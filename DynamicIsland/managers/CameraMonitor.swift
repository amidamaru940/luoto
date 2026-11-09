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
import CoreMediaIO
import AVFoundation
import SwiftUI
import Combine

// MARK: - CMIOObject Property Listener (Event-driven approach)
private func cameraPropertyListener(
    objectID: CMIOObjectID,
    numberAddresses: UInt32,
    addresses: UnsafePointer<CMIOObjectPropertyAddress>?,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let context = clientData else { return OSStatus(kCMIOHardwareNoError) }
    let monitor = Unmanaged<CameraMonitor>.fromOpaque(context).takeUnretainedValue()
    
    DispatchQueue.main.async {
        print("CameraMonitor: 📷 Camera property changed")
        monitor.checkCameraStatus()
    }
    
    return OSStatus(kCMIOHardwareNoError)
}

private var runningSomewhereAddress = CMIOObjectPropertyAddress(
    mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
)

/// The camera hardware `CameraMonitor` talks to, one replaceable function per
/// call so tests can hand it made-up devices and see where listeners go.
enum CameraDevices {
    /// Transport types (`kCMIODevicePropertyTransportType`, values from
    /// CoreAudio's `kAudioDeviceTransportType…`) of an iPhone or iPad used as
    /// the Mac's camera: 'ccwl' wireless, 'ccwd' by cable, 'ccap' (macOS 13).
    static let continuityTransportTypes: Set<UInt32> = [0x6363_776C, 0x6363_7764, 0x6363_6170]
    /// The plug-in that serves Continuity Camera. Checked on macOS 26: the
    /// iPhone's cameras have no transport type at all, only this plug-in.
    static let continuityPlugInBundleID = "com.apple.cmio.ContinuityCaptureAgent"

    /// Every CMIO device with a video input stream.
    static var videoDeviceIDs: () -> [CMIOObjectID] = { allVideoDeviceIDs() }
    /// The device's transport type; nil when it has none.
    static var transportType: (CMIOObjectID) -> UInt32? = { readTransportType(of: $0) }
    /// The bundle identifier of the plug-in that serves the device.
    static var plugInBundleID: (CMIOObjectID) -> String? = { readPlugInBundleID(of: $0) }
    static var addListener: (CMIOObjectID, UnsafeMutableRawPointer) -> OSStatus = { deviceID, context in
        CMIOObjectAddPropertyListener(deviceID, &runningSomewhereAddress, cameraPropertyListener, context)
    }
    static var removeListener: (CMIOObjectID, UnsafeMutableRawPointer) -> OSStatus = { deviceID, context in
        CMIOObjectRemovePropertyListener(deviceID, &runningSomewhereAddress, cameraPropertyListener, context)
    }
    static var isRunningSomewhere: (CMIOObjectID) -> Bool = { deviceID in
        var isRunning: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = CMIOObjectGetPropertyData(deviceID, &runningSomewhereAddress, 0, nil, dataSize, &dataSize, &isRunning)
        return status == OSStatus(kCMIOHardwareNoError) && isRunning != 0
    }
    /// An iPhone or iPad camera: Luoto leaves it alone, no listener and no
    /// running check, so the camera indicator stays dark for it.
    static func isContinuityCamera(_ deviceID: CMIOObjectID) -> Bool {
        if let transport = transportType(deviceID), continuityTransportTypes.contains(transport) { return true }
        return plugInBundleID(deviceID) == continuityPlugInBundleID
    }

    /// The video devices Luoto watches: all but the Continuity cameras.
    static func watchedDeviceIDs() -> [CMIOObjectID] {
        videoDeviceIDs().filter { !isContinuityCamera($0) }
    }

    private static func address(_ selector: Int, scope: Int = Int(kCMIOObjectPropertyScopeGlobal)) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(scope),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private static func allVideoDeviceIDs() -> [CMIOObjectID] {
        var propertyAddress = address(Int(kCMIOHardwarePropertyDevices))
        var dataSize: UInt32 = 0
        var status = CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        guard status == OSStatus(kCMIOHardwareNoError), dataSize > 0 else {
            print("CameraMonitor: ⚠️ Failed to get devices data size (status: \(status))")
            return []
        }
        let deviceCount = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: deviceCount)
        status = CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, dataSize, &dataSize, &devices)
        guard status == OSStatus(kCMIOHardwareNoError) else {
            print("CameraMonitor: ⚠️ Failed to get devices (status: \(status))")
            return []
        }
        return devices.filter(hasVideoInput)
    }

    /// Whether the device has video input streams.
    private static func hasVideoInput(_ deviceID: CMIOObjectID) -> Bool {
        var propertyAddress = address(Int(kCMIODevicePropertyStreams), scope: Int(kCMIODevicePropertyScopeInput))
        var dataSize: UInt32 = 0
        let status = CMIOObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        return status == OSStatus(kCMIOHardwareNoError) && dataSize > 0
    }

    /// Asked only when the device has the property: asking a device without
    /// it is an error in the system log.
    private static func readTransportType(of deviceID: CMIOObjectID) -> UInt32? {
        var propertyAddress = address(Int(kCMIODevicePropertyTransportType))
        guard CMIOObjectHasProperty(deviceID, &propertyAddress) else { return nil }
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = CMIOObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, dataSize, &dataSize, &value)
        return status == OSStatus(kCMIOHardwareNoError) ? value : nil
    }

    private static func readPlugInBundleID(of deviceID: CMIOObjectID) -> String? {
        var plugInAddress = address(Int(kCMIODevicePropertyPlugIn))
        guard CMIOObjectHasProperty(deviceID, &plugInAddress) else { return nil }
        var plugIn = CMIOObjectID(0)
        var dataSize = UInt32(MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(deviceID, &plugInAddress, 0, nil, dataSize, &dataSize, &plugIn) == OSStatus(kCMIOHardwareNoError) else { return nil }
        var bundleAddress = address(Int(kCMIOPlugInPropertyBundleID))
        guard CMIOObjectHasProperty(plugIn, &bundleAddress) else { return nil }
        var bundleID: Unmanaged<CFString>?
        dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(plugIn, &bundleAddress, 0, nil, dataSize, &dataSize, &bundleID) == OSStatus(kCMIOHardwareNoError) else { return nil }
        // CMIOHardware.h, kCMIOPlugInPropertyBundleID: "The caller is
        // responsible for releasing the returned CFObject", so it comes +1.
        return bundleID?.takeRetainedValue() as String?
    }
}

@MainActor
class CameraMonitor: ObservableObject {
    // MARK: - Published Properties
    @Published var isCameraActive: Bool = false
    @Published var activeApp: String? = nil
    @Published var isMonitoring: Bool = false
    
    // MARK: - Private Properties
    private var cancellables = Set<AnyCancellable>()
    private var isListenerRegistered: Bool = false
    private var cameraDeviceIDs: [CMIOObjectID] = []
    
    // MARK: - Configuration
    // Pure event-driven - no polling
    
    // MARK: - Initialization
    init() {
        // No initial setup needed
    }
    
    deinit {
        // Clean up listeners synchronously
        if isListenerRegistered, !cameraDeviceIDs.isEmpty {
            let context = Unmanaged.passUnretained(self).toOpaque()
            for deviceID in cameraDeviceIDs {
                _ = CameraDevices.removeListener(deviceID, context)
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Start monitoring camera usage
    func startMonitoring() {
        guard !isMonitoring else {
            print("CameraMonitor: Already monitoring, skipping start")
            return
        }
        
        print("CameraMonitor: 🟢 Starting camera monitoring...")
        
        isMonitoring = true
        
        // Enumerate camera devices
        cameraDeviceIDs = enumerateCameraDevices()
        
        if cameraDeviceIDs.isEmpty {
            print("CameraMonitor: ⚠️ No camera devices found")
        } else {
            print("CameraMonitor: 📷 Found \(cameraDeviceIDs.count) camera device(s)")
        }
        
        // Setup event listener (CoreMediaIO approach)
        setupPropertyListener()
        
        // Check initial state
        checkCameraStatus()
        
        print("CameraMonitor: ✅ Started monitoring (event-driven CMIO)")
    }
    
    /// Stop monitoring camera usage
    func stopMonitoring() {
        guard isMonitoring else {
            print("CameraMonitor: Not monitoring, skipping stop")
            return
        }
        
        print("CameraMonitor: 🛑 Stopping monitoring...")
        
        isMonitoring = false
        
        // Remove property listener
        if isListenerRegistered {
            removePropertyListener()
        }
        
        // Reset state
        if isCameraActive {
            isCameraActive = false
        }
        activeApp = nil
        
        print("CameraMonitor: ✅ Stopped monitoring")
    }
    
    /// Toggle monitoring state
    func toggleMonitoring() {
        if isMonitoring {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }
    
    // MARK: - Private Methods
    
    /// The camera devices to watch, from CoreMediaIO: every video input
    /// except the iPhone's or iPad's Continuity cameras.
    private func enumerateCameraDevices() -> [CMIOObjectID] {
        CameraDevices.watchedDeviceIDs()
    }

    /// The devices that got a listener; for tests.
    var watchedDeviceIDs: [CMIOObjectID] { cameraDeviceIDs }
    
    /// Setup CoreMediaIO property listener
    private func setupPropertyListener() {
        guard !cameraDeviceIDs.isEmpty else { return }
        
        // Listen for device running state changes
        let context = Unmanaged.passUnretained(self).toOpaque()
        
        // Add listener for each camera device (Continuity cameras were left
        // out by enumerateCameraDevices)
        for deviceID in cameraDeviceIDs {
            let status = CameraDevices.addListener(deviceID, context)
            
            if status == OSStatus(kCMIOHardwareNoError) {
                print("CameraMonitor: ✅ Property listener registered for device \(deviceID)")
                isListenerRegistered = true
            } else {
                print("CameraMonitor: ⚠️ Failed to register listener for device \(deviceID) (status: \(status))")
            }
        }
    }
    
    /// Remove CoreMediaIO property listener
    private func removePropertyListener() {
        guard !cameraDeviceIDs.isEmpty else { return }
        
        let context = Unmanaged.passUnretained(self).toOpaque()
        
        for deviceID in cameraDeviceIDs {
            let status = CameraDevices.removeListener(deviceID, context)
            
            if status == OSStatus(kCMIOHardwareNoError) {
                print("CameraMonitor: ✅ Property listener removed for device \(deviceID)")
            } else {
                print("CameraMonitor: ⚠️ Failed to remove listener for device \(deviceID) (status: \(status))")
            }
        }
        
        isListenerRegistered = false
    }
    
    /// Check current camera status (CMIO approach)
    private func checkCameraStatusCMIO() -> Bool {
        guard !cameraDeviceIDs.isEmpty else { return false }
        
        // Check if any camera device is running
        return cameraDeviceIDs.contains { CameraDevices.isRunningSomewhere($0) }
    }
    
    /// Check current camera status. CMIO only: an AVFoundation discovery
    /// session made Luoto a capture client, and AVFoundation then worked on
    /// the main thread every time the iPhone's camera came into range.
    func checkCameraStatus() {
        let isActive = checkCameraStatusCMIO()
        print("CameraMonitor: 🔍 Checking... current=\(isCameraActive), CMIO=\(isActive)")
        
        // Update state if changed
        if isActive != isCameraActive {
            print("CameraMonitor: 🔄 State change detected (\(isCameraActive) -> \(isActive))")
            
            withAnimation(.smooth) {
                isCameraActive = isActive
            }
            
            if isActive {
                print("CameraMonitor: 📷 Camera ACTIVE")
                // Could try to identify app here (TODO: investigate)
                activeApp = "Unknown App"
            } else {
                print("CameraMonitor: ⚪ Camera INACTIVE")
                activeApp = nil
            }
        }
    }

}

// MARK: - Extensions

extension CameraMonitor {
    /// Get current camera status without async
    var currentCameraStatus: Bool {
        return isCameraActive
    }
    
    /// Check if monitoring is available
    var isMonitoringAvailable: Bool {
        return !enumerateCameraDevices().isEmpty
    }
}
