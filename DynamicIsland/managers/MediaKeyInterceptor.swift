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
import AppKit
import CoreGraphics
#if canImport(ApplicationServices)
import ApplicationServices
#endif

private let NX_SYSDEFINED_EVENT_TYPE: UInt32 = 14
private let NX_KEYTYPE_SOUND_UP: Int32 = 0
private let NX_KEYTYPE_SOUND_DOWN: Int32 = 1
private let NX_KEYTYPE_BRIGHTNESS_UP: Int32 = 2
private let NX_KEYTYPE_BRIGHTNESS_DOWN: Int32 = 3
private let NX_KEYTYPE_MUTE: Int32 = 7

extension Notification.Name {
    /// Posted when the media key tap comes up or goes away, so settings can
    /// tell the user why their volume and brightness keys are behaving natively.
    static let mediaKeyInterceptionAvailabilityDidChange = Notification.Name(
        "MediaKeyInterceptionAvailabilityDidChange"
    )
}

enum MediaKeyDirection {
    case up
    case down
}

enum MediaKeyStep {
    case standard
    case fine
}

struct MediaKeyConfiguration {
    var interceptVolume: Bool
    var interceptBrightness: Bool
    var interceptCommandModifiedBrightness: Bool

    static let disabled = MediaKeyConfiguration(
        interceptVolume: false,
        interceptBrightness: false,
        interceptCommandModifiedBrightness: false
    )
}

protocol MediaKeyInterceptorDelegate: AnyObject {
    func mediaKeyInterceptor(
        _ interceptor: MediaKeyInterceptor,
        didReceiveVolumeCommand direction: MediaKeyDirection,
        step: MediaKeyStep,
        isRepeat: Bool,
        modifiers: NSEvent.ModifierFlags
    )
    func mediaKeyInterceptor(
        _ interceptor: MediaKeyInterceptor,
        didReceiveBrightnessCommand direction: MediaKeyDirection,
        step: MediaKeyStep,
        isRepeat: Bool,
        modifiers: NSEvent.ModifierFlags
    )
    func mediaKeyInterceptorDidToggleMute(_ interceptor: MediaKeyInterceptor)
}

/// What the media key tap does when Accessibility may have changed.
enum MediaKeyTapAction: Equatable {
    case install
    case remove
    case none

    static func after(trusted: Bool, hasTap: Bool) -> MediaKeyTapAction {
        switch (trusted, hasTap) {
        case (true, false): return .install
        case (false, true): return .remove
        default: return .none
        }
    }
}

/// Tells when macOS's Accessibility list may have changed. Luoto is almost
/// never the active app, and an inactive app gets distributed notifications
/// late unless it asks otherwise. The signal comes before the change takes
/// effect, by a moment that varies, so it is checked a few times, and once more
/// when the person comes back to Luoto.
private final class AccessibilityListWatcher: NSObject {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(listChanged),
            name: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func listChanged() {
        for delay: TimeInterval in [1, 3, 10] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.onChange()
            }
        }
    }

    @objc private func appBecameActive() {
        onChange()
    }
}

final class MediaKeyInterceptor {
    static let shared = MediaKeyInterceptor()

    weak var delegate: MediaKeyInterceptorDelegate?
    var configuration: MediaKeyConfiguration = .disabled {
        didSet {
            updateTapState()
        }
    }

    /// False while the event tap could not be created — almost always because
    /// Accessibility has not been granted yet. The media keys then reach macOS
    /// untouched, so the native HUD draws over this app's, and brightness gets
    /// no HUD at all (it is only detected when this app drives the change).
    private(set) var isInterceptionAvailable = false {
        didSet {
            guard isInterceptionAvailable != oldValue else { return }
            NotificationCenter.default.post(
                name: .mediaKeyInterceptionAvailabilityDidChange,
                object: nil
            )
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isTapEnabled = false
    private var accessibilityWatcher: AccessibilityListWatcher?
    private let systemDefinedEventType = CGEventType(rawValue: NX_SYSDEFINED_EVENT_TYPE)
    private let eventTapLocations: [CGEventTapLocation] = [.cghidEventTap, .cgSessionEventTap]

    private var shouldEnableTap: Bool {
        configuration.interceptVolume
            || configuration.interceptBrightness
            || configuration.interceptCommandModifiedBrightness
    }

    private init() {}

    /// Installs the media key tap, and keeps trying if it cannot be installed yet.
    ///
    /// `CGEvent.tapCreate` fails outright until Accessibility is granted, and
    /// granting it does not relaunch the app — so a single attempt at startup
    /// leaves interception off for the rest of the session. The only way back
    /// was to toggle a HUD style in Settings and toggle it again, which
    /// restarts the observer and so retries the tap by accident (#601).
    @discardableResult
    func start() -> Bool {
        // A test host must not tap the keyboard: macOS asks for it.
        guard AppRuntimeEnvironment.mayAskForPermissions else { return false }
        guard eventTap == nil else {
            updateTapState()
            return true
        }

        // Nothing here asks. Accessibility is asked for when the person turns on
        // something that needs it, and even trying to tap without it makes macOS
        // show its own dialog.
        watchAccessibilityList()
        return AXIsProcessTrusted() && installTap()
    }

    @discardableResult
    private func installTap() -> Bool {
        guard eventTap == nil else { return true }

        guard let systemDefinedType = systemDefinedEventType else {
            NSLog("❌ Unable to resolve system-defined event type")
            return false
        }
        let mask = CGEventMask(1) << systemDefinedType.rawValue
        let callback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(cgEvent) }
            let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
            return interceptor.handleEvent(cgEvent: cgEvent, type: type)
        }

        var createdTap: CFMachPort?
        for location in eventTapLocations {
            if let tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            ) {
                createdTap = tap
                break
            }
        }

        guard let tap = createdTap else {
#if canImport(ApplicationServices)
            if !AXIsProcessTrusted() {
                NSLog("⚠️ Accessibility permission missing; grant access in System Settings › Privacy & Security › Accessibility")
            }
#endif
            NSLog("❌ Failed to create media key event tap")
            isInterceptionAvailable = false
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isTapEnabled = true
        isInterceptionAvailable = true
        NSLog("✅ Media key event tap installed (HID)")
        return true
    }

    /// Accessibility is given and taken away in System Settings while the app
    /// runs. macOS posts a signal when its list changes, so nothing runs until
    /// then: polling here cost 266 wakeups an hour for everyone without the
    /// permission, and stopped after an hour.
    private func watchAccessibilityList() {
        guard accessibilityWatcher == nil else { return }
        accessibilityWatcher = AccessibilityListWatcher { [weak self] in
            self?.accessibilityMayHaveChanged()
        }
    }

    /// Also called when Luoto itself notices the change
    /// (`AccessibilityPermissionStore`). Does nothing unless the tap is wanted.
    func accessibilityMayHaveChanged() {
        guard accessibilityWatcher != nil else { return }
        switch MediaKeyTapAction.after(trusted: AXIsProcessTrusted(), hasTap: eventTap != nil) {
        case .install:
            guard installTap() else { return }
            updateTapState()
            // This tap missed every key until now, and the native HUD has been
            // drawing in its place — take the HUD back immediately.
            SystemOSDManager.suppressNativeOSDNow()
        case .remove:
            // The tap no longer gets the keys; macOS's HUD must take over.
            removeTap()
        case .none:
            break
        }
    }

    func stop() {
        accessibilityWatcher = nil
        removeTap()
    }

    private func removeTap() {
        isInterceptionAvailable = false
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isTapEnabled = false
    }

    private func updateTapState() {
        guard let tap = eventTap else { return }
        let shouldEnable = shouldEnableTap
        if shouldEnable != isTapEnabled {
            CGEvent.tapEnable(tap: tap, enable: shouldEnable)
            isTapEnabled = shouldEnable
        }
    }

    private func handleEvent(cgEvent: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if shouldEnableTap, let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                isTapEnabled = true
                SystemOSDManager.suppressNativeOSDNow()
                NSLog(
                    "Media key event tap was disabled by %@; re-enabled",
                    type == .tapDisabledByTimeout ? "timeout" : "user input"
                )
            }
            return Unmanaged.passUnretained(cgEvent)
        }

        guard let systemDefinedType = systemDefinedEventType,
              type == systemDefinedType,
              let nsEvent = NSEvent(cgEvent: cgEvent),
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(cgEvent)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyState = ((keyFlags & 0xFF00) >> 8) == 0xA // 0xA = keyDown, 0xB = keyUp
        let isRepeat = (keyFlags & 0x0001) == 1
        let step = step(for: nsEvent)
        let modifiers = nsEvent.modifierFlags

        guard keyState else {
            // Swallow key-up events only when intercepting, otherwise let them pass through
            if shouldHandle(keyCode: Int32(keyCode), modifiers: modifiers) {
                return nil
            }
            return Unmanaged.passUnretained(cgEvent)
        }

        switch Int32(keyCode) {
        case NX_KEYTYPE_SOUND_UP:
            guard configuration.interceptVolume else { return Unmanaged.passUnretained(cgEvent) }
            dispatchVolumeCommand(.up, step: step, isRepeat: isRepeat, modifiers: modifiers)
            return nil
        case NX_KEYTYPE_SOUND_DOWN:
            guard configuration.interceptVolume else { return Unmanaged.passUnretained(cgEvent) }
            dispatchVolumeCommand(.down, step: step, isRepeat: isRepeat, modifiers: modifiers)
            return nil
        case NX_KEYTYPE_MUTE:
            guard configuration.interceptVolume else { return Unmanaged.passUnretained(cgEvent) }
            dispatchMuteCommand()
            return nil
        case NX_KEYTYPE_BRIGHTNESS_UP:
            guard shouldHandleBrightness(modifiers: modifiers) else { return Unmanaged.passUnretained(cgEvent) }
            dispatchBrightnessCommand(.up, step: step, isRepeat: isRepeat, modifiers: modifiers)
            return nil
        case NX_KEYTYPE_BRIGHTNESS_DOWN:
            guard shouldHandleBrightness(modifiers: modifiers) else { return Unmanaged.passUnretained(cgEvent) }
            dispatchBrightnessCommand(.down, step: step, isRepeat: isRepeat, modifiers: modifiers)
            return nil
        default:
            return Unmanaged.passUnretained(cgEvent)
        }
    }

    /// Keep all potentially blocking CoreAudio/CoreBrightness work outside the
    /// event-tap callback. A tap callback must return promptly or macOS disables
    /// it and the next media key falls through to the native OSD.
    private func dispatchVolumeCommand(
        _ direction: MediaKeyDirection,
        step: MediaKeyStep,
        isRepeat: Bool,
        modifiers: NSEvent.ModifierFlags
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.mediaKeyInterceptor(
                self,
                didReceiveVolumeCommand: direction,
                step: step,
                isRepeat: isRepeat,
                modifiers: modifiers
            )
        }
    }

    private func dispatchBrightnessCommand(
        _ direction: MediaKeyDirection,
        step: MediaKeyStep,
        isRepeat: Bool,
        modifiers: NSEvent.ModifierFlags
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.mediaKeyInterceptor(
                self,
                didReceiveBrightnessCommand: direction,
                step: step,
                isRepeat: isRepeat,
                modifiers: modifiers
            )
        }
    }

    private func dispatchMuteCommand() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.mediaKeyInterceptorDidToggleMute(self)
        }
    }

    private func shouldHandle(keyCode: Int32, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE:
            return configuration.interceptVolume
        case NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_DOWN:
            return configuration.interceptBrightness || (configuration.interceptCommandModifiedBrightness && modifiers.contains(.command))
        default:
            return false
        }
    }

    private func shouldHandleBrightness(modifiers: NSEvent.ModifierFlags) -> Bool {
        if configuration.interceptBrightness {
            return true
        }
        return configuration.interceptCommandModifiedBrightness && modifiers.contains(.command)
    }

    private func step(for event: NSEvent) -> MediaKeyStep {
        let modifiers = event.modifierFlags
        if modifiers.contains(.option) && modifiers.contains(.shift) {
            return .fine
        }
        return .standard
    }
}
