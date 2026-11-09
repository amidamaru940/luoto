/*
 * Luoto — a fork of Atoll (DynamicIsland)
 * Copyright (C) 2026 amidamaru940 and Luoto contributors
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

import AppKit
import Combine
import CoreGraphics
import OSLog

/// The one standing poll Luoto keeps: the pasteboard's `changeCount`, once a
/// second with half a second of tolerance, and only while someone is at the
/// Mac.
///
/// macOS posts no notice when the clipboard changes, so reading its counter
/// is the only way to see a copy. The look stops when the Mac sleeps, the
/// screen sleeps or locks (`ActivityGate`), and after a minute without any
/// keyboard or pointer input: a copy needs a person, and the first input
/// afterwards starts it again with an immediate look. A change made while it
/// waited for input (Universal Clipboard, a password manager clearing the
/// clipboard) is seen then, with what the clipboard holds at that moment.
/// Leaving the Mac (lock, sleep, screen sleep) looks once more, so a copy
/// made just before is kept. Coming back from a lock, a sleep or another
/// user's session takes the count as seen: nobody copies in this session
/// then, so the change came from another device, which Luoto leaves unread
/// anyway. Coming back from a screen sleep with no lock in between (the
/// password asked later, or not at all) looks at once, as scripts and
/// remote desktop apps may write to the clipboard while the screen is dark.
///
/// A burst of clipboard screenshots replaces the picture a few times a
/// second, so `burst()` looks ten times a second for a few seconds. Only an
/// event asks for it (the screenshot shortcut's modifiers, a screenshot
/// arriving), never the watcher itself. Main thread only.
final class ClipboardChangeWatcher {
    static let shared = ClipboardChangeWatcher()

    static let interval: TimeInterval = 1
    static let tolerance: TimeInterval = 0.5
    /// Without input for this long, the look waits for the next input.
    static let idleAfter: TimeInterval = 60
    static let burstInterval: TimeInterval = 0.1
    static let burstDuration: TimeInterval = 6
    /// Looks after an event that may put a picture on the clipboard a moment
    /// later (`nudge()`): the screenshot tool writes it 0.1–0.5 s after the
    /// selection ends.
    static let nudgeDelays: [TimeInterval] = [0.15, 0.4, 0.9]

    /// Called on every change, with the change count it was seen at.
    typealias Listener = (Int) -> Void

    let pasteboard: NSPasteboard
    /// Kept so the slow-look line asks the pasteboard for nothing.
    private let pasteboardName: String
    private let gate: ActivityGate
    private let idleSeconds: () -> TimeInterval
    private var listeners: [UUID: Listener] = [:]
    private var lastChangeCount: Int
    private var steady: GatedTimer?
    private var burstTimer: GatedTimer?
    private var burstEnds: Date?
    private var resumeMonitors: [Any] = []
    /// ⇧⌘ held and mouse releases: the events that put screenshots on the
    /// clipboard. Installed with the first listener, for the clipboard
    /// history and the screenshot batches alike.
    private var screenshotEventMonitors: [Any] = []
    private let watchesScreenshotEvents: Bool
    private var gateSubscription: AnyCancellable?
    private var stateSubscription: AnyCancellable?
    /// The time away included a lock or a sleep, not only a dark screen.
    private var awayLockedOrAsleep = false

    /// True while the look waits for input after the idle minute.
    private(set) var isWaitingForInput = false
    var isLooking: Bool { steady?.isScheduled == true || burstTimer?.isScheduled == true }
    var isBursting: Bool { burstTimer?.isScheduled == true }

    init(pasteboard: NSPasteboard = .general,
         gate: ActivityGate = .shared,
         idleSeconds: @escaping () -> TimeInterval = ClipboardChangeWatcher.secondsSinceLastInput,
         watchesScreenshotEvents: Bool? = nil) {
        self.pasteboard = pasteboard
        self.pasteboardName = pasteboard.name.rawValue
        self.gate = gate
        self.idleSeconds = idleSeconds
        self.watchesScreenshotEvents = watchesScreenshotEvents ?? (pasteboard === NSPasteboard.general)
        lastChangeCount = pasteboard.changeCount
        steady = GatedTimer(name: "clipboard changeCount", interval: Self.interval, tolerance: Self.tolerance, gate: gate) { [weak self] in
            self?.tick()
        }
        burstTimer = GatedTimer(name: "clipboard burst", interval: Self.burstInterval, tolerance: Self.burstInterval / 5, gate: gate) { [weak self] in
            self?.burstTick()
        }
        // Leaving and coming back; see the type's comment. Looking at a
        // phone copy right at the unlock asked the pasteboard while macOS
        // was still fetching it from the phone and held the main thread for
        // seconds (5.5 s on 09.11).
        gateSubscription = gate.publisher(for: .userPresent)
            .dropFirst()
            .sink { [weak self] present in
                guard let self else { return }
                self.stopWaitingForInput()
                let skipsTheTimeAway = present && self.awayLockedOrAsleep
                if present { self.awayLockedOrAsleep = false }
                guard !self.listeners.isEmpty else { return }
                if present {
                    if skipsTheTimeAway {
                        self.lastChangeCount = self.pasteboard.changeCount
                        self.steady?.start()
                    } else {
                        self.steady?.start()
                        self.look()
                    }
                } else {
                    self.look()
                }
            }
        // Set while away only (being present needs both); cleared above on
        // the way back, so the two subscriptions may run in either order.
        stateSubscription = gate.$state
            .sink { [weak self] state in
                if !state.unlocked || !state.systemAwake || !state.sessionActive { self?.awayLockedOrAsleep = true }
            }
    }

    /// Starts looking with the first listener.
    @discardableResult
    func add(_ listener: @escaping Listener) -> UUID {
        let id = UUID()
        if listeners.isEmpty {
            lastChangeCount = pasteboard.changeCount
            steady?.start()
            startScreenshotEventMonitors()
        }
        listeners[id] = listener
        return id
    }

    /// Stops looking with the last listener.
    func remove(_ id: UUID?) {
        guard let id, listeners.removeValue(forKey: id) != nil, listeners.isEmpty else { return }
        steady?.stop()
        burstTimer?.stop()
        burstEnds = nil
        stopWaitingForInput()
        stopScreenshotEventMonitors()
    }

    /// ⌃⇧⌘3/4 and ⇧⌘5 all hold ⇧⌘: look fast for the shots that follow
    /// (seen only with Accessibility). A mouse release, seen without it, ends
    /// a ⌃⇧⌘4 selection and the ⇧⌘5 toolbar's Capture: a few looks follow.
    /// Both are events, so they cost nothing between key presses and clicks.
    /// They used to belong to the screenshot collector alone, so with
    /// "collect clipboard screenshots" off the history missed quick shots.
    private func startScreenshotEventMonitors() {
        guard watchesScreenshotEvents, screenshotEventMonitors.isEmpty else { return }
        let onFlags: (NSEvent) -> Void = { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: [.shift, .command]) else { return }
            self?.burst()
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: onFlags) {
            screenshotEventMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            onFlags(event)
            return event
        }) {
            screenshotEventMonitors.append(local)
        }
        if let release = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            self?.nudge()
        }) {
            screenshotEventMonitors.append(release)
        }
    }

    private func stopScreenshotEventMonitors() {
        screenshotEventMonitors.forEach(NSEvent.removeMonitor)
        screenshotEventMonitors.removeAll()
    }

    /// Looks ten times a second for `burstDuration` from now.
    func burst() {
        guard !listeners.isEmpty, gate.allows(.userPresent) else { return }
        burstEnds = Date().addingTimeInterval(Self.burstDuration)
        stopWaitingForInput()
        steady?.start()
        burstTimer?.start()
    }

    /// A few looks right after an event that may put a screenshot on the
    /// clipboard: a mouse release ends a ⌃⇧⌘4 selection or a click on the
    /// ⇧⌘5 toolbar's Capture. The shortcut's ⇧⌘ is seen only with
    /// Accessibility; mouse releases are seen without it. Without these
    /// looks, two shots inside one once-a-second look kept only the second.
    /// Three cheap looks per click, no timer left running; a
    /// screenshot found this way starts the burst.
    func nudge() {
        guard !listeners.isEmpty, gate.allows(.userPresent) else { return }
        for delay in Self.nudgeDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                // Still someone at the Mac when it fires: a lock in between stops it.
                guard let self, !self.listeners.isEmpty, self.gate.allows(.userPresent) else { return }
                self.look()
            }
        }
    }

    /// One look now, outside the schedule.
    ///
    /// Timed as a whole: `changeCount` and every listener (the history's
    /// `captureChange`, the screenshot collector's `poll`). A look that held
    /// the main thread longer than `slowLookThreshold` leaves one log line.
    /// A look started inside a listener (a nested run loop, such as WebKit's
    /// while it turns HTML into RTF, can fire a nudge or a tick) belongs to
    /// the outer one: only the outermost look writes the line, and its
    /// remote flag is that of the change the outer look saw, even when the
    /// inner look has moved on to a newer one.
    func look() {
        lookDepth += 1
        let isOuter = lookDepth == 1
        let started = isOuter ? Self.now() : 0
        if isOuter {
            outerRemoteBeforeNested = nil
        } else if outerRemoteBeforeNested == nil {
            // Before the inner look's listeners note their own change over it.
            outerRemoteBeforeNested = .some(ClipboardCapturePolicy.seenRemote(
                changeCount: outerChangeCount, pasteboardName: pasteboardName))
        }
        let count = pasteboard.changeCount
        if isOuter { outerChangeCount = count }
        defer {
            lookDepth -= 1
            if lookDepth == 0 { reportIfSlow(since: started, changeCount: count) }
        }
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        for listener in Array(listeners.values) {
            listener(count)
        }
    }

    // MARK: - Slow looks

    /// A look longer than this is written to the log.
    static let slowLookThreshold: TimeInterval = 0.5
    static let log = OSLog(subsystem: "io.github.amidamaru940.luoto", category: "clipboard")

    /// Looks running now, the outermost one included.
    private var lookDepth = 0
    /// The change count the outermost look running now saw.
    private var outerChangeCount = 0
    /// What the outer look's change was noted as when the first nested look
    /// began (`.some(nil)`: not decided yet); nil while no look is nested.
    /// The policy keeps one change only, and the nested look's listeners
    /// replace it with theirs.
    private var outerRemoteBeforeNested: Bool??

    /// Monotonic clock in nanoseconds; tests replace it.
    static var now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    /// Where the slow-look line goes; tests replace it. Public, because the
    /// line holds only a duration and yes/no/?: no content, no type names.
    static var logSlowLook: (String) -> Void = { message in
        os_log("%{public}@", log: ClipboardChangeWatcher.log, type: .default, message)
    }

    /// Log readers match lines that begin with "clipboard look took": keep
    /// that start as it is. `remote` is nil when no listener decided on the
    /// change the look saw (no listener got that far). When nothing changed,
    /// the flag repeats the state of the previous change, the one the look saw.
    static func slowLookMessage(seconds: TimeInterval, remote: Bool?) -> String {
        let flag = remote.map { $0 ? "yes" : "no" } ?? "?"
        return "clipboard look took \(String(format: "%.1f", seconds)) s (remote=\(flag))"
    }

    /// Reads nothing from the pasteboard: whether the copy came from another
    /// device is what the listeners noted while deciding on `changeCount`,
    /// the change the outer look saw.
    private func reportIfSlow(since started: UInt64, changeCount: Int) {
        let beforeNested: Bool? = outerRemoteBeforeNested ?? nil
        outerRemoteBeforeNested = nil
        let ended = Self.now()
        let seconds = TimeInterval(ended &- started) / 1_000_000_000
        guard ended >= started, seconds > Self.slowLookThreshold else { return }
        let remote = ClipboardCapturePolicy.seenRemote(changeCount: changeCount, pasteboardName: pasteboardName)
            ?? beforeNested
        Self.logSlowLook(Self.slowLookMessage(seconds: seconds, remote: remote))
    }

    // MARK: - Schedule

    /// One scheduled look; internal so tests can run it without waiting.
    func tick() {
        look()
        guard !isBursting, idleSeconds() >= Self.idleAfter else { return }
        waitForInput()
    }

    private func burstTick() {
        look()
        if let burstEnds, Date() < burstEnds { return }
        burstEnds = nil
        burstTimer?.stop()
    }

    /// Pauses the look until the next keyboard or pointer event anywhere.
    /// The monitors fire once: the first event removes them.
    private func waitForInput() {
        guard !isWaitingForInput else { return }
        steady?.stop()
        isWaitingForInput = true
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown,
                                           .otherMouseDown, .scrollWheel, .mouseMoved]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.inputArrived()
        }) {
            resumeMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.inputArrived()
            return event
        }) {
            resumeMonitors.append(local)
        }
    }

    private func inputArrived() {
        guard isWaitingForInput else { return }
        stopWaitingForInput()
        guard !listeners.isEmpty else { return }
        look()
        steady?.start()
    }

    private func stopWaitingForInput() {
        resumeMonitors.forEach(NSEvent.removeMonitor)
        resumeMonitors.removeAll()
        isWaitingForInput = false
    }

    /// Seconds since the last keyboard, mouse or trackpad event in this session.
    static func secondsSinceLastInput() -> TimeInterval {
        // kCGAnyInputEventType (~0): any kind of input.
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}
