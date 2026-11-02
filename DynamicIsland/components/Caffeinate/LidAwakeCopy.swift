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

/// Everything "with the lid closed" can have to say, one state at a time.
enum LidAwakeRowState: Equatable, CaseIterable {
    case needsSetup, offInstalled
    case waitingForPassword, passwordCancelled, setupFailed, damagedCopy, moveToApplications
    case waitingForSession, checking, ready, readyLidClosed, foreign
    case stoppedBattery, stoppedHeat, helperOff, failed, helperSilent
    case otherUser, outdated, stuck, removed, removalFailed

    enum Action: Equatable { case install, turnOnAgain, openLoginItems, fixStuckSleep }

    struct Situation {
        var install = LidGuardInstaller.State.missing
        var optionOn = false
        var isInstalling = false
        var setupOutcome: LidGuardInstaller.Outcome?
        var removal: LidAwakeController.Removal?
        var isStuck = false
        var canInstallFromHere = true
        var sessionActive = false
        var phase = LidAwakePhase.idle
        var lidClosed = false
    }

    static func resolve(_ now: Situation) -> LidAwakeRowState {
        if now.isInstalling { return .waitingForPassword }
        if now.isStuck { return .stuck }
        if let removal = now.removal { return removal == .done ? .removed : .removalFailed }
        switch now.setupOutcome {
        case .cancelled: return .passwordCancelled
        case .failed: return .setupFailed
        case .damaged: return .damagedCopy
        case .done, .none: break
        }
        guard now.install == .current else {
            if !now.canInstallFromHere { return .moveToApplications }
            switch now.install {
            case .otherUser: return .otherUser
            case .outdated: return .outdated
            default: return .needsSetup
            }
        }
        guard now.optionOn else { return .offInstalled }
        switch now.phase {
        case .stopped(.battery): return .stoppedBattery
        case .stopped(.thermal): return .stoppedHeat
        case .idle: return now.sessionActive ? .checking : .waitingForSession
        case .arming: return .checking
        case .ready: return now.lidClosed ? .readyLidClosed : .ready
        case .foreign: return .foreign
        case .helperOff: return .helperOff
        case .failed: return .failed
        case .helperSilent: return .helperSilent
        }
    }

    var text: String {
        let floor = LidGuardInstaller.chosenBatteryFloor
        switch self {
        case .needsSetup:
            return String(localized: "The Mac stays awake with the lid closed, even on battery with no display. Asks for your password once, and macOS will report a new background item.")
        case .offInstalled:
            return String(localized: "The Mac stays awake with the lid closed, even on battery with no display.")
        case .waitingForPassword:
            return String(localized: "Waiting for your password…")
        case .passwordCancelled:
            return String(localized: "No password entered. Nothing changed.")
        case .setupFailed:
            return String(localized: "Couldn't install the helper. If it is switched off in Login Items, turn it on and try again.")
        case .damagedCopy:
            return String(localized: "This copy of Luoto is damaged. Download it again.")
        case .moveToApplications:
            return String(localized: "Move Luoto to Applications first.")
        case .waitingForSession:
            return String(localized: "Works while Keep Awake is on.")
        case .checking:
            return String(localized: "Checking… Keep the lid open for now.")
        case .ready:
            return String(format: String(localized: "You can close the lid. Don't put the Mac in a bag. With the lid closed it sleeps at %d%% battery or if it overheats."), floor)
        case .readyLidClosed:
            return String(localized: "Lid closed, Mac running. The built-in mic and camera are off.")
        case .foreign:
            return String(localized: "Another tool has already turned sleep off. Luoto leaves that setting alone, so the battery and heat limits won't apply.")
        case .stoppedBattery:
            return String(localized: "Stopped because of low battery. Closing the lid puts the Mac to sleep again. Plug in and turn it on again.")
        case .stoppedHeat:
            return String(localized: "Stopped: the Mac got too hot. Closing the lid puts it to sleep again. Let it cool down and turn it on again.")
        case .helperOff:
            return String(localized: "The helper is switched off. In System Settings, open General → Login Items & Extensions and turn on the item ending in luoto.lidguard.")
        case .failed:
            return String(localized: "It didn't work: sleep is still on. Don't close the lid, the Mac will sleep.")
        case .helperSilent:
            return String(localized: "Luoto's helper isn't answering, so nothing is watching the battery or the heat. The Mac stays awake with the lid closed. Try again, or turn this off.")
        case .otherUser:
            return String(localized: "Another user on this Mac installed the helper. It doesn't work for you yet.")
        case .outdated:
            return String(localized: "The helper needs an update, which asks for your password.")
        case .stuck:
            return String(localized: "Sleep was left off after a problem. Fix it with your password?")
        case .removed:
            return String(localized: "The helper is removed.")
        case .removalFailed:
            return String(localized: "Couldn't remove it. The README explains how to do it by hand.")
        }
    }

    var isAttention: Bool {
        switch self {
        case .setupFailed, .damagedCopy, .stoppedBattery, .stoppedHeat, .helperOff, .failed, .helperSilent, .stuck, .removalFailed:
            return true
        default:
            return false
        }
    }

    var button: (title: String, action: Action)? {
        switch self {
        case .setupFailed: return (String(localized: "Try Again"), .install)
        case .stoppedBattery, .stoppedHeat: return (String(localized: "Turn On Again"), .turnOnAgain)
        case .helperOff: return (String(localized: "Open Settings"), .openLoginItems)
        case .failed, .helperSilent: return (String(localized: "Try Again"), .turnOnAgain)
        case .otherUser: return (String(localized: "Install for Me"), .install)
        case .outdated: return (String(localized: "Update"), .install)
        case .stuck: return (LidAwakeCopy.fixIt, .fixStuckSleep)
        default: return nil
        }
    }
}

enum LidAwakeCopy {
    static var title: String { String(localized: "With the lid closed") }
    static var settingsTitle: String { String(localized: "Keep awake with the lid closed") }
    static var removeHelper: String { String(localized: "Remove Helper") }
    static var sleepAtBattery: String { String(localized: "Sleep at battery level") }
    static func percent(_ value: Int) -> String { String(format: String(localized: "%d%%"), value) }
    static var settingsFooter: String {
        String(localized: "With the lid closed, Luoto turns system sleep off through a small helper that acts only during a session. The built-in microphone and camera don't work under a closed lid, and Sleep in the Apple menu does nothing while it acts.")
    }
    static var fixIt: String { String(localized: "Fix It") }
    static var notNow: String { String(localized: "Not Now") }
    static var stuckAlertTitle: String { String(localized: "This Mac cannot sleep right now") }
    static var stuckAlertBody: String {
        String(localized: "Luoto's helper turned sleep off and no longer answers. Your password puts this right.")
    }
    static var canClose: String { String(localized: "lid can be closed") }
    static var needsAttention: String { String(localized: "needs attention") }
}
