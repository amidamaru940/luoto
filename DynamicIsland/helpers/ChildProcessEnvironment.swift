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
            || upper.hasPrefix("MEDIAREMOTEADAPTER_") || upper.contains("BASH_FUNC") {
            return true
        }
        return [
            // The Now Playing adapter starts the helper this names; the
            // script sets it itself where it needs it.
            "NOWPLAYING_CLIENT",
            "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "PS4",
            "PYTHONPATH", "PYTHONSTARTUP", "PYTHONHOME", "PYTHONINSPECT",
            "RUBYOPT", "RUBYLIB", "NODE_OPTIONS", "NODE_PATH",
            "LD_PRELOAD", "LD_LIBRARY_PATH",
        ].contains(upper)
    }

    /// A shell function passed through the environment, under whatever name.
    static func isExportedFunction(value: String) -> Bool {
        value.hasPrefix("() {")
    }

    /// Takes the injection variables out of this process itself. `do shell script`
    /// with the administrator's password goes past `sanitized()`, and a process of
    /// the user's can set these for the next launch (`launchctl setenv`). Called
    /// early at launch: changing the environment is not safe once other threads
    /// read it, and with a clean environment this does nothing.
    static func removeInjectionVariablesFromThisProcess() {
        for (name, value) in ProcessInfo.processInfo.environment where isInjection(name) || isExportedFunction(value: value) {
            unsetenv(name)
        }
    }

    /// `environment` without the injection variables.
    static func sanitized(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        environment.filter { !isInjection($0.key) && !isExportedFunction(value: $0.value) }
    }
}

/// The Now Playing helpers, which stream for as long as they are not told to stop.
/// A helper with nothing to report does not notice that its reader has gone, so a
/// quit has to stop it, and a launch clears any that a crash left behind.
enum AdapterProcesses {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: [Process] = []

    static func track(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        running.removeAll { !$0.isRunning }
        running.append(process)
    }

    static func stopAll() {
        lock.lock()
        defer { lock.unlock() }
        for process in running where process.isRunning {
            process.terminate()
        }
        running.removeAll()
    }

    /// Only this copy's own script, and only orphans: another Luoto's helper has a
    /// parent, and so does this one's, once it has started any.
    static func clearOrphans() {
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl") else { return }
        DispatchQueue.global(qos: .utility).async {
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-P", "1", "-f", NSRegularExpression.escapedPattern(for: script.path)]
            pkill.environment = ChildProcessEnvironment.sanitized()
            guard (try? pkill.run()) != nil else { return }
            pkill.waitUntilExit()
        }
    }
}
