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

import Darwin
import Foundation
import IOKit
import IOKit.ps
import os

// The root helper behind "keep awake with the lid closed". launchd starts it when
// the session folder changes and at boot; it runs only while a lease is fresh and
// then exits, so nothing runs when the feature is not in use.
//
// It runs with one argument, the app's path, from a root-owned plist. Decisions
// are in LidGuardPolicy.swift. Everything from the user's side is only `lstat`ed.

private let log = Logger(subsystem: LidGuardConfig.label, category: "guard")

/// The outside world. In a debug build, tests swap it for files in a folder, so
/// the real helper can run as an ordinary user and change nothing on the Mac.
private struct World {
    var sessionDirectory = LidGuardConfig.sessionDirectory
    var supportDirectory = LidGuardConfig.supportDirectory
    var pmset = "/usr/bin/pmset"
    var launchctl: String? = "/bin/launchctl"
    var plistPath = LidGuardConfig.plistPath
    var helperPath = LidGuardConfig.helperPath
    var tick = LidGuardConfig.tick
    var appGoneLimit = LidGuardConfig.appGoneLimit
    var unknownBatteryLimit = LidGuardConfig.unknownBatteryLimit
    var confirmLooks = 20
    var readRoot: (String) -> Any? = { key in
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    /// `nil` when the battery cannot be read. A Mac with no battery is on power.
    var battery: () -> (onBattery: Bool, percent: Int?)? = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  details[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onBattery = details[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            guard let current = details[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = details[kIOPSMaxCapacityKey] as? Int, maximum > 0 else {
                return onBattery ? nil : (false, nil)
            }
            return (onBattery, current * 100 / maximum)
        }
        return (false, nil)
    }
    var thermal: () -> Int = { ProcessInfo.processInfo.thermalState.rawValue }
}

/// Runs a system tool with an empty environment and waits for it, but not for
/// ever: a hung tool must not stop the checks of battery and heat.
@discardableResult
private func run(_ path: String, _ arguments: [String]) -> Bool {
    let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    let environment: [UnsafeMutablePointer<CChar>?] = [nil]
    var pid: pid_t = 0
    guard posix_spawn(&pid, path, nil, nil, argv, environment) == 0 else {
        log.error("could not start \(path, privacy: .public)")
        return false
    }
    let deadline = Date().addingTimeInterval(10)
    var status: Int32 = 0
    while true {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return status == 0 }
        if result == -1 && errno != EINTR { return false }
        if Date() > deadline {
            log.error("\(path, privacy: .public) did not finish")
            kill(pid, SIGKILL)
            // Not for ever either: a process stuck in the kernel does not die.
            for _ in 0..<100 where waitpid(pid, &status, WNOHANG) != pid { usleep(20_000) }
            return false
        }
        usleep(20_000)
    }
}

private final class Guard {
    private let world: World
    private let appPath: String?
    private var seriousHeatSince: Date?
    private var appMissingSince: Date?
    private var batteryUnknownSince: Date?
    private var turnOffFailures = 0

    init(world: World, appPath: String?) {
        self.world = world
        self.appPath = appPath
    }

    private var statusPath: String { "\(world.supportDirectory)/\(LidGuardConfig.statusName)" }
    private var markerPath: String { "\(world.supportDirectory)/\(LidGuardConfig.markerName)" }

    /// The date of a name in the user's folder. `lstat` only: a link or a folder
    /// put there counts as nothing, and nothing is ever opened.
    private func leaseAge() -> TimeInterval? {
        var info = stat()
        let path = "\(world.sessionDirectory)/\(LidGuardConfig.leaseName)"
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let date = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        return Date().timeIntervalSince1970 - date
    }

    private func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Really not there. A path macOS will not let a daemon look at, in Desktop for
    /// example, answers with another error and is still somewhere.
    private func isGone(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) != 0 && (errno == ENOENT || errno == ENOTDIR)
    }

    /// How long something has been going on, from one check to the next.
    private func duration(_ happening: Bool, since start: inout Date?) -> TimeInterval {
        guard happening else {
            start = nil
            return 0
        }
        let since = start ?? Date()
        start = since
        return Date().timeIntervalSince(since)
    }

    /// The level the user chose: which fixed name exists, nothing read from it. If
    /// several do, the highest counts, the safe way round.
    private func chosenFloor() -> Int {
        LidGuardConfig.batteryFloors.sorted(by: >).first {
            exists("\(world.sessionDirectory)/\(LidGuardConfig.floorName($0))")
        } ?? LidGuardConfig.batteryFloor
    }

    private func observe() -> LidGuardObservation {
        let thermalLevel = world.thermal()
        let battery = world.battery()
        let status = (try? String(contentsOfFile: statusPath, encoding: .utf8)).flatMap(LidGuardStatus.init(rawValue:))
        let appMissing = appPath.map { isGone($0) } ?? false
        var seen = LidGuardObservation()
        seen.leaseAge = leaseAge()
        seen.uninstallRequested = exists("\(world.sessionDirectory)/\(LidGuardConfig.uninstallName)")
        seen.appMissing = appMissing
        seen.appGone = duration(appMissing, since: &appMissingSince) >= world.appGoneLimit && appMissing
        seen.sleepDisabled = world.readRoot("SleepDisabled") as? Bool ?? false
        seen.hasMarker = exists(markerPath)
        seen.status = status ?? .off
        seen.onBattery = battery?.onBattery ?? false
        seen.batteryPercent = battery?.percent
        seen.batteryFloor = chosenFloor()
        // In config units, so a debug build can shorten the wait.
        seen.batteryUnknownFor = duration(battery == nil, since: &batteryUnknownSince)
            * LidGuardConfig.unknownBatteryLimit / world.unknownBatteryLimit
        seen.thermalLevel = thermalLevel
        seen.seriousHeatFor = duration(thermalLevel >= ProcessInfo.ThermalState.serious.rawValue, since: &seriousHeatSince)
        seen.lidClosed = world.readRoot("AppleClamshellState") as? Bool ?? false
        seen.lidCausesSleep = world.readRoot("AppleClamshellCausesSleep") as? Bool ?? true
        return seen
    }

    private func write(status: LidGuardStatus) {
        do {
            try Data(status.rawValue.utf8).write(to: URL(fileURLWithPath: statusPath), options: .atomic)
            chmod(statusPath, 0o644)
        } catch {
            log.error("could not write the status: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `pmset` has returned; the kernel may not have caught up, and `sleepnow`
    /// is refused until it has. A macOS that no longer has this setting to read
    /// leaves only `pmset`'s word for it.
    private func flagIsConfirmedOff(pmsetSucceeded: Bool) -> Bool {
        for _ in 0..<world.confirmLooks {
            guard let flag = world.readRoot("SleepDisabled") as? Bool else { return pmsetSucceeded }
            if !flag { return true }
            usleep(100_000)
        }
        return false
    }

    /// False when it did not take, and has to be tried again at the next check.
    /// The marker goes only once the flag is seen off, so that a failure cannot
    /// leave the flag on with nothing saying it is this helper's to clear. The
    /// status is written either way: a stop is a stop, and the app must hear of it.
    private func apply(_ decision: LidGuardDecision, seen: LidGuardObservation) -> Bool {
        // The marker first, or no flag: stopped between the two, the flag must still be found ours.
        if decision.writeMarker, !FileManager.default.createFile(atPath: markerPath, contents: Data()) {
            log.error("could not write the marker")
            return false
        }
        var flagIsOff = true
        if let flag = decision.setSleepDisabled {
            let succeeded = run(world.pmset, ["-a", "disablesleep", flag ? "1" : "0"])
            log.notice("disablesleep \(flag ? 1 : 0, privacy: .public): lease \(seen.leaseAge ?? -1, privacy: .public) s, lid closed \(seen.lidClosed, privacy: .public), causes sleep \(seen.lidCausesSleep, privacy: .public), battery \(seen.batteryPercent ?? -1, privacy: .public), thermal \(seen.thermalLevel, privacy: .public)")
            if !flag { flagIsOff = flagIsConfirmedOff(pmsetSucceeded: succeeded) }
        }
        if let status = decision.status {
            if status != seen.status { log.notice("status \(status.rawValue, privacy: .public)") }
            // Also when unchanged, while running: its date says the helper is alive.
            if status != seen.status || decision.next == .keepRunning || !exists(statusPath) {
                write(status: status)
            }
        }
        guard flagIsOff else {
            log.error("sleep is still disabled")
            return false
        }
        if decision.removeMarker {
            unlink(markerPath)
        }
        if decision.sleepNow {
            run(world.pmset, ["sleepnow"])
            log.notice("asked the Mac to sleep")
        }
        return true
    }

    /// One check. Exits when the helper is done.
    func check() {
        let seen = observe()
        let decision = LidGuardPolicy.decide(seen)
        let applied = apply(decision, seen: seen)
        // Being asked to go is an answer in itself, after this one try. The marker
        // then stays behind, so that the app can say what is left to put right.
        if !applied && decision.next != .removeSelf {
            turnOffFailures += 1
            if turnOffFailures >= LidGuardConfig.turnOffAttempts {
                log.error("giving up on the flag for now")
                exit(0)
            }
            return
        }
        turnOffFailures = 0
        switch decision.next {
        case .keepRunning:
            return
        case .exit:
            exit(0)
        case .removeSelf:
            removeSelf(keepingMarker: !applied)
        }
    }

    /// launchd is asking the helper to stop: the helper was switched off in Login
    /// Items, or the Mac is shutting down. Nothing may be left switched on.
    func terminate() {
        var seen = observe()
        seen.leaseAge = nil
        seen.uninstallRequested = false
        var decision = LidGuardPolicy.decide(seen)
        // Shutting down, not sleeping.
        decision.sleepNow = false
        // If it did not take, the marker stays and the next start clears the flag.
        _ = apply(decision, seen: seen)
        exit(0)
    }

    /// Constant names only, and never a recursive delete: the session folder is
    /// the user's, and walking it as root could be led somewhere else. What the
    /// user left in there stays, and so does the folder.
    private func removeSelf(keepingMarker: Bool) -> Never {
        log.notice("removing the helper")
        for name in [LidGuardConfig.leaseName, LidGuardConfig.uninstallName, LidGuardConfig.wakeName]
            + LidGuardConfig.batteryFloors.map(LidGuardConfig.floorName) {
            unlink("\(world.sessionDirectory)/\(name)")
        }
        rmdir(world.sessionDirectory)
        for name in [LidGuardConfig.statusName, LidGuardConfig.versionName] {
            unlink("\(world.supportDirectory)/\(name)")
        }
        if !keepingMarker { unlink(markerPath) }
        rmdir(world.supportDirectory)
        unlink(world.plistPath)
        unlink(world.helperPath)
        if let launchctl = world.launchctl {
            run(launchctl, ["bootout", "system/\(LidGuardConfig.label)"])
        }
        exit(0)
    }
}

private var world = World()
private var appPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil

#if DEBUG
// `--test-root <folder>`: everything lives in that folder. A debug-only hook:
// the release build has no way to point the helper anywhere else.
if CommandLine.arguments.count > 3, CommandLine.arguments[2] == "--test-root" {
    let root = CommandLine.arguments[3]
    log.notice("debug build: running from a test root")
    func simulated(_ name: String) -> String? {
        (try? String(contentsOfFile: "\(root)/sim/\(name)", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    world.sessionDirectory = "\(root)/session"
    world.supportDirectory = "\(root)/support"
    world.pmset = "\(root)/fake-pmset"
    world.launchctl = nil
    world.plistPath = "\(root)/plist"
    world.helperPath = "\(root)/helper"
    world.tick = 0.1
    world.appGoneLimit = 0.5
    world.unknownBatteryLimit = 0.5
    world.confirmLooks = 3
    world.readRoot = { key in
        switch key {
        case "SleepDisabled": return simulated("flag-unreadable") != nil ? nil : simulated("flag") == "1"
        case "AppleClamshellState": return simulated("lid") == "closed"
        case "AppleClamshellCausesSleep": return simulated("causes") != "no"
        default: return nil
        }
    }
    world.battery = {
        let source = simulated("source")
        return source == "unknown" ? nil : (source == "battery", simulated("percent").flatMap { Int($0) })
    }
    world.thermal = { simulated("thermal").flatMap { Int($0) } ?? 0 }
}
#endif

private let lidGuard = Guard(world: world, appPath: appPath)

signal(SIGTERM, SIG_IGN)
private let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler { lidGuard.terminate() }
termination.resume()

private let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: world.tick, leeway: .milliseconds(Int(world.tick * 100)))
timer.setEventHandler { lidGuard.check() }
timer.resume()

dispatchMain()
