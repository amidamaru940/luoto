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

import AppKit
import Defaults
import IOKit.pwr_mgt
import SwiftUI
import XCTest
@testable import Atoll

/// Covers the two pure pieces of the caffeinate feature: when a session ends,
/// and how the countdown reads. The assertion itself is IOKit state, so it is
/// not exercised here.
final class CaffeinateManagerTests: XCTestCase {

    // MARK: - expiry

    func testIndefiniteSessionNeverExpires() {
        XCTAssertNil(CaffeinateManager.expiry(from: Date(), duration: .indefinite))
    }

    func testTimedSessionExpiresAfterItsDuration() {
        let start = Date(timeIntervalSince1970: 1_000_000)

        for duration in CaffeinateDuration.allCases {
            guard let seconds = duration.seconds else { continue }
            let expiry = CaffeinateManager.expiry(from: start, duration: duration)
            XCTAssertEqual(
                expiry?.timeIntervalSince(start),
                seconds,
                "\(duration.rawValue) should expire exactly \(seconds)s after it starts"
            )
        }
    }

    func testDurationsAreOrderedAndDistinct() {
        // The popover renders `allCases` in declaration order, so a duration
        // list that is not ascending would read as a shuffled menu.
        let seconds = CaffeinateDuration.allCases.compactMap(\.seconds)
        XCTAssertEqual(seconds, seconds.sorted())
        XCTAssertEqual(Set(seconds).count, seconds.count)
    }

    // MARK: - remainingLabel

    func testLabelUnderAnHourOmitsTheHourField() {
        XCTAssertEqual(CaffeinateManager.remainingLabel(0), "0:00")
        XCTAssertEqual(CaffeinateManager.remainingLabel(59), "0:59")
        XCTAssertEqual(CaffeinateManager.remainingLabel(60), "1:00")
        XCTAssertEqual(CaffeinateManager.remainingLabel(15 * 60), "15:00")
        XCTAssertEqual(CaffeinateManager.remainingLabel(3599), "59:59")
    }

    func testLabelAtOrAboveAnHourIncludesIt() {
        XCTAssertEqual(CaffeinateManager.remainingLabel(3600), "1:00:00")
        XCTAssertEqual(CaffeinateManager.remainingLabel(3661), "1:01:01")
        XCTAssertEqual(CaffeinateManager.remainingLabel(4 * 60 * 60), "4:00:00")
    }

    func testLabelRoundsUpSoTheFinalSecondIsNotShownAsZero() {
        // Truncating instead would show "0:00" for the whole last second,
        // which reads as a session that has already ended.
        XCTAssertEqual(CaffeinateManager.remainingLabel(0.4), "0:01")
        XCTAssertEqual(CaffeinateManager.remainingLabel(59.5), "1:00")
    }

    func testNegativeRemainderClampsToZero() {
        // The ticker deactivates at <= 0, but a late tick can still arrive with
        // a negative interval; it must not render as "-1:-1".
        XCTAssertEqual(CaffeinateManager.remainingLabel(-5), "0:00")
    }
}

/// A helper with nothing to report does not notice its reader has gone.
final class AdapterProcessesTests: XCTestCase {
    func testQuittingStopsWhatIsRunning() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        AdapterProcesses.track(process)
        AdapterProcesses.stopAll()
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
    }
}

/// The decisions of the root helper. Nothing here touches the Mac.
final class LidGuardPolicyTests: XCTestCase {
    private func seen(_ change: (inout LidGuardObservation) -> Void) -> LidGuardObservation {
        var observation = LidGuardObservation()
        observation.leaseAge = 1
        change(&observation)
        return observation
    }

    func testFreshLeaseTurnsTheFlagOnAndClaimsIt() {
        let decision = LidGuardPolicy.decide(seen { _ in })
        XCTAssertEqual(decision.setSleepDisabled, true)
        XCTAssertTrue(decision.writeMarker)
        XCTAssertEqual(decision.status, .on)
        XCTAssertEqual(decision.next, .keepRunning)
    }

    func testAFlagFoundOnStaysSomeoneElses() {
        let running = LidGuardPolicy.decide(seen { $0.sleepDisabled = true })
        XCTAssertNil(running.setSleepDisabled)
        XCTAssertFalse(running.writeMarker)
        XCTAssertEqual(running.status, .foreign)
        XCTAssertEqual(running.next, .keepRunning)

        let lowBattery = LidGuardPolicy.decide(seen { $0.sleepDisabled = true; $0.onBattery = true; $0.batteryPercent = 5 })
        XCTAssertEqual(lowBattery.status, .foreign, "There is nothing of Luoto's to turn off, so no stop is claimed")

        let ended = LidGuardPolicy.decide(seen { $0.leaseAge = nil; $0.sleepDisabled = true })
        XCTAssertNil(ended.setSleepDisabled, "A flag the helper did not set is not the helper's to clear")
        XCTAssertFalse(ended.sleepNow)
    }

    func testAFlagTurnedOffBehindItsBackIsPutBack() {
        let decision = LidGuardPolicy.decide(seen { $0.hasMarker = true })
        XCTAssertEqual(decision.setSleepDisabled, true)
        XCTAssertFalse(decision.writeMarker)
    }

    func testLeaseAges() {
        XCTAssertTrue(LidGuardPolicy.isLeaseFresh(age: 0))
        XCTAssertTrue(LidGuardPolicy.isLeaseFresh(age: LidGuardConfig.leaseLifetime))
        XCTAssertFalse(LidGuardPolicy.isLeaseFresh(age: LidGuardConfig.leaseLifetime + 1))
        XCTAssertFalse(LidGuardPolicy.isLeaseFresh(age: nil))
        XCTAssertTrue(LidGuardPolicy.isLeaseFresh(age: -LidGuardConfig.futureTolerance))
        XCTAssertFalse(LidGuardPolicy.isLeaseFresh(age: -3600), "A file dated in the future must not hold the Mac awake")
    }

    func testAStaleLeaseEndsTheSessionAndSleepsAClosedLid() {
        let decision = LidGuardPolicy.decide(seen {
            $0.leaseAge = 3600; $0.hasMarker = true; $0.sleepDisabled = true; $0.lidClosed = true
        })
        XCTAssertEqual(decision.setSleepDisabled, false)
        XCTAssertTrue(decision.removeMarker)
        XCTAssertTrue(decision.sleepNow)
        XCTAssertEqual(decision.status, .off)
        XCTAssertEqual(decision.next, .exit)
    }

    func testEndingWithTheLidOpenDoesNotSleep() {
        let decision = LidGuardPolicy.decide(seen { $0.leaseAge = nil; $0.hasMarker = true; $0.sleepDisabled = true })
        XCTAssertEqual(decision.setSleepDisabled, false)
        XCTAssertFalse(decision.sleepNow)
    }

    func testEndingOnAnExternalDisplayDoesNotSleep() {
        let decision = LidGuardPolicy.decide(seen {
            $0.leaseAge = nil; $0.hasMarker = true; $0.sleepDisabled = true; $0.lidClosed = true; $0.lidCausesSleep = false
        })
        XCTAssertEqual(decision.setSleepDisabled, false)
        XCTAssertFalse(decision.sleepNow)
    }

    func testLowBatteryStopsAndSleepsAClosedLidWhateverElseHoldsIt() {
        let decision = LidGuardPolicy.decide(seen {
            $0.hasMarker = true; $0.sleepDisabled = true; $0.onBattery = true
            $0.batteryPercent = LidGuardConfig.batteryFloor; $0.lidClosed = true; $0.lidCausesSleep = false
        })
        XCTAssertEqual(decision.setSleepDisabled, false)
        XCTAssertEqual(decision.status, .battery)
        XCTAssertTrue(decision.sleepNow)
        XCTAssertEqual(decision.next, .exit)
    }

    func testTheChosenFloorIsTheLimit() {
        XCTAssertEqual(LidGuardPolicy.limitReached(onBattery: true, batteryPercent: 50, batteryFloor: 50, thermalLevel: 0, seriousHeatFor: 0), .battery)
        XCTAssertNil(LidGuardPolicy.limitReached(onBattery: true, batteryPercent: 51, batteryFloor: 50, thermalLevel: 0, seriousHeatFor: 0))
        XCTAssertNil(LidGuardPolicy.limitReached(onBattery: true, batteryPercent: 11, batteryFloor: 10, thermalLevel: 0, seriousHeatFor: 0))
        XCTAssertEqual(LidGuardPolicy.decide(seen { $0.onBattery = true; $0.batteryPercent = 40; $0.batteryFloor = 50 }).status, .battery)
    }

    func testThereIsNoNeverAndTheDefaultIsAChoice() {
        XCTAssertTrue(LidGuardConfig.batteryFloors.contains(LidGuardConfig.batteryFloor))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(LidGuardConfig.batteryFloors.min()), 10)
    }

    func testABatteryThatCannotBeReadCountsAsLowAfterAWhile() {
        XCTAssertNil(LidGuardPolicy.limitReached(onBattery: false, batteryPercent: nil, batteryUnknownFor: LidGuardConfig.unknownBatteryLimit - 1, thermalLevel: 0, seriousHeatFor: 0))
        XCTAssertEqual(LidGuardPolicy.limitReached(onBattery: false, batteryPercent: nil, batteryUnknownFor: LidGuardConfig.unknownBatteryLimit, thermalLevel: 0, seriousHeatFor: 0), .battery)
    }

    func testTheFlagIsNotTurnedOnUnderALidAlreadyClosed() {
        let decision = LidGuardPolicy.decide(seen { $0.lidClosed = true })
        XCTAssertNil(decision.setSleepDisabled, "The Mac is on its way to sleep, or woke for a moment in a bag")
        XCTAssertFalse(decision.writeMarker)
        XCTAssertEqual(decision.next, .exit)
    }

    func testAFlagLostUnderTheClosedLidIsPutBack() {
        let decision = LidGuardPolicy.decide(seen { $0.lidClosed = true; $0.hasMarker = true })
        XCTAssertEqual(decision.setSleepDisabled, true)
        XCTAssertEqual(decision.next, .keepRunning)
    }

    func testAClosedLidOnAnExternalDisplayCanStillBeArmed() {
        let decision = LidGuardPolicy.decide(seen { $0.lidClosed = true; $0.lidCausesSleep = false })
        XCTAssertEqual(decision.setSleepDisabled, true)
    }

    func testTheMarkerMeansTurnOffEvenIfTheReadSaysOff() {
        let decision = LidGuardPolicy.decide(seen { $0.leaseAge = nil; $0.hasMarker = true; $0.sleepDisabled = false })
        XCTAssertEqual(decision.setSleepDisabled, false, "A failed read must not leave the Mac awake")
        XCTAssertTrue(decision.removeMarker)
    }

    func testBatteryLimitDoesNotApplyOnPowerOrAboveTheFloor() {
        XCTAssertNil(LidGuardPolicy.limitReached(onBattery: false, batteryPercent: 5, thermalLevel: 0, seriousHeatFor: 0))
        XCTAssertNil(LidGuardPolicy.limitReached(onBattery: true, batteryPercent: LidGuardConfig.batteryFloor + 1, thermalLevel: 0, seriousHeatFor: 0))
        XCTAssertNil(LidGuardPolicy.limitReached(onBattery: true, batteryPercent: nil, thermalLevel: 0, seriousHeatFor: 0))
    }

    func testHeatLimits() {
        XCTAssertEqual(LidGuardPolicy.limitReached(onBattery: false, batteryPercent: nil, thermalLevel: 3, seriousHeatFor: 0), .thermal)
        XCTAssertNil(LidGuardPolicy.limitReached(onBattery: false, batteryPercent: nil, thermalLevel: 2, seriousHeatFor: LidGuardConfig.seriousHeatLimit - 1))
        XCTAssertEqual(LidGuardPolicy.limitReached(onBattery: false, batteryPercent: nil, thermalLevel: 2, seriousHeatFor: LidGuardConfig.seriousHeatLimit), .thermal)
        XCTAssertNil(LidGuardPolicy.limitReached(onBattery: false, batteryPercent: nil, thermalLevel: 1, seriousHeatFor: 9999))
    }

    func testAStopLastsUntilTheLeaseIsTakenAway() {
        let heartbeat = LidGuardPolicy.decide(seen { $0.status = .battery })
        XCTAssertNil(heartbeat.setSleepDisabled, "The next heartbeat must not turn it back on")
        XCTAssertNil(heartbeat.status)
        XCTAssertEqual(heartbeat.next, .exit)

        // The app may be dead: the stop stays readable next to the old lease.
        XCTAssertNil(LidGuardPolicy.decide(seen { $0.status = .battery; $0.leaseAge = 3600 }).status)
        XCTAssertEqual(LidGuardPolicy.decide(seen { $0.status = .battery; $0.leaseAge = nil }).status, .off)
    }

    func testAGoneAppRemovesTheHelperUnlessALeaseIsFresh() {
        XCTAssertEqual(LidGuardPolicy.decide(seen { $0.leaseAge = nil; $0.appGone = true }).next, .removeSelf)
        XCTAssertEqual(LidGuardPolicy.decide(seen { $0.leaseAge = 3600; $0.appGone = true }).next, .removeSelf)
        XCTAssertEqual(LidGuardPolicy.decide(seen { $0.appGone = true }).next, .keepRunning)
    }

    func testAnAppMissingForAMomentIsWaitedFor() {
        XCTAssertEqual(LidGuardPolicy.decide(seen { $0.leaseAge = nil; $0.appMissing = true }).next, .keepRunning)
    }

    func testUninstallFirstTurnsOff() {
        let decision = LidGuardPolicy.decide(seen {
            $0.uninstallRequested = true; $0.hasMarker = true; $0.sleepDisabled = true
        })
        XCTAssertEqual(decision.setSleepDisabled, false)
        XCTAssertEqual(decision.next, .removeSelf)
    }
}

private extension Data {
    func write(to url: URL, withIntermediate: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(to: url)
    }
}

/// The real helper binary, run as this user in a throwaway folder with a fake
/// `pmset`, through its debug-only test root. It changes nothing on the Mac.
final class LidGuardHelperEndToEndTests: XCTestCase {
    private var root: URL!
    private var helper: Process?
    private var appPath: URL { root.appendingPathComponent("Luoto.app") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lidguard-\(UUID().uuidString)")
        for folder in ["session", "support", "sim", "Luoto.app"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("plist"))
        try Data().write(to: root.appendingPathComponent("helper"))
        // `sim/pmset-fails` makes it fail and change nothing; `sim/pmset-slow` makes
        // the flag change only a moment after it returns, as a kernel may.
        let script = """
        #!/bin/sh
        echo "$*" >> '\(root.path)/pmset.log'
        [ -e '\(root.path)/sim/pmset-fails' ] && exit 1
        delay=''
        [ -e '\(root.path)/sim/pmset-slow' ] && delay='/bin/sleep 0.5;'
        case "$*" in
          "-a disablesleep 1") echo 1 > '\(root.path)/sim/flag' ;;
          "-a disablesleep 0") /bin/sh -c "$delay echo 0 > '\(root.path)/sim/flag'" & ;;
        esac
        exit 0
        """
        let fake = root.appendingPathComponent("fake-pmset")
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    }

    override func tearDownWithError() throws {
        if let helper, helper.isRunning { helper.terminate(); helper.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }

    private func simulate(_ name: String, _ value: String) throws {
        try value.write(to: root.appendingPathComponent("sim/\(name)"), atomically: true, encoding: .utf8)
    }

    private var flag: String {
        ((try? String(contentsOf: root.appendingPathComponent("sim/flag"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var status: String {
        (try? String(contentsOf: root.appendingPathComponent("support/status"), encoding: .utf8)) ?? ""
    }

    private var pmsetCalls: [String] {
        ((try? String(contentsOf: root.appendingPathComponent("pmset.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private var hasMarker: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("support/marker").path)
    }

    private func renewLease(date: Date = Date()) throws {
        let lease = root.appendingPathComponent("session/lease")
        try Data().write(to: lease, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: lease.path)
    }

    private func removeLease() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("session/lease"))
    }

    private func startHelper(file: StaticString = #filePath, line: UInt = #line) throws {
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(LidGuardConfig.label)")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path), "The test host has no helper")
        let process = Process()
        process.executableURL = binary
        process.arguments = [appPath.path, "--test-root", root.path]
        try process.run()
        helper = process
    }

    private func waitUntil(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("Timed out waiting for: \(what). Status \(status), flag \(flag), calls \(pmsetCalls)", file: file, line: line)
    }

    private func waitForExit(file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("the helper to exit", file: file, line: line) { helper?.isRunning == false }
    }

    func testFreshLeaseThenRemovedLease() throws {
        try renewLease()
        try startHelper()
        waitUntil("flag on") { flag == "1" && status == "on" }
        XCTAssertTrue(hasMarker)
        XCTAssertEqual(pmsetCalls, ["-a disablesleep 1"])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(pmsetCalls.count, 1, "A flag that is on is left alone")

        try removeLease()
        waitForExit()
        XCTAssertEqual(flag, "0")
        XCTAssertEqual(status, "off")
        XCTAssertFalse(hasMarker)
        XCTAssertEqual(helper?.terminationStatus, 0)
        XCTAssertFalse(pmsetCalls.contains("sleepnow"), "The lid is open")
    }

    func testDeadAppWithClosedLidResetsAndSleeps() throws {
        try renewLease()
        try startHelper()
        waitUntil("flag on") { flag == "1" }
        try simulate("lid", "closed")

        try renewLease(date: Date().addingTimeInterval(-3600))
        waitForExit()
        XCTAssertEqual(flag, "0")
        XCTAssertEqual(pmsetCalls.last, "sleepnow", "`disablesleep 0` alone leaves a closed Mac awake")
    }

    func testAFailedTurnOffKeepsTheMarkerAndKeepsTrying() throws {
        try renewLease()
        try startHelper()
        waitUntil("flag on") { flag == "1" }
        try simulate("lid", "closed")

        try simulate("pmset-fails", "1")
        try removeLease()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(helper?.isRunning, true, "It must not walk away with sleep still off")
        XCTAssertTrue(hasMarker, "The flag is still its own to clear")
        XCTAssertFalse(pmsetCalls.contains("sleepnow"))

        try FileManager.default.removeItem(at: root.appendingPathComponent("sim/pmset-fails"))
        waitForExit()
        XCTAssertEqual(flag, "0")
        XCTAssertFalse(hasMarker)
        XCTAssertEqual(pmsetCalls.last, "sleepnow")
    }

    /// Nothing runs for ever with no session: it leaves the marker for the app to
    /// report and for the next start.
    func testItStopsTryingAfterAWhileAndLeavesTheMarker() throws {
        try renewLease()
        try startHelper()
        waitUntil("flag on") { flag == "1" }
        try simulate("pmset-fails", "1")
        try removeLease()
        waitForExit()
        XCTAssertEqual(helper?.terminationStatus, 0)
        XCTAssertTrue(hasMarker)
        XCTAssertEqual(flag, "1")
    }

    /// A macOS that drops the setting must not leave a root process running.
    func testAFlagThatCannotBeReadDoesNotKeepItRunning() throws {
        try renewLease()
        try startHelper()
        waitUntil("flag on") { flag == "1" }
        try simulate("lid", "closed")
        try simulate("flag-unreadable", "1")
        try removeLease()
        waitForExit()
        XCTAssertFalse(hasMarker)
        XCTAssertEqual(pmsetCalls.last, "sleepnow")
    }

    /// It goes, and leaves the marker: otherwise sleep would stay off, with no helper
    /// and nothing to tell the app.
    func testAskedToGoItGoesEvenIfTheFlagWouldNotComeOff() throws {
        try renewLease()
        try startHelper()
        waitUntil("flag on") { flag == "1" }
        try simulate("pmset-fails", "1")
        try Data().write(to: root.appendingPathComponent("session/uninstall"))
        waitForExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("plist").path))
        XCTAssertTrue(hasMarker, "The app must still be able to report this")
    }

    func testASecondTryAtAnEmergencyStillSleeps() throws {
        try simulate("causes", "no")
        try renewLease()
        try startHelper()
        waitUntil("flag on") { flag == "1" }
        try simulate("lid", "closed")
        try simulate("pmset-fails", "1")
        try simulate("thermal", "3")
        waitUntil("the stop") { status == "thermal" }
        XCTAssertFalse(pmsetCalls.contains("sleepnow"), "The flag is still on")
        try FileManager.default.removeItem(at: root.appendingPathComponent("sim/pmset-fails"))
        waitForExit()
        XCTAssertEqual(flag, "0")
        XCTAssertEqual(pmsetCalls.last, "sleepnow", "An emergency, whatever else holds the Mac awake")
    }

    /// A stop is written even if the flag would not come off, so the app hears of it.
    func testAStopIsReportedEvenIfTheFlagWouldNotComeOff() throws {
        try simulate("source", "battery")
        try simulate("percent", "80")
        try renewLease()
        try startHelper()
        waitUntil("flag on") { flag == "1" }
        try simulate("pmset-fails", "1")
        try simulate("percent", "10")
        waitUntil("the stop") { status == "battery" }
    }

    func testSleepIsAskedForOnlyAfterTheFlagReadsOff() throws {
        try simulate("pmset-slow", "1")
        try renewLease()
        try startHelper()
        waitUntil("flag on") { flag == "1" }
        try simulate("lid", "closed")
        try FileManager.default.removeItem(at: root.appendingPathComponent("session/lease"))
        let logged = root.appendingPathComponent("flag-when-sleeping")
        waitUntil("sleep asked for") {
            if pmsetCalls.contains("sleepnow") {
                try? flag.write(to: logged, atomically: true, encoding: .utf8)
                return true
            }
            return false
        }
        XCTAssertEqual(try String(contentsOf: logged, encoding: .utf8), "0")
    }

    func testNoFlagIfTheMarkerCannotBeWritten() throws {
        try renewLease()
        let support = root.appendingPathComponent("support")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: support.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path) }
        try startHelper()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(pmsetCalls, [], "Without the marker nothing could ever clear it")
    }

    func testAStatusIsRewrittenWhileRunningSoItsDateProvesTheHelperAlive() throws {
        try renewLease()
        try startHelper()
        waitUntil("status on") { status == "on" }
        let file = root.appendingPathComponent("support/status").path
        let first = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date)
        waitUntil("a newer status") {
            let date = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
            return (date ?? first) > first
        }
    }

    func testTheFlagIsNotTurnedOnUnderALidAlreadyClosed() throws {
        try simulate("lid", "closed")
        try renewLease()
        try startHelper()
        waitForExit()
        XCTAssertEqual(pmsetCalls, [])
    }

    func testABatteryThatCannotBeReadEndsTheSession() throws {
        try renewLease()
        try simulate("source", "unknown")
        try startHelper()
        waitUntil("the battery limit") { status == "battery" }
    }

    func testAnAppPathItMayNotLookAtIsNotGone() throws {
        // As macOS answers a daemon about Desktop: an error, but not "no such file".
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(LidGuardConfig.label)")
        let process = Process()
        process.executableURL = binary
        process.arguments = [locked.appendingPathComponent("Luoto.app").path, "--test-root", root.path]
        try process.run()
        helper = process
        waitForExit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("plist").path))
    }

    func testBootAfterAPowerCutResetsALeftoverFlag() throws {
        try simulate("flag", "1")
        try Data().write(to: root.appendingPathComponent("support/marker"))
        try renewLease(date: Date().addingTimeInterval(-86400))
        try startHelper()
        waitForExit()
        XCTAssertEqual(flag, "0")
        XCTAssertFalse(hasMarker)
    }

    func testAFutureDateIsNotALease() throws {
        try renewLease(date: Date().addingTimeInterval(86400))
        try startHelper()
        waitForExit()
        XCTAssertEqual(pmsetCalls, [])
    }

    func testALinkOrAFolderIsNotALease() throws {
        let target = root.appendingPathComponent("elsewhere")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("session/lease"), withDestinationURL: target)
        try startHelper()
        waitForExit()
        XCTAssertEqual(pmsetCalls, [])

        try removeLease()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("session/lease"), withIntermediateDirectories: false)
        try startHelper()
        waitForExit()
        XCTAssertEqual(pmsetCalls, [])
    }

    func testTerminationLeavesNothingOn() throws {
        try renewLease()
        try startHelper()
        waitUntil("flag on") { flag == "1" }
        try simulate("lid", "closed")
        helper?.terminate()
        waitForExit()
        XCTAssertEqual(flag, "0")
        XCTAssertFalse(hasMarker)
        XCTAssertFalse(pmsetCalls.contains("sleepnow"), "Shutting down, not sleeping")
    }

    func testLowBatteryStopsAndStaysStoppedUntilTheLeaseGoes() throws {
        try simulate("source", "battery")
        try simulate("percent", "80")
        try renewLease()
        try startHelper()
        waitUntil("flag on") { flag == "1" }
        try simulate("lid", "closed")

        try simulate("percent", "\(LidGuardConfig.batteryFloor)")
        waitForExit()
        XCTAssertEqual(flag, "0")
        XCTAssertEqual(status, "battery")
        XCTAssertEqual(pmsetCalls.last, "sleepnow")

        // launchd starts it again on the next heartbeat. It must stay off.
        try simulate("percent", "90")
        try renewLease()
        try startHelper()
        waitForExit()
        XCTAssertEqual(flag, "0")
        XCTAssertEqual(status, "battery")

        try removeLease()
        try startHelper()
        waitForExit()
        XCTAssertEqual(status, "off")
    }

    func testTheHelperUsesTheFloorChosenByName() throws {
        try simulate("source", "battery")
        try simulate("percent", "40")
        try renewLease()
        try startHelper()
        waitUntil("running: 40 is above the default floor") { flag == "1" && status == "on" }

        try Data().write(to: root.appendingPathComponent("session/\(LidGuardConfig.floorName(50))"))
        waitUntil("the stop at the chosen floor") { status == "battery" }
    }

    func testTheHighestChosenFloorWinsAndOtherNamesMeanNothing() throws {
        for name in [LidGuardConfig.floorName(10), LidGuardConfig.floorName(30), "floor-99", "floor-1"] {
            try Data().write(to: root.appendingPathComponent("session/\(name)"))
        }
        try simulate("source", "battery")
        try simulate("percent", "25")
        try renewLease()
        try startHelper()
        waitForExit()
        XCTAssertEqual(status, "battery", "30 counts, not 10")
    }

    func testALowerChosenFloorLetsItRunBelowTheDefault() throws {
        try Data().write(to: root.appendingPathComponent("session/\(LidGuardConfig.floorName(10))"))
        try simulate("source", "battery")
        try simulate("percent", "15")
        try renewLease()
        try startHelper()
        waitUntil("running below the default floor") { flag == "1" && status == "on" }
    }

    func testRemovalTakesTheFloorNamesToo() throws {
        try Data().write(to: root.appendingPathComponent("session/\(LidGuardConfig.floorName(50))"))
        try Data().write(to: root.appendingPathComponent("session/uninstall"))
        try startHelper()
        waitForExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("session").path))
    }

    func testCriticalHeatStops() throws {
        try renewLease()
        try startHelper()
        waitUntil("flag on") { flag == "1" }
        try simulate("thermal", "3")
        waitForExit()
        XCTAssertEqual(flag, "0")
        XCTAssertEqual(status, "thermal")
    }

    func testRollBackIsPutBack() throws {
        try renewLease()
        try startHelper()
        waitUntil("flag on") { flag == "1" }
        try simulate("flag", "0")
        waitUntil("flag back on") { flag == "1" }
        XCTAssertEqual(pmsetCalls, ["-a disablesleep 1", "-a disablesleep 1"])
    }

    func testSomeoneElsesFlagIsNeverCleared() throws {
        try simulate("flag", "1")
        try renewLease()
        try startHelper()
        waitUntil("status foreign") { status == "foreign" }
        try removeLease()
        waitForExit()
        XCTAssertEqual(flag, "1")
        XCTAssertEqual(pmsetCalls, [])
    }

    func testUninstallRemovesItsFiles() throws {
        try Data().write(to: root.appendingPathComponent("session/uninstall"))
        try Data().write(to: root.appendingPathComponent("support/version"))
        try startHelper()
        waitForExit()
        for name in ["plist", "helper", "support", "session"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), name)
        }
    }

    func testRemovalNeverWalksTheUsersFolder() throws {
        let victim = root.appendingPathComponent("victim")
        try Data().write(to: victim.appendingPathComponent("precious"), withIntermediate: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("session/link"), withDestinationURL: victim)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("session/mine"), withIntermediateDirectories: false)
        try Data().write(to: root.appendingPathComponent("session/mine/file"))
        try Data().write(to: root.appendingPathComponent("session/uninstall"))
        try startHelper()
        waitForExit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.appendingPathComponent("precious").path), "A link is not followed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("session/mine/file").path), "The user's own files stay")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("plist").path))
    }

    func testAnAppGoneForGoodRemovesTheHelper() throws {
        try FileManager.default.removeItem(at: appPath)
        try startHelper()
        waitForExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("plist").path))
    }

    func testAnAppBackInTimeKeepsTheHelper() throws {
        try FileManager.default.removeItem(at: appPath)
        try startHelper()
        Thread.sleep(forTimeInterval: 0.2)
        try FileManager.default.createDirectory(at: appPath, withIntermediateDirectories: false)
        waitForExit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("plist").path))
    }

    func testThePermissionsOfALeaseDoNotMatterBecauseItIsNeverOpened() throws {
        try renewLease()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent("session/lease").path)
        try startHelper()
        waitUntil("flag on") { flag == "1" }
    }
}

/// The app's side of "with the lid closed": what it would run as root, and what
/// it says. Nothing here asks for a password.
final class LidAwakeAppTests: XCTestCase {
    private func script(helper: String = "/Applications/Luoto.app/Contents/Helpers/x",
                        requirement: String? = "identifier \"a\" and certificate leaf = H\"00\"") -> String {
        LidGuardInstaller.shellScript(bundledHelper: helper, user: 501, group: 20,
                                      plist: LidGuardInstaller.launchdPlist(appPath: "/Applications/Luoto.app"),
                                      requirement: requirement)
    }

    private func next(_ phase: LidAwakePhase, status: LidGuardStatus = .on, fresh: Bool = true, flag: Bool = false,
                      since seconds: TimeInterval = 0, lost: inout Date?, switchedOff: Bool = false) -> LidAwakePhase {
        let start = Date(timeIntervalSince1970: 1_000)
        return LidAwakeController.nextPhase(from: phase, status: status, statusFresh: fresh, flagOn: flag, armedAt: start,
                                            troubleSince: &lost, now: start.addingTimeInterval(seconds), helperSwitchedOff: switchedOff)
    }

    func testTheSetupScriptIsValidShell() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lidguard-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: file) }
        try script().write(to: file, atomically: true, encoding: .utf8)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-n", file.path]
        try shell.run()
        shell.waitUntilExit()
        XCTAssertEqual(shell.terminationStatus, 0)
    }

    func testRootRunsOnlyARootOwnedCopyAndChecksItsSignatureThere() throws {
        let text = script()
        let copy = LidGuardInstaller.quoted(LidGuardConfig.helperPath + ".new")
        let owned = try XCTUnwrap(text.range(of: "/usr/bin/install -o root -g wheel -m 700 "))
        let checked = try XCTUnwrap(text.range(of: "/usr/bin/codesign --verify --strict -R="))
        let moved = try XCTUnwrap(text.range(of: "/bin/mv -f \(copy)"))
        XCTAssertLessThan(owned.lowerBound, checked.lowerBound)
        XCTAssertLessThan(checked.lowerBound, moved.lowerBound)
        XCTAssertTrue(text.hasPrefix("set -e\numask 022\n"), "A failed step must stop everything after it")
        XCTAssertTrue(text.contains("|| exit \(LidGuardInstaller.signatureExitCode)"))
    }

    /// The bundled file is the user's to change. Pointed at a root-only file, its
    /// copy must never be readable by anyone else.
    func testTheCopyIsUnreadableUntilItsSignatureIsChecked() throws {
        let text = script()
        let private700 = try XCTUnwrap(text.range(of: "-m 700 "))
        let checked = try XCTUnwrap(text.range(of: "/usr/bin/codesign --verify"))
        let opened = try XCTUnwrap(text.range(of: "/bin/chmod 755 \(LidGuardInstaller.quoted(LidGuardConfig.helperPath + ".new"))"))
        XCTAssertLessThan(private700.lowerBound, checked.lowerBound)
        XCTAssertLessThan(checked.lowerBound, opened.lowerBound)
        XCTAssertFalse(text.contains("-m 755"))
    }

    func testAPlantedLinkIsRefused() {
        let text = script()
        let source = LidGuardInstaller.quoted("/Applications/Luoto.app/Contents/Helpers/x")
        XCTAssertTrue(text.contains("if [ ! -f \(source) ] || [ -L \(source) ]; then exit \(LidGuardInstaller.refusedExitCode); fi"))
        let support = LidGuardInstaller.quoted(LidGuardConfig.supportDirectory)
        let session = LidGuardInstaller.quoted(LidGuardConfig.sessionDirectory)
        XCTAssertTrue(text.contains("if [ -L \(support) ] || [ -L \(session) ]; then exit \(LidGuardInstaller.refusedExitCode); fi"))
        XCTAssertTrue(text.contains("/usr/sbin/chown -h 501:20 \(session)"), "chown must not follow a link")
        XCTAssertFalse(text.contains("chown -R"))
    }

    func testAnAdHocCopyIsStillCheckedToBeSignedCode() {
        let text = script(requirement: nil)
        XCTAssertTrue(text.contains("/usr/bin/codesign --verify --strict '"))
        XCTAssertFalse(text.contains("-R="))
    }

    func testRequirementNamesTheHelperAndTheCertificate() {
        let requirement = LidGuardInstaller.requirement(leafCertificate: Data([1, 2, 3]))
        XCTAssertTrue(requirement.hasPrefix("identifier \"\(LidGuardConfig.label)\" and certificate leaf = H\""))
    }

    func testWhatReachesRootsShellIsFiltered() {
        for name in ["SHELLOPTS", "PS4", "BASH_ENV", "ENV", "BASHOPTS", "BASH_FUNC_x%%", "__BASH_FUNC</usr/bin/true>()",
                     "DYLD_INSERT_LIBRARIES"] {
            XCTAssertTrue(ChildProcessEnvironment.isInjection(name), name)
        }
        XCTAssertTrue(ChildProcessEnvironment.isExportedFunction(value: "() { echo shadow; }"))
        XCTAssertFalse(ChildProcessEnvironment.isExportedFunction(value: "/usr/bin"))
        XCTAssertEqual(ChildProcessEnvironment.sanitized(["A": "() { x; }", "PATH": "/usr/bin", "PS4": "$(x)"]), ["PATH": "/usr/bin"])
    }

    func testThisProcessLosesThemItself() {
        setenv("PS4", "$(/tmp/x)", 1)
        setenv("__BASH_FUNC</usr/bin/true>()", "() { echo shadow; }", 1)
        setenv("LUOTO_INNOCENT_LOOKING", "() { echo shadow; }", 1)
        setenv("LUOTO_REALLY_INNOCENT", "value", 1)
        defer { unsetenv("LUOTO_REALLY_INNOCENT") }
        ChildProcessEnvironment.removeInjectionVariablesFromThisProcess()
        XCTAssertNil(getenv("PS4"))
        XCTAssertNil(getenv("__BASH_FUNC</usr/bin/true>()"))
        XCTAssertNil(getenv("LUOTO_INNOCENT_LOOKING"))
        XCTAssertNotNil(getenv("LUOTO_REALLY_INNOCENT"))
    }

    /// Run for real as this user: both refusals come before anything is touched.
    func testTheScriptRefusesALinkOrAMissingFileWithItsExitCode() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lidguard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("secret")
        try Data().write(to: target)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        for source in [link.path, folder.appendingPathComponent("nothing").path] {
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", script(helper: source)]
            try shell.run()
            shell.waitUntilExit()
            XCTAssertEqual(shell.terminationStatus, Int32(LidGuardInstaller.refusedExitCode), source)
        }
    }

    func testThisAppsOwnSignatureCanBeRead() {
        XCTAssertNotEqual(LidGuardInstaller.signature(), .unreadable)
    }

    func testNothingIsWrittenThroughATemporaryFileOfTheUsers() {
        XCTAssertFalse(script().contains("/tmp/"))
        XCTAssertFalse(script().contains("/var/folders/"))
    }

    func testEveryCommandInTheScriptIsAbsolute() {
        for line in script().split(separator: "\n") {
            let first = line.split(separator: " ").first.map(String.init) ?? ""
            if ["set", "umask", "trap", "for", "if", "loaded=0"].contains(first) { continue }
            XCTAssertTrue(first.hasPrefix("/"), "Not absolute: \(line)")
        }
    }

    func testTheSessionFolderGoesToANumericUser() {
        XCTAssertTrue(script().contains("/usr/sbin/chown -h 501:20 "))
    }

    func testTheAppPathCannotBreakOutOfItsQuotes() throws {
        XCTAssertEqual(LidGuardInstaller.quoted("a'b c"), "'a'\\''b c'")
        XCTAssertTrue(script(helper: "/Users/x/it's; rm -rf ~/Luoto.app/h").contains("'/Users/x/it'\\''s; rm -rf ~/Luoto.app/h'"))
    }

    func testThePlistWakesTheHelperOnChangesAndAfterACrash() throws {
        let plist = LidGuardInstaller.launchdPlist(appPath: "/Applications/Luoto.app")
        let parsed = try XCTUnwrap(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        XCTAssertEqual(parsed["Label"] as? String, LidGuardConfig.label)
        XCTAssertEqual(parsed["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(parsed["WatchPaths"] as? [String], [LidGuardConfig.sessionDirectory])
        let keepAlive = try XCTUnwrap(parsed["KeepAlive"] as? [String: Bool])
        XCTAssertEqual(keepAlive["Crashed"], true)
        XCTAssertEqual(keepAlive["SuccessfulExit"], false)
        XCTAssertEqual(parsed["ProgramArguments"] as? [String], [LidGuardConfig.helperPath, "/Applications/Luoto.app"])
    }

    func testAnUpdateDoesNotAskForThePassword() {
        let same = LidGuardInstaller.resolve(version: String(LidGuardConfig.version), installedAppPath: "/Applications/Luoto.app",
                                             appPath: "/Applications/Luoto.app", sessionWritable: true)
        XCTAssertEqual(same, .current)
    }

    func testOtherInstallStates() {
        let version = String(LidGuardConfig.version)
        XCTAssertEqual(LidGuardInstaller.resolve(version: "0", installedAppPath: "/a", appPath: "/a", sessionWritable: true), .outdated)
        XCTAssertEqual(LidGuardInstaller.resolve(version: nil, installedAppPath: "/a", appPath: "/a", sessionWritable: true), .outdated)
        XCTAssertEqual(LidGuardInstaller.resolve(version: version, installedAppPath: "/b", appPath: "/a", sessionWritable: true), .outdated)
        XCTAssertEqual(LidGuardInstaller.resolve(version: version, installedAppPath: "/a", appPath: "/a", sessionWritable: false), .otherUser)
    }

    func testACopyThatWillVanishCannotInstall() {
        XCTAssertTrue(LidGuardInstaller.canInstall(fromAppPath: "/Applications/Luoto.app"))
        XCTAssertFalse(LidGuardInstaller.canInstall(fromAppPath: "/Volumes/Luoto 1.3.0/Luoto.app"))
        XCTAssertFalse(LidGuardInstaller.canInstall(fromAppPath: "/private/var/folders/x/AppTranslocation/y/d/Luoto.app"))
    }

    func testArmingGivesUpAfterItsLimitAndRecovers() {
        var lost: Date?
        XCTAssertEqual(next(.arming, since: LidAwakeController.armingLimit - 1, lost: &lost), .arming)
        XCTAssertEqual(next(.arming, since: LidAwakeController.armingLimit, lost: &lost), .failed)
        XCTAssertEqual(next(.arming, since: LidAwakeController.armingLimit, lost: &lost, switchedOff: true), .helperOff)
        XCTAssertEqual(next(.arming, flag: true, lost: &lost), .ready)
        XCTAssertEqual(next(.failed, flag: true, lost: &lost), .ready)
        XCTAssertEqual(next(.helperOff, flag: true, lost: &lost), .ready)
    }

    func testSomeoneElsesFlagIsReportedAsTheirs() {
        var lost: Date?
        XCTAssertEqual(next(.arming, status: .foreign, flag: true, lost: &lost), .foreign)
    }

    func testAFlagWithNoLiveHelperBehindItIsNotReady() {
        var lost: Date?
        XCTAssertEqual(next(.arming, status: .off, flag: true, lost: &lost), .arming, "Not the helper's word yet")
        XCTAssertEqual(next(.arming, status: .on, fresh: false, flag: true, lost: &lost), .arming, "The helper is not running")
        XCTAssertEqual(next(.arming, status: .on, fresh: false, flag: true, since: LidAwakeController.armingLimit, lost: &lost), .helperSilent)
        lost = nil
        XCTAssertEqual(next(.ready, status: .on, fresh: false, flag: true, lost: &lost), .ready)
        XCTAssertEqual(next(.ready, status: .on, fresh: false, flag: true, since: LidAwakeController.flagLossLimit, lost: &lost), .helperSilent)
    }

    func testAFlagOnWithASilentHelperIsSaidPlainly() {
        var lost: Date?
        XCTAssertEqual(next(.arming, status: .on, fresh: false, flag: true, since: LidAwakeController.armingLimit, lost: &lost), .helperSilent)
        XCTAssertEqual(next(.helperSilent, status: .on, fresh: true, flag: true, lost: &lost), .ready)
        XCTAssertEqual(LidAwakeRowState.resolve(.init(install: .current, optionOn: true, sessionActive: true, phase: .helperSilent)), .helperSilent)
        XCTAssertEqual(KeepAwakeLiveActivity.symbol(phase: .helperSilent), "exclamationmark.triangle.fill")
    }

    func testTheResetClearsTheMarkerOnlyAfterTheFlagAndIsValidShell() throws {
        let text = LidGuardInstaller.resetScript
        XCTAssertTrue(text.contains("/usr/bin/pmset -a disablesleep 0 && /bin/rm -f "))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lidguard-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: file) }
        try text.write(to: file, atomically: true, encoding: .utf8)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-n", file.path]
        try shell.run()
        shell.waitUntilExit()
        XCTAssertEqual(shell.terminationStatus, 0)
    }

    func testAMomentaryLossOfTheFlagDoesNotTakeBackReady() {
        var lost: Date?
        XCTAssertEqual(next(.ready, lost: &lost), .ready)
        XCTAssertNotNil(lost)
        XCTAssertEqual(next(.ready, since: LidAwakeController.flagLossLimit, lost: &lost), .failed)
        XCTAssertEqual(next(.ready, flag: true, lost: &lost), .ready)
        XCTAssertNil(lost)
    }

    func testAClosedLidNeverHoldsTheDisplay() {
        XCTAssertEqual(CaffeinateManager.assertionType(keepsDisplayAwake: true, displayLetGo: false), kIOPMAssertionTypeNoDisplaySleep)
        XCTAssertEqual(CaffeinateManager.assertionType(keepsDisplayAwake: true, displayLetGo: true), kIOPMAssertionTypePreventUserIdleSystemSleep)
        XCTAssertEqual(CaffeinateManager.assertionType(keepsDisplayAwake: false, displayLetGo: false), kIOPMAssertionTypePreventUserIdleSystemSleep)
    }

    func testTheIslandShowsALaptopOnlyOnceItIsSafeToClose() {
        XCTAssertEqual(KeepAwakeLiveActivity.symbol(phase: .ready), "laptopcomputer")
        XCTAssertEqual(KeepAwakeLiveActivity.symbol(phase: .foreign), "laptopcomputer")
        XCTAssertEqual(KeepAwakeLiveActivity.symbol(phase: .idle), "cup.and.saucer.fill")
        XCTAssertEqual(KeepAwakeLiveActivity.symbol(phase: .arming), "cup.and.saucer.fill")
        for phase in [LidAwakePhase.stopped(.battery), .stopped(.thermal), .helperOff, .failed, .helperSilent] {
            XCTAssertEqual(KeepAwakeLiveActivity.symbol(phase: phase), "exclamationmark.triangle.fill")
        }
    }

    func testTheRowSaysCloseTheLidOnlyWhenReadBack() {
        var now = LidAwakeRowState.Situation(install: .current, optionOn: true, sessionActive: true, phase: .arming)
        XCTAssertEqual(LidAwakeRowState.resolve(now), .checking)
        now.phase = .ready
        XCTAssertEqual(LidAwakeRowState.resolve(now), .ready)
        now.lidClosed = true
        XCTAssertEqual(LidAwakeRowState.resolve(now), .readyLidClosed)
        now.phase = .failed
        XCTAssertEqual(LidAwakeRowState.resolve(now), .failed)
    }

    func testTheRowInEveryOtherSituation() {
        typealias S = LidAwakeRowState.Situation
        XCTAssertEqual(LidAwakeRowState.resolve(S()), .needsSetup)
        XCTAssertEqual(LidAwakeRowState.resolve(S(canInstallFromHere: false)), .moveToApplications)
        XCTAssertEqual(LidAwakeRowState.resolve(S(install: .outdated)), .outdated)
        XCTAssertEqual(LidAwakeRowState.resolve(S(install: .otherUser)), .otherUser)
        XCTAssertEqual(LidAwakeRowState.resolve(S(install: .current)), .offInstalled)
        XCTAssertEqual(LidAwakeRowState.resolve(S(install: .current, optionOn: true)), .waitingForSession)
        XCTAssertEqual(LidAwakeRowState.resolve(S(isInstalling: true)), .waitingForPassword)
        XCTAssertEqual(LidAwakeRowState.resolve(S(setupOutcome: .cancelled)), .passwordCancelled)
        XCTAssertEqual(LidAwakeRowState.resolve(S(setupOutcome: .failed)), .setupFailed)
        XCTAssertEqual(LidAwakeRowState.resolve(S(setupOutcome: .damaged)), .damagedCopy)
        XCTAssertEqual(LidAwakeRowState.resolve(S(removal: .done)), .removed)
        XCTAssertEqual(LidAwakeRowState.resolve(S(removal: .failed)), .removalFailed)
        XCTAssertEqual(LidAwakeRowState.resolve(S(isStuck: true)), .stuck)
        XCTAssertEqual(LidAwakeRowState.resolve(S(install: .current, optionOn: true, phase: .foreign)), .foreign)
        XCTAssertEqual(LidAwakeRowState.resolve(S(install: .current, optionOn: true, phase: .helperOff)), .helperOff)
        XCTAssertEqual(LidAwakeRowState.resolve(S(install: .current, optionOn: true, phase: .stopped(.battery))), .stoppedBattery)
        XCTAssertEqual(LidAwakeRowState.resolve(S(install: .current, optionOn: true, phase: .stopped(.thermal))), .stoppedHeat)
    }

    func testEveryStateSaysSomethingAndNamesTheRealLimit() {
        for state in LidAwakeRowState.allCases {
            XCTAssertFalse(state.text.isEmpty, "\(state)")
        }
        XCTAssertTrue(LidAwakeRowState.ready.text.contains("\(LidGuardConfig.batteryFloor)"))
    }

    /// Every state, in the panel's width: nothing cut, and the switch beside its title.
    @MainActor
    func testEveryStateDrawsWithinThePanel() throws {
        for state in LidAwakeRowState.allCases {
            let view = LidAwakeRowContent(title: LidAwakeCopy.title, state: state, isOn: .constant(true), batteryFloor: .constant(LidGuardConfig.batteryFloor))
                .frame(width: DS.panelWidth - 32)
                .padding(16)
                .background(DS.Palette.surface)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, "\(state)")
            XCTAssertEqual(image.size.width, DS.panelWidth, accuracy: 1, "\(state)")
            XCTAssertLessThan(image.size.height, 200, "\(state)")
            // Through a real window for the picture: ImageRenderer cannot draw the switch.
            if let folder = ProcessInfo.processInfo.environment["LUOTO_SNAPSHOT_DIR"].map({ URL(fileURLWithPath: $0) }) {
                let host = NSHostingView(rootView: view)
                host.frame.size = host.fittingSize
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.displayIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("lid-\(state).png"))
                }
                window.close()
            }
        }
    }

    /// A test once told the helper installed on the Mac it ran on to remove itself.
    func testATestHostCannotReachTheRealHelper() {
        XCTAssertNil(LidGuardInstaller.testRoot)
        for url in [LidGuardInstaller.leaseURL, LidGuardInstaller.uninstallURL, LidGuardInstaller.wakeURL] {
            XCTAssertFalse(url.path.hasPrefix("/Library"), url.path)
        }
        XCTAssertFalse(LidGuardInstaller.hasMarker)
        XCTAssertEqual(LidGuardInstaller.state, .missing)
    }

    func testTheOptionIsOffByDefault() {
        XCTAssertFalse(Defaults.Keys.caffeinateWithLidClosed.defaultValue)
    }
}

/// The controller against a made-up install in a folder. It takes a real, brief
/// Keep Awake assertion, as the panel would, and asks for nothing.
@MainActor
final class LidAwakeControllerTests: XCTestCase {
    private var root: URL!
    private var savedOption = false
    private var lease: URL { LidGuardInstaller.leaseURL }
    private let controller = LidAwakeController.shared

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lidawake-\(UUID().uuidString)")
        let files = FileManager.default
        let plist = try PropertyListSerialization.data(fromPropertyList: ["ProgramArguments": [LidGuardConfig.helperPath, "/Applications/Luoto.app"]], format: .xml, options: 0)
        for path in [LidGuardConfig.plistPath, LidGuardConfig.helperPath, LidGuardConfig.sessionDirectory + "/.keep",
                     LidGuardConfig.supportDirectory + "/" + LidGuardConfig.versionName] {
            let url = URL(fileURLWithPath: root.path + path)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        try plist.write(to: URL(fileURLWithPath: root.path + LidGuardConfig.plistPath))
        try String(LidGuardConfig.version).write(toFile: root.path + LidGuardConfig.supportDirectory + "/" + LidGuardConfig.versionName, atomically: true, encoding: .utf8)
        savedOption = Defaults[.caffeinateWithLidClosed]
        LidGuardInstaller.testRoot = root.path
        controller.setOption(false)
        controller.refreshInstalled()
        Defaults[.caffeinateWithLidClosed] = true
    }

    override func tearDown() async throws {
        CaffeinateManager.shared.deactivate()
        Defaults[.caffeinateWithLidClosed] = savedOption
        PowerRootDomain.testSleepDisabled = nil
        LidAwakeController.stuckCheckDelay = LidAwakeController.armingLimit
        Defaults[.lidClosedBatteryFloor] = LidGuardConfig.batteryFloor
        controller.refreshInstalled()
        LidGuardInstaller.testRoot = nil
        controller.refreshInstalled()
        try? FileManager.default.removeItem(at: root)
    }

    private func writeStatus(_ status: LidGuardStatus) throws {
        try status.rawValue.write(toFile: root.path + LidGuardConfig.supportDirectory + "/" + LidGuardConfig.statusName, atomically: true, encoding: .utf8)
    }

    private func spin(until condition: () -> Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out: \(what), phase \(controller.phase)", file: file, line: line)
    }

    private var leaseExists: Bool { FileManager.default.fileExists(atPath: lease.path) }

    func testNoLeaseWithoutASession() {
        XCTAssertFalse(leaseExists)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testASessionTakesALeaseAndItsEndTakesItAway() {
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        XCTAssertTrue(leaseExists)
        XCTAssertEqual(controller.phase, .arming)
        CaffeinateManager.shared.deactivate()
        XCTAssertFalse(leaseExists)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testTheOptionOffMeansNoLeaseButTheSessionGoesOn() {
        Defaults[.caffeinateWithLidClosed] = false
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        XCTAssertFalse(leaseExists)
        CaffeinateManager.shared.deactivate()
    }

    func testAChangeOfDurationKeepsTheLeaseUntouched() throws {
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: lease.path)[.systemFileNumber] as? Int)
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .oneHour))
        let after = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: lease.path)[.systemFileNumber] as? Int)
        XCTAssertEqual(before, after, "The helper must not see the session end for a new duration")
        XCTAssertEqual(CaffeinateManager.shared.activeDuration, .oneHour)
    }

    func testTurningTheOptionOffMidSessionEndsOnlyTheLidPart() {
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        controller.setOption(false)
        XCTAssertFalse(leaseExists)
        XCTAssertTrue(CaffeinateManager.shared.isActive)
        XCTAssertEqual(controller.phase, .idle)
    }

    /// Another copy of the app on the Mac must not end the running one's session.
    func testALeaseThisCopyDidNotWriteIsLeftAlone() throws {
        Defaults[.caffeinateWithLidClosed] = false
        try Data().write(to: lease)
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        CaffeinateManager.shared.deactivate()
        controller.appWillTerminate()
        XCTAssertTrue(leaseExists)
    }

    func testQuittingTakesTheLeaseAway() {
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        controller.appWillTerminate()
        XCTAssertFalse(leaseExists)
    }

    func testAHelperStopEndsTheLidPartAndTheSessionGoesOn() async throws {
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        try writeStatus(.battery)
        await spin(until: { self.controller.phase == .stopped(.battery) }, "the stop")
        XCTAssertFalse(leaseExists)
        XCTAssertTrue(CaffeinateManager.shared.isActive)
    }

    func testAStopStaysNewsAfterTheSessionRunsOut() async throws {
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        try writeStatus(.thermal)
        await spin(until: { self.controller.phase == .stopped(.thermal) }, "the stop")
        CaffeinateManager.shared.deactivate()
        XCTAssertEqual(controller.phase, .stopped(.thermal))
    }

    /// The new lease must wait for the helper to let go of the old stop, or the
    /// helper would take it as the same session.
    func testTurningOnAgainWaitsForTheStopToClear() async throws {
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        try writeStatus(.battery)
        await spin(until: { self.controller.phase == .stopped(.battery) }, "the stop")

        controller.turnOnAgain()
        XCTAssertEqual(controller.phase, .arming)
        try? await Task.sleep(for: .seconds(1))
        XCTAssertFalse(leaseExists, "The stop is still there")

        try writeStatus(.off)
        await spin(until: { self.leaseExists }, "the new lease")
        XCTAssertEqual(controller.phase, .arming)
    }

    /// A lease that cannot be written must not leave "you can close the lid" up.
    func testALeaseThatCannotBeWrittenIsSaid() throws {
        try FileManager.default.createDirectory(at: lease, withIntermediateDirectories: false)
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        XCTAssertEqual(controller.phase, .failed)
    }

    private func floorFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path + LidGuardConfig.sessionDirectory)
            .filter { $0.hasPrefix("floor-") }
    }

    func testAChosenFloorReachesTheHelperByNameOnly() throws {
        controller.setBatteryFloor(50)
        XCTAssertEqual(try floorFiles(), [LidGuardConfig.floorName(50)])
        XCTAssertEqual(Defaults[.lidClosedBatteryFloor], 50)
        let size = try FileManager.default.attributesOfItem(atPath: root.path + LidGuardConfig.sessionDirectory + "/" + LidGuardConfig.floorName(50))[.size] as? Int
        XCTAssertEqual(size, 0, "Nothing to read in it")

        controller.setBatteryFloor(10)
        XCTAssertEqual(try floorFiles(), [LidGuardConfig.floorName(10)])

        controller.setBatteryFloor(LidGuardConfig.batteryFloor)
        XCTAssertEqual(try floorFiles(), [], "The default needs no file")
    }

    func testAFloorOutsideTheChoiceIsRefused() {
        controller.setBatteryFloor(1)
        XCTAssertEqual(Defaults[.lidClosedBatteryFloor], LidGuardConfig.batteryFloor)
    }

    func testAChoiceMadeBeforeSetupReachesTheHelperWithTheSession() throws {
        Defaults[.lidClosedBatteryFloor] = 30
        XCTAssertEqual(try floorFiles(), [])
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        XCTAssertEqual(try floorFiles(), [LidGuardConfig.floorName(30)])
    }

    func testThePanelNamesTheChosenFloor() {
        Defaults[.lidClosedBatteryFloor] = 30
        XCTAssertTrue(LidAwakeRowState.ready.text.contains("30"))
    }

    func testAStoredValueOutsideTheChoiceFallsBackEverywhere() throws {
        Defaults[.lidClosedBatteryFloor] = 90
        XCTAssertEqual(LidGuardInstaller.chosenBatteryFloor, LidGuardConfig.batteryFloor)
        XCTAssertFalse(LidAwakeRowState.ready.text.contains("90"))
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        XCTAssertEqual(try floorFiles(), [])
    }

    func testAWakeRenewsTheLease() async throws {
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        let old = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: lease.path)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await spin(until: {
            let date = (try? FileManager.default.attributesOfItem(atPath: self.lease.path))?[.modificationDate] as? Date
            return (date ?? old) > old
        }, "a new lease after waking")
    }

    private func plantMarker() throws {
        try Data().write(to: URL(fileURLWithPath: root.path + LidGuardConfig.supportDirectory + "/" + LidGuardConfig.markerName))
    }

    func testAFlagTheHelperCouldNotClearIsReportedAfterAStop() async throws {
        LidAwakeController.stuckCheckDelay = 0.2
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        PowerRootDomain.testSleepDisabled = true
        try plantMarker()
        try writeStatus(.battery)
        await spin(until: { self.controller.phase == .stopped(.battery) }, "the stop")
        await spin(until: { self.controller.isStuck }, "the report")

        // And it goes when it is no longer true.
        PowerRootDomain.testSleepDisabled = false
        controller.refreshInstalled()
        XCTAssertFalse(controller.isStuck)
    }

    func testANewLeaseCancelsThatCheck() async throws {
        LidAwakeController.stuckCheckDelay = 0.3
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        PowerRootDomain.testSleepDisabled = true
        try plantMarker()
        CaffeinateManager.shared.deactivate()
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        try? await Task.sleep(for: .seconds(0.6))
        XCTAssertFalse(controller.isStuck, "The helper is holding it for this session")
    }

    func testASessionWithoutTheOptionDoesNotCancelThatCheck() async throws {
        LidAwakeController.stuckCheckDelay = 0.3
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        PowerRootDomain.testSleepDisabled = true
        try plantMarker()
        CaffeinateManager.shared.deactivate()
        Defaults[.caffeinateWithLidClosed] = false
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        await spin(until: { self.controller.isStuck }, "the report")
    }

    func testAMissingHelperDoesNotStartAnything() throws {
        try FileManager.default.removeItem(atPath: root.path + LidGuardConfig.plistPath)
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        XCTAssertFalse(leaseExists)
        XCTAssertEqual(controller.installState, .missing)
    }

    func testRemovingTheHelperAsksItAndStopsTheLease() {
        XCTAssertTrue(CaffeinateManager.shared.activate(for: .fifteenMinutes))
        controller.removeHelper()
        XCTAssertFalse(leaseExists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: LidGuardInstaller.uninstallURL.path))
        XCTAssertFalse(Defaults[.caffeinateWithLidClosed])
    }
}
