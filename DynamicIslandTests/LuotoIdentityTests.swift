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

@testable import Atoll
import XCTest

/// Checks the built host app: fork identity, updates off until the person agrees.
final class LuotoIdentityTests: XCTestCase {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    func testHostAppUsesForkIdentity() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        XCTAssertTrue(["io.github.amidamaru940.luoto", "io.github.amidamaru940.luoto.dev"].contains(bundleID), bundleID)
        XCTAssertEqual(info["CFBundleName"] as? String, "Luoto")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Luoto")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "Luoto")
    }

    func testTestBundleUsesForkIdentifier() {
        XCTAssertEqual(Bundle(for: Self.self).bundleIdentifier, "io.github.amidamaru940.luoto.tests")
    }

    func testUpdatesStayOffUntilThePersonAgrees() {
        XCTAssertEqual(info["SUFeedURL"] as? String, "https://github.com/amidamaru940/luoto/releases/latest/download/appcast.xml")
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(info["SUEnableSystemProfiling"] as? Bool, false)
    }

    @MainActor
    func testTheTestHostGetsNoUpdater() {
        XCTAssertNil(SoftwareUpdatePolicy.makeUpdaterController())
        // The running host app went through DynamicNotchApp.init(); no updater may have been handed over.
        XCTAssertFalse(SettingsWindowController.shared.hasUpdaterController)
    }

    func testSignedAppHasNoCameraEntitlement() throws {
        let task = try XCTUnwrap(SecTaskCreateFromSelf(nil))
        let camera = SecTaskCopyValueForEntitlement(task, "com.apple.security.device.camera" as CFString, nil)
        XCTAssertNil(camera, "the signed host app must not carry the camera entitlement")
        // Sanity check that entitlements are readable at all.
        let appleEvents = SecTaskCopyValueForEntitlement(task, "com.apple.security.automation.apple-events" as CFString, nil)
        XCTAssertEqual(appleEvents as? Bool, true)
    }

    func testUsageDescriptionsNameTheFork() {
        let usage = info.filter { $0.key.hasSuffix("UsageDescription") }
        XCTAssertFalse(usage.isEmpty)
        for (key, value) in usage {
            XCTAssertFalse((value as? String ?? "").contains("Atoll"), "\(key) still says Atoll")
        }
    }
}
