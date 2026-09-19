// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Combine
import Foundation
import HIDKit
import HIDPP
import os.log

/// What a HID++ device's firmware actually implements, probed once at
/// discovery so the UI can hide the settings this particular device has no
/// hardware for.
public struct DeviceCapabilities: Equatable {
    /// Ratchet control, 0x2110 or 0x2111.
    public var smartShift = false
    /// High-resolution wheel, 0x2121.
    public var hiResWheel = false
    /// The invert bit of 0x2121.
    public var wheelInvert = false
    /// Adjustable DPI, 0x2201.
    public var dpi = false
    /// Report rate, 0x8060.
    public var reportRate = false
    /// Button diversion, 0x1B04 — what the wheel-mode and thumb buttons need.
    public var buttonDiversion = false

    public init() {}
}

/// One physical mouse, as LoLiMouse understands it.
///
/// The identity is deliberately connection-independent: unplugging a Bolt
/// receiver and pairing over Bluetooth produces the same `key`, so settings
/// follow the mouse rather than the cable.
public final class ManagedDevice: Identifiable, ObservableObject {
    public let key: String
    public let displayName: String

    /// The HID++ conversation, when the device speaks it. Non-Logitech mice
    /// still get pointer, scrolling and button handling — they just have no
    /// hardware settings to manage.
    public let target: HIDPPTarget?
    /// The HID endpoint HID++ runs over.
    public let endpoint: HIDDevice?
    /// The macOS pointer service, used for tracking speed and acceleration.
    public internal(set) var pointerService: PointerService?

    /// Registry IDs that identify this device as the source of a CGEvent.
    public internal(set) var senderIDs: Set<UInt64>

    /// What the firmware implements, or `nil` while unknown. The UI treats
    /// unknown as "show everything" so a probe that failed because the device
    /// was asleep never hides settings the mouse actually has.
    public internal(set) var capabilities: DeviceCapabilities?

    @Published public internal(set) var isOnline: Bool
    @Published public internal(set) var battery: HIDPPBattery?
    /// Populated lazily on first use, because reading the control table costs a
    /// round trip per row.
    @Published public internal(set) var controls: [HIDPPControlInfo] = []

    public var id: String { key }

    /// `package` so the test target can build a detached device (no target,
    /// no endpoint) without opening anything.
    package init(
        key: String,
        displayName: String,
        target: HIDPPTarget?,
        endpoint: HIDDevice?,
        pointerService: PointerService?,
        senderIDs: Set<UInt64> = [],
        isOnline: Bool = true
    ) {
        self.key = key
        self.displayName = displayName
        self.target = target
        self.endpoint = endpoint
        self.pointerService = pointerService
        self.senderIDs = senderIDs
        self.isOnline = isOnline
    }

    public var supportsHardwareSettings: Bool { target != nil }

    /// A multitouch surface rather than a mouse: the built-in trackpad or an
    /// external one. Gets the trackpad gesture settings.
    public var isTrackpad: Bool { pointerService?.isTrackpad ?? false }

    /// Pairs this trackpad with the stream MultitouchSupport delivers.
    public var multitouchID: UInt64? { pointerService?.multitouchID }
}

/// Discovers mice and keeps the live device list up to date.
///
/// Discovery is deliberately debounced. A single physical reconnect produces a
/// burst of IOKit notifications as each HID collection reappears, and probing
/// six receiver slots per burst would be both slow and pointless.
public final class DeviceRegistry: ObservableObject {
    private static let log = LoLiLog.devices

    @Published public private(set) var devices: [ManagedDevice] = []

    /// Fires after every rescan, with the devices that appeared or came back.
    /// The reconciler uses this to know when hardware settings need reapplying.
    public var onDevicesChanged: (([ManagedDevice], _ arrived: [ManagedDevice]) -> Void)?

    private let monitor = HIDDeviceMonitor()
    private let pointerRegistry = PointerServiceRegistry()
    private let scanQueue = DispatchQueue(label: "\(LoLiLog.subsystem).device-scan", qos: .userInitiated)
    private var scanWorkItem: DispatchWorkItem?
    private var started = false

    public init() {}

    public func start() {
        guard !started else { return }
        started = true

        monitor.start(.init(
            added: { [weak self] _ in self?.scheduleScan() },
            removed: { [weak self] _ in self?.scheduleScan() }
        ))
        scheduleScan(delay: 0.2)
    }

    public func stop() {
        guard started else { return }
        started = false
        scanWorkItem?.cancel()
        monitor.stop()
    }

    /// Forces a rescan, e.g. after the user grants Input Monitoring.
    public func rescan() {
        scheduleScan(delay: 0)
    }

    /// Re-reads every HID++ device's battery level.
    ///
    /// Called on a slow timer and after wake — the level changes over hours,
    /// so anything more eager would just cost the mouse radio traffic. May be
    /// called from any thread; the HID++ round trips happen on the scan queue
    /// and the published values are updated back on the main thread.
    public func refreshBatteries() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let candidates = devices.compactMap { device in
                device.target.map { (device, $0) }
            }
            scanQueue.async {
                for (device, target) in candidates {
                    guard let battery = try? target.battery().get() else { continue }
                    DispatchQueue.main.async {
                        device.battery = battery
                    }
                }
            }
        }
    }

    private func scheduleScan(delay: TimeInterval = 0.7) {
        scanWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.scan() }
        scanWorkItem = item
        scanQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scan() {
        pointerRegistry.refresh()

        let endpoints = monitor.devices.filter(HIDPPDiscovery.isCandidateEndpoint)
        let allServices = pointerRegistry.services

        var discovered: [ManagedDevice] = []
        var seenKeys = Set<String>()
        var claimedServices = Set<UInt64>()

        for endpoint in endpoints {
            for descriptor in HIDPPDiscovery.devices(on: endpoint) {
                guard !seenKeys.contains(descriptor.stableKey) else { continue }
                seenKeys.insert(descriptor.stableKey)

                // Pointer services carry the *endpoint's* USB identifiers — a
                // device behind a receiver reports the receiver's — so match on
                // those rather than on the mouse's own model ID.
                let indices = ServiceMatching.indicesMatching(
                    endpoint: Self.identity(of: endpoint),
                    services: allServices.map(Self.identity(of:))
                )
                let services = indices.map { allServices[$0] }
                for service in services { claimedServices.insert(service.registryID) }

                let device = ManagedDevice(
                    key: descriptor.stableKey,
                    displayName: descriptor.displayName,
                    target: descriptor.target,
                    endpoint: endpoint,
                    pointerService: services.first
                )
                device.senderIDs = Set(services.map(\.registryID))
                device.capabilities = Self.probeCapabilities(descriptor.target)
                // Safe to assign directly: the device is not published yet, so
                // nothing is observing it from the main thread.
                device.battery = try? descriptor.target.battery().get()
                discovered.append(device)
            }
        }

        // Mice that do not speak HID++ still get scrolling, pointer and button
        // handling. They are built from pointer services alone — no HID device
        // is opened for them, because nothing here needs one.
        for service in allServices where !claimedServices.contains(service.registryID) {
            // A leftover Logitech service carrying the same marketing name as a
            // discovered HID++ device is that device on another transport.
            // Attach it there — turning it into a separate generic device would
            // show the same mouse twice, and scroll events carrying this
            // service's sender ID would ignore the settings made on the real
            // entry.
            if let name = service.product,
               let owner = discovered.first(where: { candidate in
                   candidate.target != nil && ServiceMatching.service(
                       Self.identity(of: service),
                       belongsToDeviceNamed: candidate.displayName,
                       vendorID: HIDPP.vendorID
                   )
               }) {
                os_log("attaching stray service %{public}@ (0x%llX) to %{public}@",
                       log: Self.log, type: .info, name, service.registryID, owner.displayName)
                owner.senderIDs.insert(service.registryID)
                if owner.pointerService == nil { owner.pointerService = service }
                claimedServices.insert(service.registryID)
                continue
            }

            let key = Self.genericKey(for: service)
            guard !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)

            let device = ManagedDevice(
                key: key,
                displayName: service.product ?? "Pointing device",
                target: nil,
                endpoint: nil,
                pointerService: service
            )
            device.senderIDs = [service.registryID]
            discovered.append(device)
        }

        let previousKeys = Set(devices.map(\.key))
        let arrived = discovered.filter { !previousKeys.contains($0.key) }
        let result = discovered.sorted { $0.displayName < $1.displayName }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            devices = result
            // The sender IDs are what the event tap matches scroll and button
            // events against; logging them is the only way to tell "the tap
            // ignored the mouse" apart from "the tap was never installed".
            let summary = result.map { device in
                let senders = device.senderIDs.sorted().map { String($0, radix: 16) }.joined(separator: ",")
                return "\(device.displayName) [\(senders)]"
            }.joined(separator: "; ")
            os_log("device scan: %{public}d device(s), %{public}d new: %{public}@",
                   log: Self.log, type: .info, result.count, arrived.count, summary)
            onDevicesChanged?(result, arrived)
        }
    }

    private static func identity(of endpoint: HIDDevice) -> ServiceMatching.Identity {
        ServiceMatching.Identity(
            vendorID: endpoint.vendorID,
            productID: endpoint.productID,
            locationID: endpoint.locationID,
            product: endpoint.product
        )
    }

    private static func identity(of service: PointerService) -> ServiceMatching.Identity {
        ServiceMatching.Identity(
            vendorID: service.vendorID,
            productID: service.productID,
            locationID: service.locationID,
            product: service.product
        )
    }

    /// Asks the device what its firmware implements. Runs on the scan queue,
    /// right after discovery has already round-tripped the device successfully,
    /// so the answers are as definitive as they get. Costs one feature lookup
    /// per capability; the indices are cached on the target afterwards.
    private static func probeCapabilities(_ target: HIDPPTarget) -> DeviceCapabilities {
        var capabilities = DeviceCapabilities()
        capabilities.smartShift = target.supportsSmartShift
        capabilities.hiResWheel = target.supports(.hiResWheel)
        if capabilities.hiResWheel, let wheel = try? target.wheelCapabilities().get() {
            capabilities.wheelInvert = wheel.supportsInvert
        }
        capabilities.dpi = target.supports(.adjustableDPI)
        capabilities.reportRate = target.supports(.reportRate)
        capabilities.buttonDiversion = target.supports(.reprogrammableControlsV4)
        return capabilities
    }

    private static func genericKey(for service: PointerService) -> String {
        String(format: "usb:%04X:%04X", service.vendorID ?? 0, service.productID ?? 0)
    }

    /// Resolves a CGEvent sender ID to a device.
    public func device(senderID: UInt64) -> ManagedDevice? {
        devices.first { $0.senderIDs.contains(senderID) }
    }

    public func device(key: String) -> ManagedDevice? {
        devices.first { $0.key == key }
    }
}
