// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation
import HIDKit
import os.log

/// A Logitech device found on a HID++ endpoint, together with everything needed
/// to identify it across reconnects.
public struct HIDPPDeviceDescriptor {
    public let target: HIDPPTarget
    public let name: String?
    public let information: HIDPPDeviceInformation?
    /// `true` when reached through a receiver rather than directly.
    public let viaReceiver: Bool
    /// The endpoint the conversation runs over. Useful for grouping and logs.
    public let endpoint: HIDDevice

    /// A stable key for this physical device.
    ///
    /// The unit ID is the strongest choice: it identifies the individual mouse
    /// regardless of whether it is on Bluetooth, on a Bolt receiver, or wired,
    /// so settings follow the hardware rather than the connection. Devices that
    /// do not implement `0x0003` fall back to their name, then to USB IDs.
    public var stableKey: String {
        if let unitID = information?.unitIDString, !unitID.isEmpty, unitID != "00000000" {
            return "unit:\(unitID)"
        }
        if let name, !name.isEmpty {
            return "name:\(name)"
        }
        return String(format: "usb:%04X:%04X", endpoint.vendorID ?? 0, endpoint.productID ?? 0)
    }

    public var displayName: String {
        name ?? endpoint.product ?? "Logitech device"
    }
}

/// Finds HID++ endpoints and enumerates the devices reachable through them.
public enum HIDPPDiscovery {
    private static let log = LoLiLog.hidpp

    /// Product IDs of Logitech receivers that multiplex several devices.
    ///
    /// Sources: Solaar's receiver catalogue and the Linux `hid-logitech-dj`
    /// driver. An endpoint on this list is never probed as a direct device.
    public static let receiverProductIDs: Set<Int> = [
        0xC52B, 0xC532,                                     // Unifying
        0xC539, 0xC53A, 0xC53D, 0xC53F, 0xC541, 0xC543,     // Lightspeed
        0xC545, 0xC547, 0xC54D,
        0xC548,                                             // Bolt
        0xC52E, 0xC52F, 0xC534, 0xC535, 0xC542,             // Nano
        0xC518, 0xC51A, 0xC521, 0xC525, 0xC526,
    ]

    /// Whether this HID device looks like it can carry HID++ traffic.
    ///
    /// Logitech puts HID++ on a vendor-defined usage page, but not necessarily
    /// as the *primary* one: a mouse connected over Bluetooth presents a single
    /// HID device whose primary usage is Mouse, with the vendor collection
    /// listed beside it. Checking every top-level collection rather than just
    /// the primary one is what makes Bluetooth-connected mice work at all.
    public static func isCandidateEndpoint(_ device: HIDDevice) -> Bool {
        guard device.vendorID == HIDPP.vendorID else { return false }
        guard (device.maxOutputReportSize ?? 0) >= HIDPP.shortReportLength - 1 else { return false }
        return device.hasVendorDefinedCollection
    }

    public static func isReceiver(_ device: HIDDevice) -> Bool {
        guard let productID = device.productID else { return false }
        return receiverProductIDs.contains(productID)
    }

    /// Enumerates every device reachable through `endpoint`.
    ///
    /// This performs blocking HID transactions and must run off the main thread.
    public static func devices(on endpoint: HIDDevice) -> [HIDPPDeviceDescriptor] {
        guard isCandidateEndpoint(endpoint), let channel = HIDPPChannel(endpoint: endpoint) else {
            return []
        }
        guard endpoint.open() else {
            os_log("cannot open HID++ endpoint %{public}@ — check Input Monitoring",
                   log: log, type: .error, endpoint.description)
            return []
        }

        if !isReceiver(endpoint) {
            let direct = HIDPPTarget(channel: channel, deviceIndex: HIDPP.directIndex)
            if direct.ping() {
                return [describe(direct, endpoint: endpoint, viaReceiver: false)]
            }
        }

        var found: [HIDPPDeviceDescriptor] = []
        for slot in HIDPP.receiverSlots {
            let target = HIDPPTarget(channel: channel, deviceIndex: slot)
            guard target.ping() else { continue }
            found.append(describe(target, endpoint: endpoint, viaReceiver: true))
        }
        return found
    }

    private static func describe(
        _ target: HIDPPTarget,
        endpoint: HIDDevice,
        viaReceiver: Bool
    ) -> HIDPPDeviceDescriptor {
        let name = try? target.deviceName().get()
        let information = try? target.deviceInformation().get()

        os_log("HID++ device on %{public}@#%02X: %{public}@ [%{public}@]",
               log: log, type: .info,
               endpoint.description, target.deviceIndex,
               name ?? "(unnamed)",
               information?.unitIDString ?? "no unit id")

        return HIDPPDeviceDescriptor(
            target: target,
            name: name,
            information: information,
            viaReceiver: viaReceiver,
            endpoint: endpoint
        )
    }
}
