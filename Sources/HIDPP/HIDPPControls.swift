// MIT License
// Copyright (c) 2026 LoLiMouse contributors
//
// Feature 0x1B04, "Reprogrammable Controls v4" (Logitech calls it
// SpecialKeysMSEButtons). This is how the buttons that macOS never sees —
// the wheel-mode button, the thumb button — are made available to software:
// each control is diverted, after which presses arrive as HID++ notifications
// instead of HID button reports.

import Foundation

public typealias HIDPPControlID = UInt16

/// The control IDs LoLiMouse knows by name.
///
/// The full table is device-specific and is enumerated at runtime through
/// `getCidInfo`; these constants only exist so the UI can label the buttons
/// people actually care about.
public enum HIDPPControl {
    public static let leftClick: HIDPPControlID = 0x0050
    public static let rightClick: HIDPPControlID = 0x0051
    public static let middleClick: HIDPPControlID = 0x0052
    public static let back: HIDPPControlID = 0x0053
    public static let forward: HIDPPControlID = 0x0056

    /// The button under the thumb rest on MX Master mice. Logitech ships it as
    /// the "gesture button": held down, it also streams pointer movement.
    public static let gestureButton: HIDPPControlID = 0x00C3
    public static let multiplatformGestureButton: HIDPPControlID = 0x00D0
    public static let virtualGestureButton: HIDPPControlID = 0x00D7

    /// The small button just below the scroll wheel. Named SmartShift because
    /// its factory function is toggling the wheel ratchet.
    public static let wheelModeButton: HIDPPControlID = 0x00C4

    /// Buttons macOS already handles correctly. Diverting these would break
    /// ordinary clicking, so they are never offered for remapping.
    public static let systemHandled: Set<HIDPPControlID> = [
        leftClick, rightClick, back, forward,
        0x00CE, 0x00CF, 0x00D9, 0x00DB,
    ]

    /// Every control that behaves like the MX Master thumb button.
    public static let gestureCapable: Set<HIDPPControlID> = [
        gestureButton, multiplatformGestureButton, virtualGestureButton,
    ]

    public static func name(for control: HIDPPControlID) -> String? {
        switch control {
        case leftClick: return "Left click"
        case rightClick: return "Right click"
        case middleClick: return "Middle click"
        case back: return "Back"
        case forward: return "Forward"
        case gestureButton, multiplatformGestureButton, virtualGestureButton: return "Thumb button"
        case wheelModeButton: return "Wheel mode button"
        default: return nil
        }
    }
}

/// Capability bits from `getCidInfo`.
public struct HIDPPControlFlags: OptionSet, Equatable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let mouseButton = HIDPPControlFlags(rawValue: 1 << 0)
    public static let functionKey = HIDPPControlFlags(rawValue: 1 << 1)
    public static let hotkey = HIDPPControlFlags(rawValue: 1 << 2)
    public static let fnToggle = HIDPPControlFlags(rawValue: 1 << 3)
    public static let reprogrammable = HIDPPControlFlags(rawValue: 1 << 4)
    public static let divertable = HIDPPControlFlags(rawValue: 1 << 5)
    public static let persistentlyDivertable = HIDPPControlFlags(rawValue: 1 << 6)
    public static let virtualControl = HIDPPControlFlags(rawValue: 1 << 7)
    public static let rawXY = HIDPPControlFlags(rawValue: 1 << 8)
    public static let forceRawXY = HIDPPControlFlags(rawValue: 1 << 9)
    public static let analyticsKeyEvents = HIDPPControlFlags(rawValue: 1 << 10)
    public static let rawWheel = HIDPPControlFlags(rawValue: 1 << 11)
}

/// One row of the device's control table.
public struct HIDPPControlInfo: Equatable {
    public let controlID: HIDPPControlID
    public let taskID: UInt16
    public let flags: HIDPPControlFlags
    public let position: UInt8
    public let group: UInt8
    public let groupMask: UInt8

    public var isDivertable: Bool { flags.contains(.divertable) }
    public var supportsRawXY: Bool { flags.contains(.rawXY) }

    /// A label for the UI: the friendly name when we have one, otherwise the
    /// raw control ID.
    public var displayName: String {
        HIDPPControl.name(for: controlID) ?? String(format: "Button 0x%04X", controlID)
    }
}

/// The current diversion state of one control.
public struct HIDPPControlReporting: Equatable {
    public let controlID: HIDPPControlID
    public let diverted: Bool
    public let persistentlyDiverted: Bool
    public let rawXY: Bool
    public let remap: HIDPPControlID?
}

/// A partial update to a control's diversion state. `nil` leaves a field alone.
public struct HIDPPControlReportingChange {
    public var diverted: Bool?
    public var persistentlyDiverted: Bool?
    public var rawXY: Bool?
    public var remap: HIDPPControlID?

    public init(
        diverted: Bool? = nil,
        persistentlyDiverted: Bool? = nil,
        rawXY: Bool? = nil,
        remap: HIDPPControlID? = nil
    ) {
        self.diverted = diverted
        self.persistentlyDiverted = persistentlyDiverted
        self.rawXY = rawXY
        self.remap = remap
    }
}

/// An unsolicited notification from feature 0x1B04.
public enum HIDPPControlEvent: Equatable {
    /// The complete set of diverted controls currently held down. An empty set
    /// means everything was released — the device reports state, not edges.
    case buttonsPressed(Set<HIDPPControlID>)
    /// Pointer movement, streamed while a raw-XY control is held.
    case rawXY(dx: Int16, dy: Int16)
}

public extension HIDPPTarget {
    var supportsReprogrammableControls: Bool { supports(.reprogrammableControlsV4) }

    /// Reads the device's whole control table.
    ///
    /// This costs one round trip per row, so the result is cached — the table
    /// is fixed in firmware and cannot change while the device stays connected.
    func controlTable() -> [HIDPPControlInfo] {
        if let cached = cachedControlTable { return cached }

        guard supportsLongReports,
              case let .success(countResponse) = call(.reprogrammableControlsV4, function: 0),
              let count = countResponse.byte(0), count > 0
        else {
            return []
        }

        var controls: [HIDPPControlInfo] = []
        for index in 0 ..< count {
            guard case let .success(response) = call(
                .reprogrammableControlsV4,
                function: 1,
                parameters: [index]
            ) else {
                continue
            }
            let payload = response.payload
            guard payload.count >= 9 else { continue }
            controls.append(HIDPPControlInfo(
                controlID: UInt16(payload[0]) << 8 | UInt16(payload[1]),
                taskID: UInt16(payload[2]) << 8 | UInt16(payload[3]),
                flags: HIDPPControlFlags(rawValue: UInt16(payload[4]) | UInt16(payload[8]) << 8),
                position: payload[5],
                group: payload[6],
                groupMask: payload[7]
            ))
        }
        cachedControlTable = controls
        return controls
    }

    func controlReporting(_ control: HIDPPControlID) -> Result<HIDPPControlReporting, HIDPPError> {
        let parameters: [UInt8] = [UInt8(control >> 8), UInt8(control & 0xFF)]
        return call(.reprogrammableControlsV4, function: 2, parameters: parameters)
            .flatMap { response in
                let payload = response.payload
                guard payload.count >= 5 else { return .failure(.malformedResponse) }
                let remap = UInt16(payload[3]) << 8 | UInt16(payload[4])
                return .success(HIDPPControlReporting(
                    controlID: UInt16(payload[0]) << 8 | UInt16(payload[1]),
                    diverted: payload[2] & (1 << 0) != 0,
                    persistentlyDiverted: payload[2] & (1 << 2) != 0,
                    rawXY: payload[2] & (1 << 4) != 0,
                    remap: remap != 0 ? remap : nil
                ))
            }
    }

    /// Applies a diversion change.
    ///
    /// Each boolean travels as a value bit plus a "this field is valid" bit, so
    /// unset fields really are left untouched by the firmware.
    @discardableResult
    func setControlReporting(
        _ control: HIDPPControlID,
        _ change: HIDPPControlReportingChange
    ) -> Result<Void, HIDPPError> {
        guard supportsLongReports else {
            return .failure(.featureUnsupported(.reprogrammableControlsV4))
        }

        var parameters = [UInt8](repeating: 0, count: 16)
        parameters[0] = UInt8(control >> 8)
        parameters[1] = UInt8(control & 0xFF)

        if let diverted = change.diverted {
            parameters[2] |= 1 << 1
            parameters[2] |= diverted ? 1 : 0
        }
        if let persistent = change.persistentlyDiverted {
            parameters[2] |= 1 << 3
            parameters[2] |= (persistent ? 1 : 0) << 2
        }
        if let rawXY = change.rawXY {
            parameters[2] |= 1 << 5
            parameters[2] |= (rawXY ? 1 : 0) << 4
        }
        if let remap = change.remap {
            parameters[3] = UInt8(remap >> 8)
            parameters[4] = UInt8(remap & 0xFF)
        }

        return call(.reprogrammableControlsV4, function: 3, parameters: parameters).map { _ in () }
    }

    /// Decodes a raw notification into a control event, or `nil` if it belongs
    /// to another feature.
    func decodeControlEvent(_ response: HIDPPResponse) -> HIDPPControlEvent? {
        guard response.deviceIndex == deviceIndex,
              let featureIndex = cachedFeatureIndex(.reprogrammableControlsV4),
              response.featureIndex == featureIndex
        else {
            return nil
        }

        let function = response.address >> 4
        let payload = response.payload

        switch function {
        case 0:
            // Four control-ID slots; zero means "no button in this slot".
            var pressed: Set<HIDPPControlID> = []
            var offset = 0
            while offset + 1 < payload.count, offset < 8 {
                let control = UInt16(payload[offset]) << 8 | UInt16(payload[offset + 1])
                if control != 0 { pressed.insert(control) }
                offset += 2
            }
            return .buttonsPressed(pressed)

        case 1:
            guard payload.count >= 4 else { return nil }
            let dx = Int16(bitPattern: UInt16(payload[0]) << 8 | UInt16(payload[1]))
            let dy = Int16(bitPattern: UInt16(payload[2]) << 8 | UInt16(payload[3]))
            return .rawXY(dx: dx, dy: dy)

        default:
            return nil
        }
    }
}
