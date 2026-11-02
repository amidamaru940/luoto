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
import Defaults
import Foundation
import IOKit
import ServiceManagement

/// The power manager's registry entry, which anyone may read.
enum PowerRootDomain {
    static func bool(_ key: String) -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    /// Desktops have no such key, and nothing to close. A Mac does not grow a lid.
    static let hasLid = bool("AppleClamshellState") != nil
    static var lidClosed: Bool { bool("AppleClamshellState") ?? false }
    static var sleepDisabled: Bool {
        #if DEBUG
        if let testSleepDisabled { return testSleepDisabled }
        #endif
        return bool("SleepDisabled") ?? false
    }

    #if DEBUG
    nonisolated(unsafe) static var testSleepDisabled: Bool?
    #endif
}

enum LidAwakeStop: Equatable {
    case battery, thermal
}

/// How far along "with the lid closed" is. Keep Awake itself goes on through all
/// of these, until its own time is up.
enum LidAwakePhase: Equatable {
    case idle
    /// The lease is there; the helper has not been seen to act yet.
    case arming
    /// Read back from the system: closing the lid will not put the Mac to sleep.
    case ready
    /// Sleep was already off by someone else's hand.
    case foreign
    /// The helper hit a limit. A closed lid sleeps again until this is turned on again.
    case stopped(LidAwakeStop)
    /// Not read back in time, and macOS lists the helper as switched off.
    case helperOff
    /// Not read back in time, for no reason Luoto can name.
    case failed
    /// Sleep is off but the helper is silent: the Mac stays awake with nothing
    /// watching the battery or the heat.
    case helperSilent
}

/// The app's side of keeping the Mac awake with the lid closed: it keeps the
/// lease fresh while a session wants this, and says only what it has read back.
/// The limits and the turning off live in the root helper, which does not need
/// this app to be alive. See LidGuard/.
@MainActor
final class LidAwakeController: ObservableObject {
    static let shared = LidAwakeController()

    enum Removal: Equatable { case done, failed }

    @Published private(set) var phase = LidAwakePhase.idle
    @Published private(set) var installState = LidGuardInstaller.state
    @Published private(set) var isInstalling = false
    @Published private(set) var setupOutcome: LidGuardInstaller.Outcome?
    @Published private(set) var removal: Removal?
    /// Sleep is off, the helper turned it off, and it does not answer.
    @Published private(set) var isStuck = false
    @Published private(set) var lidClosed = false

    /// How long the helper may take before the panel admits it did not act.
    nonisolated static let armingLimit: TimeInterval = 20
    /// The flag may be briefly off at one look, before the helper puts it back.
    nonisolated static let flagLossLimit: TimeInterval = 20
    /// How long the display may stay dark after the lid opens.
    nonisolated static let wakeDisplayDelay: TimeInterval = 3

    private var heartbeat: DispatchSourceTimer?
    private var poll: DispatchSourceTimer?
    private var armedAt = Date()
    private var troubleSince: Date?
    private var notificationPort: IONotificationPortRef?
    private var lidNotifier: io_object_t = IO_OBJECT_NULL
    private var displayLetGo = false
    private var leaseWriteFailed = false
    /// This copy of the app wrote the lease. Another copy on the Mac, a debug build
    /// for one, must leave the running one's lease alone.
    private var holdsLease = false
    private var stuckCheck: Task<Void, Never>?
    private var hasAskedAboutStuckSleep = false
    private var wakeObserver: NSObjectProtocol?
    /// How long the helper gets to clear the flag before anyone is told.
    static var stuckCheckDelay = armingLimit

    private init() {}

    var isOptionOn: Bool { Defaults[.caffeinateWithLidClosed] && installState == .current }

    // MARK: - The option

    func setOption(_ on: Bool) {
        setupOutcome = nil
        removal = nil
        guard on else {
            Defaults[.caffeinateWithLidClosed] = false
            disarm()
            return
        }
        refreshInstalled()
        if installState == .current {
            Defaults[.caffeinateWithLidClosed] = true
            if CaffeinateManager.shared.isActive { arm() }
        } else {
            install()
        }
    }

    /// The password dialog comes from macOS, and is asked for only from here,
    /// by the user's own click.
    func install() {
        guard !isInstalling, LidGuardInstaller.canInstall(fromAppPath: Bundle.main.bundleURL.path) else { return }
        isInstalling = true
        setupOutcome = nil
        removal = nil
        // A running lease is about to lose its helper for a moment.
        disarm()
        Task { @MainActor in
            let outcome = await LidGuardInstaller.install()
            isInstalling = false
            refreshInstalled()
            if outcome == .done && installState == .current {
                Defaults[.caffeinateWithLidClosed] = true
                if CaffeinateManager.shared.isActive { arm() }
            } else {
                setupOutcome = outcome == .done ? .failed : outcome
            }
        }
    }

    func setBatteryFloor(_ floor: Int) {
        guard LidGuardConfig.batteryFloors.contains(floor) else { return }
        Defaults[.lidClosedBatteryFloor] = floor
        if installState == .current { LidGuardInstaller.writeBatteryFloor(floor) }
    }

    /// "Turn On Again" and "Try Again".
    func turnOnAgain() {
        if CaffeinateManager.shared.isActive {
            disarm()
            arm()
        } else {
            setPhase(.idle)
            CaffeinateManager.shared.activate(for: Defaults[.caffeinateDefaultDuration])
        }
    }

    /// The helper removes itself. No password, and nothing left behind.
    func removeHelper() {
        Defaults[.caffeinateWithLidClosed] = false
        disarm()
        removal = nil
        LidGuardInstaller.requestRemoval()
        Task { @MainActor in
            for tick in 1...40 {
                try? await Task.sleep(for: .milliseconds(500))
                refreshInstalled()
                if installState == .missing {
                    removal = .done
                    return
                }
                // launchd's watch on the folder can miss a change.
                if tick == 20 { LidGuardInstaller.requestRemoval() }
            }
            removal = .failed
        }
    }

    func refreshInstalled() {
        let state = LidGuardInstaller.state
        if state != installState { installState = state }
        if isStuck && !(LidGuardInstaller.hasMarker && PowerRootDomain.sleepDisabled) { isStuck = false }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func fixStuckSleep() {
        Task { @MainActor in
            _ = await LidGuardInstaller.resetSleepFlag()
            isStuck = LidGuardInstaller.hasMarker && PowerRootDomain.sleepDisabled
        }
    }

    // MARK: - The session

    func sessionDidStart() {
        refreshInstalled()
        if isOptionOn {
            arm()
        } else {
            disarm()
        }
    }

    func sessionDidEnd() {
        let stopped: LidAwakePhase? = if case .stopped = phase { phase } else { nil }
        disarm()
        // The reason is still news when the session runs out during the sleep
        // it caused. It goes when the option or a new session says so.
        if let stopped { setPhase(stopped) }
    }

    private func arm() {
        guard heartbeat == nil else { return }
        stuckCheck?.cancel()
        setPhase(.arming)
        armedAt = Date()
        troubleSince = nil
        startLidWatch()
        guard LidGuardInstaller.status.isLatched else {
            startHeartbeat()
            return
        }
        // After a stop the helper must first let go of it, or it would read the
        // new lease as the old one. If it never does, the lease goes anyway, and
        // the helper's answer is what the panel will say.
        removeLease()
        wakeHelper()
        startPoll { [weak self] in
            guard let self else { return }
            if !LidGuardInstaller.status.isLatched || Date().timeIntervalSince(self.armedAt) >= Self.armingLimit {
                self.startHeartbeat()
            }
        }
    }

    private func startHeartbeat() {
        poll?.cancel()
        poll = nil
        armedAt = Date()
        LidGuardInstaller.writeBatteryFloor(LidGuardInstaller.chosenBatteryFloor)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + LidGuardConfig.tick, repeating: LidGuardConfig.tick, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.beat() }
        }
        timer.resume()
        heartbeat = timer
        observeWake()
        renewLease()
        startPoll { [weak self] in
            guard let self else { return }
            self.evaluate()
            if self.phase != .arming {
                self.poll?.cancel()
                self.poll = nil
            }
        }
    }

    private func startPoll(_ handler: @escaping @MainActor () -> Void) {
        poll?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler {
            MainActor.assumeIsolated { handler() }
        }
        timer.resume()
        poll = timer
    }

    private func disarm(to phase: LidAwakePhase = .idle) {
        let wasArmed = heartbeat != nil
        heartbeat?.cancel()
        heartbeat = nil
        poll?.cancel()
        poll = nil
        stopObservingWake()
        leaseWriteFailed = false
        stopLidWatch()
        if lidClosed { lidClosed = false }
        displayLetGo = false
        CaffeinateManager.shared.letDisplaySleep(false)
        removeLease()
        setPhase(phase)
        // Whatever ended it, the helper now has to let go, and may not manage to.
        if wasArmed { checkForStuckSleep() }
    }

    private func setPhase(_ new: LidAwakePhase) {
        if new != phase { phase = new }
    }

    /// Runs on the main thread on purpose: a hung app stops renewing, and the
    /// helper then ends the session.
    private func beat() {
        renewLease()
        evaluate()
        evaluateLid()
    }

    private func evaluate() {
        guard heartbeat != nil else { return }
        let status = LidGuardInstaller.status
        switch status {
        case .battery: return disarm(to: .stopped(.battery))
        case .thermal: return disarm(to: .stopped(.thermal))
        case .on, .off, .foreign: break
        }
        // The lease is dying, whatever the flag still says.
        if leaseWriteFailed { return setPhase(.failed) }
        setPhase(Self.nextPhase(from: phase, status: status, statusFresh: LidGuardInstaller.statusIsFresh,
                                flagOn: PowerRootDomain.sleepDisabled, armedAt: armedAt, troubleSince: &troubleSince,
                                now: Date(), helperSwitchedOff: Self.helperSwitchedOff))
    }

    /// Only a hint: this call is known to report `.notFound` for a helper that
    /// runs. The flag read back from the system remains the truth.
    private static var helperSwitchedOff: Bool {
        let status = SMAppService.statusForLegacyPlist(at: URL(fileURLWithPath: LidGuardConfig.plistPath))
        return status == .requiresApproval || status == .notRegistered
    }

    /// "You can close the lid" needs both: the flag read back from the system, and
    /// a helper that is alive and says it is its own, because the limits are the
    /// helper's. A flag on with no helper behind it is not that.
    nonisolated static func nextPhase(from phase: LidAwakePhase, status: LidGuardStatus, statusFresh: Bool, flagOn: Bool,
                                      armedAt: Date, troubleSince: inout Date?, now: Date,
                                      helperSwitchedOff: @autoclosure () -> Bool) -> LidAwakePhase {
        if flagOn && statusFresh && (status == .on || status == .foreign) {
            troubleSince = nil
            return status == .foreign ? .foreign : .ready
        }
        func notAnswering() -> LidAwakePhase {
            if flagOn { return .helperSilent }
            return helperSwitchedOff() ? .helperOff : .failed
        }
        switch phase {
        case .idle, .stopped:
            return phase
        case .arming:
            return now.timeIntervalSince(armedAt) >= armingLimit ? notAnswering() : .arming
        case .ready, .foreign:
            let since = troubleSince ?? now
            troubleSince = since
            return now.timeIntervalSince(since) >= flagLossLimit ? notAnswering() : phase
        case .helperOff, .failed, .helperSilent:
            return notAnswering()
        }
    }

    // MARK: - The lease

    /// Replaced, not rewritten, so the folder changes and launchd starts the
    /// helper if it is not running. A helper that has been removed ends this; a
    /// full disk is said out loud and tried again.
    private func renewLease() {
        do {
            try Data().write(to: LidGuardInstaller.leaseURL, options: .atomic)
            holdsLease = true
            leaseWriteFailed = false
        } catch {
            NSLog("[LidGuard] could not renew the lease")
            refreshInstalled()
            if installState == .current {
                leaseWriteFailed = true
                setPhase(.failed)
            } else {
                disarm()
            }
        }
    }

    private func removeLease() {
        guard holdsLease else { return }
        holdsLease = false
        try? FileManager.default.removeItem(at: LidGuardInstaller.leaseURL)
    }

    private func wakeHelper() {
        FileManager.default.createFile(atPath: LidGuardInstaller.wakeURL.path, contents: Data())
        try? FileManager.default.removeItem(at: LidGuardInstaller.wakeURL)
    }

    /// A long sleep is not a helper that failed to answer: the clocks start again.
    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.heartbeat != nil else { return }
                self.armedAt = Date()
                self.troubleSince = nil
                self.renewLease()
            }
        }
    }

    private func stopObservingWake() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    // MARK: - The display under the lid

    /// With sleep disabled the panel can stay lit under a closed lid: heat, and
    /// marks on the screen. External displays stay as they are.
    private func startLidWatch() {
        guard notificationPort == nil else { return }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        defer { IOObjectRelease(root) }
        IONotificationPortSetDispatchQueue(port, .main)
        // kIOPMMessageClamshellStateChange, which Swift cannot import.
        let result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { _, _, messageType, _ in
            guard messageType == 0xE003_4100 else { return }
            MainActor.assumeIsolated { LidAwakeController.shared.evaluateLid() }
        }, nil, &lidNotifier)
        guard result == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return
        }
        notificationPort = port
    }

    private func stopLidWatch() {
        if lidNotifier != IO_OBJECT_NULL {
            IOObjectRelease(lidNotifier)
            lidNotifier = IO_OBJECT_NULL
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
    }

    private func evaluateLid() {
        guard heartbeat != nil else { return }
        let closed = PowerRootDomain.lidClosed
        if closed != lidClosed { lidClosed = closed }
        let displays = Self.onlineDisplays()
        let hasExternal = displays.contains { CGDisplayIsBuiltin($0) == 0 }
        let letGo = closed && !hasExternal
        if letGo != displayLetGo, CaffeinateManager.shared.letDisplaySleep(letGo) {
            displayLetGo = letGo
            if !letGo { wakeDisplayIfDark() }
        }
        // Again at each heartbeat, if something woke the display under the lid.
        if letGo, displays.contains(where: { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsAsleep($0) == 0 }) {
            Self.sleepDisplay()
        }
    }

    /// Opening the lid normally wakes the display. It was put to sleep by hand,
    /// so it is checked once.
    private func wakeDisplayIfDark() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.wakeDisplayDelay))
            guard !PowerRootDomain.lidClosed else { return }
            let displays = Self.onlineDisplays()
            if displays.isEmpty || displays.contains(where: { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsAsleep($0) != 0 }) {
                CaffeinateManager.shared.declareUserActivity()
            }
        }
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    private static func sleepDisplay() {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            process.environment = ChildProcessEnvironment.sanitized()
            guard (try? process.run()) != nil else { return }
            // No thread waits on it: this can come every heartbeat.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    // MARK: - App lifetime

    /// Sessions do not survive a restart, so a lease left by a crash goes. Then the
    /// flag: if the helper still holds it, it is woken to clear it.
    func appDidLaunch() {
        refreshInstalled()
        // With another Luoto running, the lease and the flag may be its live session.
        guard AppRuntimeEnvironment.mayAskForPermissions, LaunchRecoveryGate.recoversAtThisLaunch else { return }
        // Left by this copy, before a crash.
        if installState == .current { try? FileManager.default.removeItem(at: LidGuardInstaller.leaseURL) }
        checkForStuckSleep()
    }

    func appWillTerminate() {
        removeLease()
    }

    /// If the helper cannot clear the flag, because it was switched off while
    /// holding it, the Mac would never sleep and nothing would say so. Someone
    /// else's session on this Mac is theirs, and a new session here cancels this.
    private func checkForStuckSleep() {
        stuckCheck?.cancel()
        guard installState != .otherUser, LidGuardInstaller.hasMarker, PowerRootDomain.sleepDisabled else { return }
        wakeHelper()
        stuckCheck = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.stuckCheckDelay))
            guard !Task.isCancelled, heartbeat == nil, LidGuardInstaller.hasMarker, PowerRootDomain.sleepDisabled else { return }
            isStuck = true
            askAboutStuckSleep()
        }
    }

    /// Once per launch, and not with no screen to show it on: the panel says it for
    /// as long as it is true, and the next launch asks again. From the run loop,
    /// because a modal loop inside a main-queue block would stop that queue, and
    /// with it the island, until it is answered.
    private func askAboutStuckSleep() {
        guard AppRuntimeEnvironment.mayAskForPermissions, !hasAskedAboutStuckSleep, !Self.onlineDisplays().isEmpty else { return }
        hasAskedAboutStuckSleep = true
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = LidAwakeCopy.stuckAlertTitle
                alert.informativeText = LidAwakeCopy.stuckAlertBody
                alert.addButton(withTitle: LidAwakeCopy.fixIt)
                alert.addButton(withTitle: LidAwakeCopy.notNow)
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { LidAwakeController.shared.fixStuckSleep() }
            }
        }
    }
}
