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

/// Whether a launch undoes what a Luoto that crashed or was force-quit left
/// behind: a frozen OSDUIHelper, frozen wallpaper renderers, a rewritten
/// wallpaper. Only when no other Luoto is running. A running one froze them
/// on purpose and its watcher skips the pid it froze, so a second copy (the
/// unit-test host, a Debug build next to the installed one) that resumed
/// them brought the system HUD back next to Luoto's until the helper
/// restarted, and put the wallpaper back under the shown artwork.
enum LaunchRecoveryGate {
    /// The Release and Debug builds (PRODUCT_BUNDLE_IDENTIFIER).
    static let bundleIdentifiers = ["io.github.amidamaru940.luoto", "io.github.amidamaru940.luoto.dev"]

    /// `luotoPIDs`: the running Luoto processes, this one included or not.
    static func recovers(hostingUnitTests: Bool, luotoPIDs: [pid_t], ownPID: pid_t) -> Bool {
        !hostingUnitTests && luotoPIDs.allSatisfy { $0 == ownPID }
    }

    /// The same for this launch. One look at the running apps, no watching. A copy
    /// force-quit a moment ago may still be listed: the recovery then waits for the
    /// next launch, and the wallpaper backup stays where it is until then.
    static var recoversAtThisLaunch: Bool {
        recovers(
            hostingUnitTests: AppRuntimeEnvironment.isHostingUnitTests,
            luotoPIDs: bundleIdentifiers.flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier)
            },
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
    }
}
