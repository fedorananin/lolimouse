// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem
import os.log

/// Per-device pointer tuning, backed by `IOHIDServiceClient`.
///
/// macOS exposes tracking speed and acceleration as per-service properties, so
/// changing them here affects only this mouse — the system-wide slider in
/// System Settings is left alone.
public final class PointerService {
    private static let log = LoLiLog.hid

    public let client: IOHIDServiceClient
    public let registryID: UInt64
    public let vendorID: Int?
    public let productID: Int?
    public let product: String?
    public let locationID: Int?

    public init?(_ client: IOHIDServiceClient) {
        guard let registryValue = IOHIDServiceClientGetRegistryID(client) as? UInt64 else {
            return nil
        }
        self.client = client
        registryID = registryValue
        vendorID = PointerService.property(client, kIOHIDVendorIDKey)
        productID = PointerService.property(client, kIOHIDProductIDKey)
        product = PointerService.property(client, kIOHIDProductKey)
        locationID = PointerService.property(client, kIOHIDLocationIDKey)
    }

    private static func property<T>(_ client: IOHIDServiceClient, _ key: String) -> T? {
        guard let value = IOHIDServiceClientCopyProperty(client, key as CFString) else { return nil }
        return value as? T
    }

    private func get<T>(_ key: String) -> T? {
        Self.property(client, key)
    }

    private func set(_ value: Any?, _ key: String) {
        guard let value else { return }
        IOHIDServiceClientSetProperty(client, key as CFString, value as CFTypeRef)
    }

    private func getFixed(_ key: String) -> Double? {
        (get(key) as IOFixed?).map { Double($0) / 65536 }
    }

    private func setFixed(_ value: Double, _ key: String) {
        set(IOFixed(value * 65536), key)
    }

    // MARK: - Tracking speed

    /// Pointer resolution in counts per inch. Lower moves the cursor further
    /// per physical millimetre, so this is inversely proportional to speed.
    /// macOS accepts roughly 10…1995.
    public var pointerResolution: Double? {
        get { getFixed(kIOHIDPointerResolutionKey) }
        set {
            guard let newValue else { return }
            setFixed(min(max(newValue, 10), 1995), kIOHIDPointerResolutionKey)
            // Resolution only takes effect once an acceleration write follows.
            if let acceleration = pointerAcceleration {
                pointerAcceleration = acceleration
            }
        }
    }

    /// Which acceleration property this device actually honours. Mice and
    /// trackpads use different keys, and some devices expose neither until
    /// probed.
    public var accelerationKey: String {
        if let explicit: String = get(kIOHIDPointerAccelerationTypeKey) {
            return explicit
        }
        if (get(kIOHIDPointerAccelerationKey) as IOFixed?) != nil {
            return kIOHIDPointerAccelerationKey
        }
        return kIOHIDMouseAccelerationTypeKey
    }

    /// Acceleration curve strength, 0…40. `-1` means the curve is disabled
    /// entirely (linear one-to-one tracking).
    public var pointerAcceleration: Double? {
        get {
            if linearScalingEnabled == 1 { return -1 }
            return getFixed(accelerationKey)
        }
        set {
            guard let newValue else { return }
            setFixed(newValue == -1 ? -1 : min(max(newValue, 0), 40), accelerationKey)
        }
    }

    /// macOS Sonoma and later expose a dedicated "linear scaling" switch, which
    /// disables acceleration without the `-1` sentinel and its side effects.
    public var linearScalingEnabled: Int? {
        get { get("HIDUseLinearScalingMouseAcceleration") }
        set { set(newValue, "HIDUseLinearScalingMouseAcceleration") }
    }

    public var supportsLinearScaling: Bool {
        (get("HIDUseLinearScalingMouseAcceleration") as Int?) != nil
    }

    public func conformsTo(usagePage: Int, usage: Int) -> Bool {
        IOHIDServiceClientConformsTo(client, UInt32(usagePage), UInt32(usage)) != 0
    }

    /// Trackpads advertise the Digitizer/TouchPad usage pair next to the
    /// mouse one; mice never do.
    public var isTrackpad: Bool {
        conformsTo(usagePage: kHIDPage_Digitizer, usage: kHIDUsage_Dig_TouchPad)
    }

    /// The ID MultitouchSupport reports for this trackpad, or `nil` for a
    /// device with no multitouch surface.
    ///
    /// The trackpad's HID event driver has an `AppleMultitouchDevice` child
    /// in the IORegistry carrying a "Multitouch ID" property, and that is the
    /// same number `MTDeviceGetDeviceID` hands back. Reading it is a plain
    /// registry lookup: nothing is opened.
    public private(set) lazy var multitouchID: UInt64? = Self.multitouchID(under: registryID)

    private static func multitouchID(under registryID: UInt64) -> UInt64? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        let value = IORegistryEntrySearchCFProperty(
            entry, kIOServicePlane, "Multitouch ID" as CFString,
            kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)
        )
        return (value as? NSNumber)?.uint64Value
    }
}

/// Enumerates pointer `IOHIDServiceClient`s and resolves an event's sender ID
/// back to the device that produced it.
public final class PointerServiceRegistry {
    private static let log = LoLiLog.hid

    private let client: IOHIDEventSystemClient?
    private let lock = NSLock()
    private var servicesByRegistryID: [UInt64: PointerService] = [:]

    public init() {
        client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        if client == nil {
            os_log("IOHIDEventSystemClientCreateSimpleClient failed; pointer tuning unavailable",
                   log: Self.log, type: .error)
        }
        refresh()
    }

    /// Re-reads the service list. Cheap enough to call on every device change.
    public func refresh() {
        guard let client,
              let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]
        else {
            return
        }

        var map: [UInt64: PointerService] = [:]
        for service in services {
            guard let pointer = PointerService(service) else { continue }
            let isPointer = pointer.conformsTo(usagePage: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_Mouse)
                || pointer.conformsTo(usagePage: kHIDPage_GenericDesktop, usage: kHIDUsage_GD_Pointer)
            guard isPointer else { continue }
            map[pointer.registryID] = pointer
        }

        lock.lock()
        servicesByRegistryID = map
        lock.unlock()
    }

    public var services: [PointerService] {
        lock.lock()
        defer { lock.unlock() }
        return Array(servicesByRegistryID.values)
    }

    public func service(registryID: UInt64) -> PointerService? {
        lock.lock()
        defer { lock.unlock() }
        return servicesByRegistryID[registryID]
    }

    /// Best-effort match of a HID device to its pointer service. IOKit gives the
    /// two objects different registry IDs, so we fall back through the
    /// identifying properties they do share.
    public func service(matching device: HIDDevice) -> PointerService? {
        let candidates = services.filter {
            $0.vendorID == device.vendorID && $0.productID == device.productID
        }
        if candidates.count == 1 { return candidates.first }
        if let locationID = device.locationID,
           let byLocation = candidates.first(where: { $0.locationID == locationID }) {
            return byLocation
        }
        return candidates.first
    }
}
