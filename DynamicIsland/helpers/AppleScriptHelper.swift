/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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

class AppleScriptHelper {
    @discardableResult
    class func execute(_ scriptText: String) async throws -> NSAppleEventDescriptor? {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let script = NSAppleScript(source: scriptText)
                var error: NSDictionary?
                if let descriptor = script?.executeAndReturnError(&error) {
                    continuation.resume(returning: descriptor)
                } else if let error = error {
                    continuation.resume(throwing: NSError(domain: "AppleScriptError", code: 1, userInfo: error as? [String: Any]))
                } else {
                    continuation.resume(throwing: NSError(domain: "AppleScriptError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }
    }
    
    class func executeVoid(_ scriptText: String) async throws {
        _ = try await execute(scriptText)
    }
}

/// Text going into an AppleScript string literal. A quote alone is not
/// enough: an AirPlay device may name itself `x\" & (do shell script …) & "`,
/// and with only `"` escaped its own backslash re-opened the string
/// (security audit, 30.10.2026). Backslashes first, then quotes; line breaks
/// become `\n` so the literal stays on its line.
enum AppleScriptText {
    static func literal(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }
}

