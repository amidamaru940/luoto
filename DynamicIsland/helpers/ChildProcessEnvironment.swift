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

/// The environment Luoto hands the interpreters and tools it starts (perl
/// for Now Playing, zip). Any program of the user can set launchd's
/// environment (`launchctl setenv`), and perl runs PERL5OPT/PERL5LIB code,
/// zip reads its options from ZIPOPT: that code would run inside Luoto's
/// process tree, with Luoto's Accessibility (security audit, 30.10.2026).
/// Everything else in the environment is kept, so the tools behave as before.
enum ChildProcessEnvironment {
    /// Variables that make an interpreter or tool load or run something.
    static func isInjection(_ name: String) -> Bool {
        let upper = name.uppercased()
        if upper.hasPrefix("PERL") || upper.hasPrefix("DYLD_") || upper.hasPrefix("ZIP") || upper.hasPrefix("UNZIP")
            || upper.hasPrefix("MEDIAREMOTEADAPTER_") {
            return true
        }
        return [
            // The Now Playing adapter starts the helper this names; the
            // script sets it itself where it needs it.
            "NOWPLAYING_CLIENT",
            "BASH_ENV", "ENV", "SHELLOPTS", "PS4",
            "PYTHONPATH", "PYTHONSTARTUP", "PYTHONHOME", "PYTHONINSPECT",
            "RUBYOPT", "RUBYLIB", "NODE_OPTIONS", "NODE_PATH",
            "LD_PRELOAD", "LD_LIBRARY_PATH",
        ].contains(upper)
    }

    /// `environment` without the injection variables.
    static func sanitized(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        environment.filter { !isInjection($0.key) }
    }
}
