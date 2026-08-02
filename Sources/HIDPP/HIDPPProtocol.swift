// MIT License
// Copyright (c) 2026 LoLiMouse contributors
//
// Wire-level constants for Logitech's HID++ protocol.
//
// Protocol references:
//   - Logitech HID++ 2.0 specification (public developer documentation)
//   - Solaar's feature catalogue: https://pwr-solaar.github.io/Solaar/
//   - The Linux hid-logitech-hidpp / hid-logitech-dj drivers

import Foundation

public enum HIDPP {
    /// USB vendor ID shared by every Logitech device.
    public static let vendorID = 0x046D

    /// Report IDs carrying HID++ traffic.
    public static let shortReportID: UInt8 = 0x10
    public static let longReportID: UInt8 = 0x11

    /// Total report sizes, including the leading report-ID byte.
    public static let shortReportLength = 7
    public static let longReportLength = 20

    /// Identifies our traffic in the low nibble of the address byte so replies
    /// to another application's requests are not mistaken for ours. Any value
    /// in 1…15 is valid.
    public static let softwareID: UInt8 = 0x0A

    /// Device index used when talking to a directly connected device (Bluetooth
    /// or wired) rather than through a receiver.
    public static let directIndex: UInt8 = 0xFF

    /// Directly connected devices answer under either of these indices
    /// depending on firmware generation.
    public static let directReplyIndices: Set<UInt8> = [0x00, 0xFF]

    /// Slots a receiver can host.
    public static let receiverSlots: ClosedRange<UInt8> = 1 ... 6

    /// Marks a HID++ 2.0 error reply.
    public static let errorFeatureIndex: UInt8 = 0xFF

    /// Marks a HID++ 1.0 error reply.
    public static let legacyErrorSubID: UInt8 = 0x8F

    public static let defaultTimeout: TimeInterval = 1.5
}

/// HID++ 2.0 error codes, as returned in an error reply.
public enum HIDPPErrorCode: UInt8 {
    case noError = 0x00
    case unknown = 0x01
    case invalidArgument = 0x02
    case outOfRange = 0x03
    case hardwareError = 0x04
    case logitechInternal = 0x05
    case invalidFeatureIndex = 0x06
    case invalidFunctionID = 0x07
    case busy = 0x08
    case unsupported = 0x09
}

public enum HIDPPError: Error, CustomStringConvertible {
    /// No reply arrived before the timeout. Usually means the device is asleep,
    /// out of range, or the slot is empty.
    case timeout
    /// The transport refused to send the report at all.
    case transportFailure
    /// The device answered with a HID++ 2.0 error.
    case device(HIDPPErrorCode)
    /// The device answered with a HID++ 1.0 error.
    case legacy(UInt8)
    /// The device does not implement the requested feature.
    case featureUnsupported(HIDPPFeatureID)
    /// The reply was structurally valid but too short to parse.
    case malformedResponse

    public var description: String {
        switch self {
        case .timeout: return "timed out"
        case .transportFailure: return "transport failure"
        case let .device(code): return "device error \(code)"
        case let .legacy(code): return String(format: "HID++ 1.0 error 0x%02X", code)
        case let .featureUnsupported(feature): return "feature \(feature) unsupported"
        case .malformedResponse: return "malformed response"
        }
    }

    /// Whether retrying the same request might succeed. A sleeping device times
    /// out and a busy device says so; an unsupported feature never will.
    public var isTransient: Bool {
        switch self {
        case .timeout, .transportFailure, .malformedResponse:
            return true
        case let .device(code):
            return code == .busy || code == .hardwareError
        case .legacy:
            return true
        case .featureUnsupported:
            return false
        }
    }
}

/// HID++ 2.0 feature identifiers used by LoLiMouse.
public enum HIDPPFeatureID: UInt16, CaseIterable, CustomStringConvertible {
    case root = 0x0000
    case featureSet = 0x0001
    case deviceInformation = 0x0003
    case deviceNameAndType = 0x0005
    case batteryStatus = 0x1000
    case unifiedBattery = 0x1004
    case reprogrammableControlsV4 = 0x1B04
    case smartShift = 0x2110
    case smartShiftEnhanced = 0x2111
    case hiResWheel = 0x2121
    case thumbwheel = 0x2150
    case adjustableDPI = 0x2201
    case extendedAdjustableDPI = 0x2202
    case reportRate = 0x8060
    case extendedReportRate = 0x8061

    public var bytes: [UInt8] {
        [UInt8(rawValue >> 8), UInt8(rawValue & 0xFF)]
    }

    public var description: String {
        String(format: "0x%04X", rawValue)
    }
}

/// A parsed HID++ reply: everything after the four-byte header.
public struct HIDPPResponse {
    public let deviceIndex: UInt8
    public let featureIndex: UInt8
    public let address: UInt8
    public let payload: [UInt8]

    public init(deviceIndex: UInt8, featureIndex: UInt8, address: UInt8, payload: [UInt8]) {
        self.deviceIndex = deviceIndex
        self.featureIndex = featureIndex
        self.address = address
        self.payload = payload
    }

    public func byte(_ index: Int) -> UInt8? {
        index < payload.count ? payload[index] : nil
    }

    public func word(_ index: Int) -> UInt16? {
        guard index + 1 < payload.count else { return nil }
        return UInt16(payload[index]) << 8 | UInt16(payload[index + 1])
    }
}
