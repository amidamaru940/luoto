/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Combine
import Defaults
import Foundation
import IOKit.pwr_mgt
import SwiftUI

/// Keeps the Mac awake for as long as the user asks, the way `caffeinate(8)`
/// does, by holding an IOKit power assertion.
///
/// The assertion is held by this process, so it is released automatically if
/// Luoto exits for any reason. "With the lid closed" is not an assertion: the root
/// helper holds that, and ends it when the app stops renewing its lease
/// (LidAwakeController).
@MainActor
final class CaffeinateManager: ObservableObject {
    static let shared = CaffeinateManager()

    /// Whether an assertion is currently held.
    @Published private(set) var isActive: Bool = false

    /// When the current session ends, or `nil` for an indefinite session.
    @Published private(set) var expiresAt: Date?

    /// Seconds left in a timed session, republished once a second so views can
    /// count down. `nil` while idle or during an indefinite session.
    @Published private(set) var remainingTime: TimeInterval?

    /// The closed island's value for a timed session, at minute resolution
    /// ("45 min", "1h 20"). Republished only when the text changes, so the
    /// closed island redraws once a minute, not with every tick of
    /// `remainingTime`. `nil` while idle or during an indefinite session.
    @Published private(set) var closedLabel: String?

    /// Whether the last `activate(for:)` replaced a running session (a new
    /// duration) rather than starting one. Read when `isActive` turns true.
    private(set) var lastActivationReplacedSession = false

    /// The duration the running session was started with. Kept so the UI can
    /// show what is running without inferring it back out of `expiresAt`.
    @Published private(set) var activeDuration: CaffeinateDuration?

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var displayLetGo = false
    private var ticker: AnyCancellable?
    private var featureCancellable: AnyCancellable?

    private init() {
        #if DEBUG
        // Live checks of the closed island: `--keep-awake-check` starts an
        // indefinite session 5 s after launch, with the island closed, as
        // its shortcut would. Never in a release build.
        if CommandLine.arguments.contains("--keep-awake-check") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.activate(for: .indefinite)
            }
        }
        #endif
        // Turning the feature off in Settings must also drop a session that is
        // already running, otherwise the Mac stays awake with no visible
        // control left to stop it.
        featureCancellable = Defaults.publisher(.enableCaffeinate, options: [])
            .sink { [weak self] change in
                guard !change.newValue else { return }
                Task { @MainActor in self?.deactivate() }
            }
    }

    deinit {
        // `deinit` cannot hop to the main actor, and the assertion ID is a
        // plain integer, so release it directly.
        if assertionID != IOPMAssertionID(0) {
            IOPMAssertionRelease(assertionID)
        }
    }

    // MARK: - Control

    /// Starts a session, replacing any session already running.
    ///
    /// Re-asserting is how a duration change is applied: the old assertion is
    /// released first so the two never stack. The lid-closed helper stays on
    /// through that, so a new duration does not switch it off and on.
    /// Returns false when macOS refused, so the panel can say so.
    @discardableResult
    func activate(for duration: CaffeinateDuration) -> Bool {
        // A new duration replaces the running session: `isActive` goes false
        // and back to true, which is not a start the island should greet.
        lastActivationReplacedSession = isActive
        resetSession()

        guard Defaults[.enableCaffeinate], takeAssertion() else {
            LidAwakeController.shared.sessionDidEnd()
            return false
        }

        isActive = true
        activeDuration = duration
        expiresAt = Self.expiry(from: Date(), duration: duration)
        startTicking()
        LidAwakeController.shared.sessionDidStart()
        return true
    }

    /// Releases the assertion, if one is held. Safe to call when idle.
    func deactivate() {
        resetSession()
        displayLetGo = false
        LidAwakeController.shared.sessionDidEnd()
    }

    private func resetSession() {
        if assertionID != IOPMAssertionID(0) {
            IOPMAssertionRelease(assertionID)
            assertionID = IOPMAssertionID(0)
        }

        ticker?.cancel()
        ticker = nil
        isActive = false
        expiresAt = nil
        remainingTime = nil
        closedLabel = nil
        activeDuration = nil
    }

    /// Wakes a display that stayed dark after the lid opened.
    func declareUserActivity() {
        var id = IOPMAssertionID(0)
        if IOPMAssertionDeclareUserActivity(Self.assertionReason as CFString, kIOPMUserActiveLocal, &id) == kIOReturnSuccess {
            IOPMAssertionRelease(id)
        }
    }

    private func takeAssertion() -> Bool {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            Self.assertionType(keepsDisplayAwake: Defaults[.caffeinateKeepsDisplayAwake], displayLetGo: displayLetGo) as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionReason as CFString,
            &id
        )

        guard result == kIOReturnSuccess else {
            NSLog("[Caffeinate] IOPMAssertionCreateWithName failed: \(result)")
            return false
        }

        assertionID = id
        return true
    }

    /// With the lid closed the display must be free to sleep while the session
    /// goes on. The new assertion comes first, so the Mac is never without one.
    /// Returns false when macOS refused, so the caller knows to try again.
    @discardableResult
    func letDisplaySleep(_ letGo: Bool) -> Bool {
        guard isActive, displayLetGo != letGo else {
            if !isActive { displayLetGo = false }
            return true
        }
        displayLetGo = letGo
        let previous = assertionID
        guard takeAssertion() else {
            displayLetGo = !letGo
            return false
        }
        if previous != IOPMAssertionID(0) { IOPMAssertionRelease(previous) }
        return true
    }

    /// Starts the configured default duration, or stops a running session.
    func toggle() {
        if isActive {
            deactivate()
        } else {
            activate(for: Defaults[.caffeinateDefaultDuration])
        }
    }

    // MARK: - Countdown

    private func startTicking() {
        guard let expiry = expiresAt else {
            // Indefinite: nothing to count down, and no timer to burn wakeups on.
            remainingTime = nil
            closedLabel = nil
            return
        }

        remainingTime = max(0, expiry.timeIntervalSinceNow)
        closedLabel = Self.closedLabel(remaining: remainingTime ?? 0)
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let left = max(0, expiry.timeIntervalSinceNow)
                self.remainingTime = left
                let label = Self.closedLabel(remaining: left)
                if self.closedLabel != label { self.closedLabel = label }
                if left <= 0 {
                    self.deactivate()
                }
            }
    }

    // MARK: - Pure helpers

    private static let assertionReason = "Luoto is keeping this Mac awake"

    /// A display the lid has closed on is never held on, whatever the setting.
    nonisolated static func assertionType(keepsDisplayAwake: Bool, displayLetGo: Bool) -> String {
        keepsDisplayAwake && !displayLetGo ? kIOPMAssertionTypeNoDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
    }

    /// The moment a session started at `start` should end, or `nil` when the
    /// session never expires on its own.
    nonisolated static func expiry(from start: Date, duration: CaffeinateDuration) -> Date? {
        guard let seconds = duration.seconds else { return nil }
        return start.addingTimeInterval(seconds)
    }

    /// A countdown label: `M:SS` under an hour, `H:MM:SS` at or above it.
    ///
    /// Rounds up, so a session with 0.4s left still reads "0:01" rather than
    /// showing "0:00" for most of its final second.
    nonisolated static func remainingLabel(_ interval: TimeInterval) -> String {
        let total = Int(ceil(max(0, interval)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// "45 min" for minutes, "1h 20" for hours and minutes, in the app's language.
    nonisolated static var closedMinutesFormat: String { String(localized: "%lld min") }
    nonisolated static var closedHoursFormat: String { String(localized: "%lldh %02lld") }

    /// The closed island's value at minute resolution, rounded up: "1 min"
    /// in the last minute, "59 min", then "1h 00", "1h 05", "3h 59". No
    /// seconds, so it changes once a minute.
    nonisolated static func closedLabel(
        remaining: TimeInterval,
        minutesFormat: String = closedMinutesFormat,
        hoursFormat: String = closedHoursFormat
    ) -> String {
        let minutes = max(1, Int(ceil(max(0, remaining) / 60)))
        if minutes < 60 {
            return String(format: minutesFormat, Int64(minutes))
        }
        return String(format: hoursFormat, Int64(minutes / 60), Int64(minutes % 60))
    }

    /// The widest value a timed session can show: "59 min" or the hours
    /// form at its widest digits (sessions last at most 4 h, "3h 59").
    /// One width for the whole session keeps the island from twitching.
    nonisolated static func widestClosedLabels(
        minutesFormat: String = closedMinutesFormat,
        hoursFormat: String = closedHoursFormat
    ) -> [String] {
        [String(format: minutesFormat, Int64(59)), String(format: hoursFormat, Int64(3), Int64(59))]
    }
}
