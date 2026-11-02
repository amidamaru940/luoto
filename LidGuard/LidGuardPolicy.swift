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

import Foundation

/// What the app and its root helper agree on. Compiled into both.
///
/// The helper has no socket, no XPC and reads no content from the user: the app
/// only keeps replacing an empty file, and the helper looks at that file's date.
enum LidGuardConfig {
    static let label = "io.github.amidamaru940.luoto.lidguard"
    /// Raise when the helper's behaviour changes: only then does the app ask for
    /// the password again. An ordinary update of Luoto does not.
    static let version = 2

    static let helperPath = "/Library/PrivilegedHelperTools/\(label)"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    /// Root-owned: the helper's own files.
    static let supportDirectory = "/Library/Application Support/Luoto"
    /// Owned by the user who set the helper up: the only thing the helper looks
    /// at there is the date and type of two names, through `lstat`.
    static let sessionDirectory = "\(supportDirectory)/session"

    static let leaseName = "lease"
    static let uninstallName = "uninstall"
    static let statusName = "status"
    static let markerName = "marker"
    static let versionName = "version"
    /// Creating and removing this wakes the helper; it means nothing else.
    static let wakeName = "wake"

    /// How often the app renews the lease and the helper checks everything.
    static let tick: TimeInterval = 15
    /// A lease this old means the app is dead or hung.
    static let leaseLifetime: TimeInterval = 60
    /// A date further ahead than this is treated as stale, so that a file dated
    /// next year cannot keep the Mac awake.
    static let futureTolerance: TimeInterval = 5

    /// On battery, at or below this, the session ends. macOS does not do it for
    /// us: going by the xnu source, not a test, with sleep disabled the kernel
    /// skips its own low-battery sleep.
    static let batteryFloor = 20
    /// What the user can choose. There is no "never": nothing else would stop the
    /// Mac before it died with work in memory. The choice reaches the helper as the
    /// mere presence of a fixed name in the session folder, so the helper still
    /// reads nothing, and another program can at worst lower it to the lowest here.
    static let batteryFloors = [10, 20, 30, 50]
    static func floorName(_ floor: Int) -> String { "floor-\(floor)" }
    /// `ProcessInfo.ThermalState.serious` this long ends the session, and
    /// `.critical` ends it at once. Same reason: the emergency sleep is skipped.
    static let seriousHeatLimit: TimeInterval = 120
    /// The app's path must stay gone this long before the helper removes itself:
    /// an update replaces the app, and for a moment it may not be there.
    static let appGoneLimit: TimeInterval = 30
    /// The battery cannot be read this long: treated as low, because a limit that
    /// cannot be checked does not protect anything.
    static let unknownBatteryLimit: TimeInterval = 120
    /// The helper rewrites its status at each check. Older than this, it is not
    /// running, whatever the status says.
    static let statusLifetime: TimeInterval = 45
    /// Checks in a row at which the flag would not come off before the helper
    /// stops trying and leaves it, with the marker, for the app to report and for
    /// the next start. Nothing should run for ever with no session.
    static let turnOffAttempts = 8
}

/// What the helper last said, in its root-owned status file.
enum LidGuardStatus: String {
    case off, on
    /// Sleep was already off when the session began, by someone else's hand. It
    /// stays as it is, so the limits have nothing to turn off.
    case foreign
    /// The helper ended the session and stays off until the lease is removed.
    case battery, thermal

    var isLatched: Bool { self == .battery || self == .thermal }
}

/// Everything the helper knows at one check.
struct LidGuardObservation {
    /// Seconds since the lease's date; `nil` when there is no lease.
    var leaseAge: TimeInterval?
    var uninstallRequested = false
    /// The app's path has been gone for `appGoneLimit`.
    var appGone = false
    /// The app's path is missing right now, but not for that long yet.
    var appMissing = false
    var sleepDisabled = false
    /// This helper turned the flag on, so it is this helper's to turn off.
    var hasMarker = false
    var status = LidGuardStatus.off
    var onBattery = false
    var batteryPercent: Int?
    var batteryFloor = LidGuardConfig.batteryFloor
    var batteryUnknownFor: TimeInterval = 0
    /// `ProcessInfo.ThermalState.rawValue`: 0 nominal to 3 critical.
    var thermalLevel = 0
    var seriousHeatFor: TimeInterval = 0
    var lidClosed = false
    /// `AppleClamshellCausesSleep`: false with an external display on power, or
    /// while another app holds the Mac awake, when closing the lid is not meant
    /// to put it to sleep anyway.
    var lidCausesSleep = true
}

struct LidGuardDecision: Equatable {
    enum Next: Equatable { case keepRunning, exit, removeSelf }

    var setSleepDisabled: Bool?
    var writeMarker = false
    var removeMarker = false
    var status: LidGuardStatus?
    /// `disablesleep 0` alone does not make a Mac with a closed lid sleep.
    var sleepNow = false
    var next = Next.exit
}

enum LidGuardPolicy {
    static func isLeaseFresh(age: TimeInterval?) -> Bool {
        guard let age else { return false }
        return age >= -LidGuardConfig.futureTolerance && age <= LidGuardConfig.leaseLifetime
    }

    /// Why the session has to end now, whatever the app thinks.
    static func limitReached(onBattery: Bool, batteryPercent: Int?, batteryFloor: Int = LidGuardConfig.batteryFloor,
                             batteryUnknownFor: TimeInterval = 0, thermalLevel: Int,
                             seriousHeatFor: TimeInterval) -> LidGuardStatus? {
        if thermalLevel >= ProcessInfo.ThermalState.critical.rawValue { return .thermal }
        if thermalLevel >= ProcessInfo.ThermalState.serious.rawValue,
           seriousHeatFor >= LidGuardConfig.seriousHeatLimit { return .thermal }
        if onBattery, let batteryPercent, batteryPercent <= batteryFloor { return .battery }
        if batteryUnknownFor >= LidGuardConfig.unknownBatteryLimit { return .battery }
        return nil
    }

    static func decide(_ seen: LidGuardObservation) -> LidGuardDecision {
        if seen.uninstallRequested {
            var decision = turnOff(seen)
            decision.status = .off
            decision.next = .removeSelf
            return decision
        }

        guard isLeaseFresh(age: seen.leaseAge) else {
            var decision = turnOff(seen)
            // A latched stop is for the app to read, so it lasts until the app
            // has taken the lease away.
            decision.status = (seen.leaseAge != nil && seen.status.isLatched) ? nil : .off
            decision.next = seen.appGone ? .removeSelf : (seen.appMissing ? .keepRunning : .exit)
            return decision
        }

        if seen.status.isLatched {
            var decision = turnOff(seen)
            // A second try at an emergency that the first try could not end.
            decision.sleepNow = seen.hasMarker && seen.lidClosed
            return decision
        }

        // Someone else's flag stays theirs, and their limits are theirs too.
        if seen.sleepDisabled && !seen.hasMarker {
            return LidGuardDecision(status: .foreign, next: .keepRunning)
        }

        if let reason = limitReached(onBattery: seen.onBattery, batteryPercent: seen.batteryPercent,
                                     batteryFloor: seen.batteryFloor,
                                     batteryUnknownFor: seen.batteryUnknownFor, thermalLevel: seen.thermalLevel,
                                     seriousHeatFor: seen.seriousHeatFor) {
            var decision = turnOff(seen)
            decision.status = reason
            // An emergency: the lid being closed is enough. Heat under a lid is
            // what this limit is for, whatever else holds the Mac awake.
            decision.sleepNow = seen.lidClosed
            return decision
        }

        // A lid already closed with sleep still on: the Mac is on its way to sleep,
        // or woke for a moment in a bag. Holding it awake now is not what anyone
        // asked for. A flag this helper had set and lost is another matter.
        if !seen.sleepDisabled && !seen.hasMarker && seen.lidClosed && seen.lidCausesSleep {
            return LidGuardDecision(status: .off)
        }

        var decision = LidGuardDecision(status: .on, next: .keepRunning)
        if !seen.sleepDisabled {
            // Also after someone else turned it off: it is put back at each check.
            decision.setSleepDisabled = true
            decision.writeMarker = !seen.hasMarker
        }
        return decision
    }

    /// Only a flag this helper set is turned off. With the marker there it is turned
    /// off whatever a read says: a read that fails must not leave the Mac awake.
    private static func turnOff(_ seen: LidGuardObservation) -> LidGuardDecision {
        guard seen.hasMarker else { return LidGuardDecision() }
        return LidGuardDecision(setSleepDisabled: false, removeMarker: true,
                                sleepNow: seen.lidClosed && seen.lidCausesSleep)
    }
}
