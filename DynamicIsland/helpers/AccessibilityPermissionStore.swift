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

import Foundation
import Combine
import AppKit
import Defaults
import SwiftUI
#if canImport(ApplicationServices)
import ApplicationServices
#endif

/// Tracks accessibility permission status and exposes helpers to request access.
@MainActor
final class AccessibilityPermissionStore: ObservableObject {
    static let shared = AccessibilityPermissionStore()

    @Published private(set) var isAuthorized: Bool = AccessibilityPermissionStore.isAccessibilityAuthorized()

    @Published private(set) var isRestoring = false

    private var pollingTask: Task<Void, Never>?

    private init() {}

    deinit {
        pollingTask?.cancel()
    }

    func refreshStatus() {
        updateAuthorizationStatus(to: Self.isAccessibilityAuthorized())
        if isAuthorized { Defaults[.accessibilityWasGranted] = true }
    }

    /// Access was given once and is gone. macOS can show the switch on in its
    /// list while the app is no longer trusted, and turning it off and on does
    /// not always help, so the card offers to start over.
    var needsRestore: Bool {
        Self.needsRestore(isAuthorized: isAuthorized, wasGranted: Defaults[.accessibilityWasGranted])
    }

    nonisolated static func needsRestore(isAuthorized: Bool, wasGranted: Bool) -> Bool {
        !isAuthorized && wasGranted
    }

    /// Drops Luoto's own row in macOS's list and asks again, which adds a row
    /// that fits this copy of the app. Never with access in place: the reset
    /// would take it away. If the reset fails, the person gets the list itself.
    func restoreAccess() {
        guard AppRuntimeEnvironment.mayAskForPermissions, !isRestoring, !Self.isAccessibilityAuthorized(),
              let bundleID = Bundle.main.bundleIdentifier else {
            refreshStatus()
            return
        }
        isRestoring = true
        Task {
            let status = await Task.detached(priority: .userInitiated) { () -> Int32 in
                let reset = Process()
                reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                reset.arguments = ["reset", "Accessibility", bundleID]
                do {
                    try reset.run()
                } catch {
                    return -1
                }
                reset.waitUntilExit()
                return reset.terminationStatus
            }.value
            isRestoring = false
            if status == 0 {
                requestAuthorizationPrompt()
            } else {
                openSystemSettings()
            }
        }
    }

    func requestAuthorizationPrompt() {
        guard AppRuntimeEnvironment.mayAskForPermissions else { return }
#if canImport(ApplicationServices)
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
#endif
        beginPollingForStatusChanges()
    }

    func openSystemSettings() {
#if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
#endif
    }

    private func beginPollingForStatusChanges() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let status = Self.isAccessibilityAuthorized()
                await MainActor.run {
                    guard let self else { return }
                    self.updateAuthorizationStatus(to: status)
                }
                if status {
                    break
                }
            }
        }
    }

    private func updateAuthorizationStatus(to newValue: Bool) {
        guard newValue != isAuthorized else { return }
        isAuthorized = newValue
        if newValue {
            Defaults[.accessibilityWasGranted] = true
            MediaKeyInterceptor.shared.accessibilityMayHaveChanged()
        }
        if !newValue {
            beginPollingForStatusChanges()
        }
    }

    private static func isAccessibilityAuthorized() -> Bool {
#if canImport(ApplicationServices)
        if AppRuntimeEnvironment.isUITesting {
            return true
        }
        return AXIsProcessTrusted()
#else
        return true
#endif
    }
}

/// The card in Settings that brings Accessibility back when macOS lost it.
struct AccessibilityRestoreSection: View {
    @ObservedObject private var permission = AccessibilityPermissionStore.shared

    var body: some View {
        if permission.needsRestore {
            Section {
                Text("Luoto had Accessibility and macOS no longer gives it, even if the switch in its list looks on. One-click paste and the volume keys wait for it.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Restore Access") { permission.restoreAccess() }
                    .disabled(permission.isRestoring)
            } header: {
                Text("Accessibility")
            }
        }
    }
}
