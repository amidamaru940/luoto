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

import Sparkle

/// Updates come through Sparkle from this project's GitHub releases, and each
/// is checked against the EdDSA key in Info.plist. Nothing goes to the network
/// until the person says yes (`SUEnableAutomaticChecks` is false in Info.plist,
/// and Sparkle keeps their answer): then one request a day, with no system
/// profile. Installing always waits for them. «Check for Updates…» works at any
/// time, because pressing it is asking.
enum SoftwareUpdatePolicy {
    private(set) static var controller: SPUStandardUpdaterController?

    /// The test host gets no updater: to macOS and GitHub it would be a real one.
    static func makeUpdaterController() -> SPUStandardUpdaterController? {
        guard AppRuntimeEnvironment.mayAskForPermissions else { return nil }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        return controller
    }

    /// The person's answer to the question in onboarding.
    static func setChecksOnceADay(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
    }
}
