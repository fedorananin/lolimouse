// MIT License
// Copyright (c) 2026 LoLiMouse contributors
//
// Typed wrappers over the HID++ 2.0 features LoLiMouse uses. Each one is a
// direct transcription of Logitech's function table; the comments record the
// byte layouts so nobody has to rediscover them from a packet capture.

import Foundation

// MARK: - 0x0003 Device Information

/// Identity of a physical device, stable across transports.
public struct HIDPPDeviceInformation: Equatable {
    /// Four bytes that uniquely identify this individual unit. This is the best
    /// device identity available: it survives re-pairing, and it is the same
    /// whether the mouse is on Bluetooth or on a receiver.
    public let unitID: [UInt8]
    /// Product IDs for each transport the device supports, in the order
    /// Bluetooth, Bluetooth LE, eQuad, USB.
    public let modelIDs: [UInt16]
    public let extendedModelID: UInt8

    public var unitIDString: String {
        unitID.map { String(format: "%02X", $0) }.joined()
    }
}

public extension HIDPPTarget {
    func deviceInformation() -> Result<HIDPPDeviceInformation, HIDPPError> {
        // getDeviceInfo → [entityCnt, unitId(4), _, transport, modelId(6),
        //                  extendedModelId, capabilities]
        call(.deviceInformation, function: 0).flatMap { response in
            guard response.payload.count >= 14 else { return .failure(.malformedResponse) }
            let payload = response.payload
            let models = [
                UInt16(payload[7]) << 8 | UInt16(payload[8]),
                UInt16(payload[9]) << 8 | UInt16(payload[10]),
                UInt16(payload[11]) << 8 | UInt16(payload[12]),
            ]
            return .success(HIDPPDeviceInformation(
                unitID: Array(payload[1 ... 4]),
                modelIDs: models,
                extendedModelID: payload[13]
            ))
        }
    }
}

// MARK: - 0x0005 Device Name and Type

public extension HIDPPTarget {
    /// The device's marketing name, e.g. "MX Master 3S".
    ///
    /// The name is read in chunks; `getDeviceNameCount` gives the total length
    /// and `getDeviceName(index)` returns up to 16 bytes starting at `index`.
    func deviceName() -> Result<String, HIDPPError> {
        call(.deviceNameAndType, function: 0).flatMap { countResponse -> Result<String, HIDPPError> in
            guard let total = countResponse.byte(0), total > 0 else {
                return .failure(.malformedResponse)
            }

            var bytes: [UInt8] = []
            var offset = 0
            while offset < Int(total), bytes.count < 64 {
                let chunk = call(.deviceNameAndType, function: 1, parameters: [UInt8(offset)])
                guard case let .success(response) = chunk else {
                    return .failure(.malformedResponse)
                }
                let slice = response.payload.prefix(min(16, Int(total) - offset))
                if slice.isEmpty { break }
                bytes.append(contentsOf: slice)
                offset += slice.count
            }

            let trimmed = bytes.prefix { $0 != 0 }
            guard let name = String(bytes: trimmed, encoding: .utf8) else {
                return .failure(.malformedResponse)
            }
            return .success(name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

// MARK: - 0x1004 Unified Battery

public struct HIDPPBattery: Equatable {
    public let percentage: Int?
    public let charging: Bool
}

public extension HIDPPTarget {
    func battery() -> Result<HIDPPBattery, HIDPPError> {
        // getStatus → [stateOfCharge, level, status, externalPowerStatus]
        call(.unifiedBattery, function: 1).flatMap { response in
            guard let charge = response.byte(0), let status = response.byte(2) else {
                return .failure(.malformedResponse)
            }
            return .success(HIDPPBattery(
                percentage: charge <= 100 ? Int(charge) : nil,
                charging: status == 1 || status == 2
            ))
        }
    }
}

// MARK: - 0x2121 High-Resolution Wheel

public enum HIDPPWheelResolution: Equatable {
    /// One report per physical ratchet detent.
    case low
    /// Many reports per detent, `multiplier` of them.
    case high
}

public enum HIDPPWheelTarget: Equatable {
    /// Wheel movement is delivered as ordinary HID scroll.
    case native
    /// Wheel movement is delivered as HID++ notifications instead. LoLiMouse
    /// never selects this — it would take scrolling away from the OS.
    case diverted
}

public struct HIDPPWheelCapabilities: Equatable {
    /// How many high-resolution increments make up one detent. Typically 8 or
    /// 15 on the MX line.
    public let multiplier: UInt8
    public let supportsInvert: Bool
    public let supportsRatchetSwitch: Bool
    public let ratchetsPerRotation: UInt8
}

public struct HIDPPWheelMode: Equatable {
    public let target: HIDPPWheelTarget
    public let resolution: HIDPPWheelResolution
    public let inverted: Bool
}

public extension HIDPPTarget {
    func wheelCapabilities() -> Result<HIDPPWheelCapabilities, HIDPPError> {
        // getWheelCapability → [multiplier, flags, ratchetsPerRotation, diameter]
        call(.hiResWheel, function: 0).flatMap { response in
            guard response.payload.count >= 3 else { return .failure(.malformedResponse) }
            return .success(HIDPPWheelCapabilities(
                multiplier: response.payload[0],
                supportsInvert: response.payload[1] & (1 << 3) != 0,
                supportsRatchetSwitch: response.payload[1] & (1 << 2) != 0,
                ratchetsPerRotation: response.payload[2]
            ))
        }
    }

    func wheelMode() -> Result<HIDPPWheelMode, HIDPPError> {
        // getWheelMode → [flags] where bit0 = target, bit1 = resolution, bit2 = invert
        call(.hiResWheel, function: 1).flatMap { response in
            guard let flags = response.byte(0) else { return .failure(.malformedResponse) }
            return .success(Self.decodeWheelMode(flags))
        }
    }

    @discardableResult
    func setWheelMode(
        target: HIDPPWheelTarget,
        resolution: HIDPPWheelResolution,
        inverted: Bool
    ) -> Result<HIDPPWheelMode, HIDPPError> {
        var flags: UInt8 = 0
        if target == .diverted { flags |= 1 << 0 }
        if resolution == .high { flags |= 1 << 1 }
        if inverted { flags |= 1 << 2 }

        return call(.hiResWheel, function: 2, parameters: [flags]).flatMap { response in
            guard let applied = response.byte(0) else { return .failure(.malformedResponse) }
            return .success(Self.decodeWheelMode(applied))
        }
    }

    private static func decodeWheelMode(_ flags: UInt8) -> HIDPPWheelMode {
        HIDPPWheelMode(
            target: flags & (1 << 0) != 0 ? .diverted : .native,
            resolution: flags & (1 << 1) != 0 ? .high : .low,
            inverted: flags & (1 << 2) != 0
        )
    }
}

// MARK: - 0x2110 / 0x2111 SmartShift

public enum HIDPPWheelRatchetMode: UInt8, Equatable, Codable, CaseIterable {
    /// The wheel spins freely with no detents.
    case freespin = 1
    /// The wheel clicks through detents.
    case ratchet = 2
}

public struct HIDPPSmartShift: Equatable {
    public let mode: HIDPPWheelRatchetMode
    /// Wheel speed, in quarter-turns per second, past which a ratcheting wheel
    /// releases into free spin. `0xFF` disables the release entirely, which is
    /// the "always ratchet" setting.
    public let autoDisengage: UInt8
    /// Ratchet resistance as a percentage of maximum force, or `nil` on devices
    /// without a tunable-torque motor.
    public let torque: UInt8?
    /// Whether the device answered on `0x2111` rather than `0x2110`.
    public let enhanced: Bool

    /// `autoDisengage` value that keeps the ratchet permanently engaged.
    public static let permanentRatchet: UInt8 = 0xFF

    public var isPermanentRatchet: Bool {
        mode == .ratchet && autoDisengage == Self.permanentRatchet
    }
}

public extension HIDPPTarget {
    /// Whether this device can have its wheel ratchet controlled at all.
    var supportsSmartShift: Bool {
        supports(.smartShiftEnhanced) || supports(.smartShift)
    }

    func smartShift() -> Result<HIDPPSmartShift, HIDPPError> {
        if case .success(let enhanced) = enhancedSmartShift() {
            return .success(enhanced)
        }
        return legacySmartShift()
    }

    /// Writes wheel mode and threshold.
    ///
    /// HID++ treats a zero byte as "leave unchanged", so a caller that only
    /// wants to flip the mode passes `nil` for the rest.
    @discardableResult
    func setSmartShift(
        mode: HIDPPWheelRatchetMode?,
        autoDisengage: UInt8?,
        torque: UInt8? = nil
    ) -> Result<HIDPPSmartShift, HIDPPError> {
        if supports(.smartShiftEnhanced) {
            let parameters: [UInt8] = [
                mode?.rawValue ?? 0,
                autoDisengage ?? 0,
                torque ?? 0,
            ]
            let result = call(.smartShiftEnhanced, function: 2, parameters: parameters)
            switch result {
            case let .success(response):
                return .success(Self.decodeEnhanced(response))
            case let .failure(error):
                return .failure(error)
            }
        }

        let parameters: [UInt8] = [
            mode?.rawValue ?? 0,
            autoDisengage ?? 0,
            0, // never overwrite the device's factory default threshold
        ]
        return call(.smartShift, function: 1, parameters: parameters).flatMap { _ in
            legacySmartShift()
        }
    }

    private func enhancedSmartShift() -> Result<HIDPPSmartShift, HIDPPError> {
        call(.smartShiftEnhanced, function: 1).flatMap { response in
            .success(Self.decodeEnhanced(response))
        }
    }

    private func legacySmartShift() -> Result<HIDPPSmartShift, HIDPPError> {
        // getRatchetControlMode → [wheelMode, autoDisengage, autoDisengageDefault]
        call(.smartShift, function: 0).flatMap { response in
            guard response.payload.count >= 2,
                  let mode = HIDPPWheelRatchetMode(rawValue: response.payload[0])
            else {
                return .failure(.malformedResponse)
            }
            return .success(HIDPPSmartShift(
                mode: mode,
                autoDisengage: response.payload[1],
                torque: nil,
                enhanced: false
            ))
        }
    }

    private static func decodeEnhanced(_ response: HIDPPResponse) -> HIDPPSmartShift {
        // getRatchetControlMode → [wheelMode, autoDisengage, currentTorque]
        let mode = HIDPPWheelRatchetMode(rawValue: response.byte(0) ?? 0) ?? .ratchet
        let torque = response.byte(2)
        return HIDPPSmartShift(
            mode: mode,
            autoDisengage: response.byte(1) ?? HIDPPSmartShift.permanentRatchet,
            torque: (torque ?? 0) > 0 ? torque : nil,
            enhanced: true
        )
    }
}

// MARK: - 0x2201 Adjustable DPI

public struct HIDPPSensorDPI: Equatable {
    public let sensorIndex: UInt8
    public let current: UInt16
    /// Either an explicit list of supported values, or a range expressed as
    /// `stride(from:through:by:)`.
    public let supported: [UInt16]

    public var minimum: UInt16? { supported.min() }
    public var maximum: UInt16? { supported.max() }
}

public extension HIDPPTarget {
    func sensorCount() -> Result<UInt8, HIDPPError> {
        call(.adjustableDPI, function: 0).flatMap { response in
            guard let count = response.byte(0) else { return .failure(.malformedResponse) }
            return .success(count)
        }
    }

    func dpi(sensor: UInt8 = 0) -> Result<HIDPPSensorDPI, HIDPPError> {
        // getSensorDpi → [sensorIndex, dpi(2), defaultDpi(2)]
        let currentResult = call(.adjustableDPI, function: 2, parameters: [sensor])
        guard case let .success(currentResponse) = currentResult else {
            return .failure((try? currentResult.get()) == nil ? .timeout : .malformedResponse)
        }
        guard let current = currentResponse.word(1) else { return .failure(.malformedResponse) }

        let supported = dpiList(sensor: sensor)
        return .success(HIDPPSensorDPI(sensorIndex: sensor, current: current, supported: supported))
    }

    /// The DPI values this sensor accepts.
    ///
    /// Logitech encodes the list as 16-bit words; a word whose top bit is set
    /// marks the previous value as the start of a range and encodes the step,
    /// so `[200, 0xE004, 4000]` means 200 to 4000 in steps of 4.
    func dpiList(sensor: UInt8 = 0) -> [UInt16] {
        guard case let .success(response) = call(.adjustableDPI, function: 1, parameters: [sensor]) else {
            return []
        }

        var values: [UInt16] = []
        var index = 1
        var pendingStep: UInt16?

        while index + 1 < response.payload.count {
            let word = UInt16(response.payload[index]) << 8 | UInt16(response.payload[index + 1])
            index += 2
            if word == 0 { break }

            if word & 0xE000 == 0xE000 {
                pendingStep = word & 0x1FFF
                continue
            }

            if let step = pendingStep, step > 0, let start = values.last, word > start {
                var value = start + step
                while value <= word {
                    values.append(value)
                    value += step
                }
                pendingStep = nil
            } else {
                values.append(word)
                pendingStep = nil
            }
        }

        return values.sorted()
    }

    @discardableResult
    func setDPI(_ dpi: UInt16, sensor: UInt8 = 0) -> Result<Void, HIDPPError> {
        let parameters: [UInt8] = [sensor, UInt8(dpi >> 8), UInt8(dpi & 0xFF)]
        return call(.adjustableDPI, function: 3, parameters: parameters).map { _ in () }
    }
}

// MARK: - 0x2150 Thumbwheel

public enum HIDPPThumbwheelMode: UInt8 {
    /// The thumbwheel produces ordinary horizontal scroll.
    case native = 0
    /// The thumbwheel produces HID++ notifications we handle ourselves.
    case diverted = 1
}

public extension HIDPPTarget {
    var hasThumbwheel: Bool { supports(.thumbwheel) }

    @discardableResult
    func setThumbwheelMode(_ mode: HIDPPThumbwheelMode, inverted: Bool = false) -> Result<Void, HIDPPError> {
        call(.thumbwheel, function: 2, parameters: [mode.rawValue, inverted ? 1 : 0]).map { _ in () }
    }

    func thumbwheelMode() -> Result<HIDPPThumbwheelMode, HIDPPError> {
        call(.thumbwheel, function: 1).flatMap { response in
            guard let raw = response.byte(0), let mode = HIDPPThumbwheelMode(rawValue: raw) else {
                return .failure(.malformedResponse)
            }
            return .success(mode)
        }
    }
}

// MARK: - 0x8060 Report Rate

public extension HIDPPTarget {
    /// Supported report rates in milliseconds per report (1 = 1000 Hz).
    func supportedReportRates() -> [Int] {
        guard case let .success(response) = call(.reportRate, function: 0),
              let mask = response.byte(0)
        else {
            return []
        }
        return (0 ..< 8).compactMap { bit in
            mask & (1 << UInt8(bit)) != 0 ? bit + 1 : nil
        }
    }

    func reportRate() -> Result<Int, HIDPPError> {
        call(.reportRate, function: 1).flatMap { response in
            guard let value = response.byte(0), value > 0 else { return .failure(.malformedResponse) }
            return .success(Int(value))
        }
    }

    @discardableResult
    func setReportRate(_ milliseconds: Int) -> Result<Void, HIDPPError> {
        call(.reportRate, function: 2, parameters: [UInt8(clamping: milliseconds)]).map { _ in () }
    }
}
