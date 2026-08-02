// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation
import HIDKit
import os.log

/// A HID++ conversation over one HID endpoint.
///
/// One channel serves every device behind it: a directly connected mouse uses
/// index `0xFF`, while a receiver multiplexes slots 1…6 over the same endpoint.
/// Requests are serialised per channel so two slots cannot interleave.
public final class HIDPPChannel {
    private static let log = LoLiLog.hidpp

    public let endpoint: HIDDevice
    public let reportID: UInt8
    public let reportLength: Int

    private let requestLock = NSLock()

    /// Fails when the endpoint cannot carry HID++ reports at all.
    public init?(endpoint: HIDDevice) {
        let maxOutput = endpoint.maxOutputReportSize ?? 0
        // IOKit is inconsistent about whether the report-ID byte counts toward
        // the maximum, so accept either interpretation.
        if maxOutput >= HIDPP.longReportLength - 1 {
            reportID = HIDPP.longReportID
            reportLength = HIDPP.longReportLength
        } else if maxOutput >= HIDPP.shortReportLength - 1 {
            reportID = HIDPP.shortReportID
            reportLength = HIDPP.shortReportLength
        } else {
            return nil
        }
        self.endpoint = endpoint
    }

    public var isValid: Bool { endpoint.isValid }

    /// Issues a HID++ 2.0 function call.
    ///
    /// `busy` replies are retried a few times because devices routinely answer
    /// busy while waking from sleep.
    public func request(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        function: UInt8,
        parameters: [UInt8] = [],
        timeout: TimeInterval = HIDPP.defaultTimeout
    ) -> Result<HIDPPResponse, HIDPPError> {
        let maxAttempts = 3
        var lastError = HIDPPError.timeout

        for attempt in 1 ... maxAttempts {
            let result = performRequest(
                deviceIndex: deviceIndex,
                featureIndex: featureIndex,
                function: function,
                parameters: parameters,
                timeout: timeout
            )
            switch result {
            case .success:
                return result
            case let .failure(error):
                lastError = error
                guard case let .device(code) = error, code == .busy, attempt < maxAttempts else {
                    return result
                }
                Thread.sleep(forTimeInterval: 0.02 * Double(attempt))
            }
        }

        return .failure(lastError)
    }

    private func performRequest(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        function: UInt8,
        parameters: [UInt8],
        timeout: TimeInterval
    ) -> Result<HIDPPResponse, HIDPPError> {
        let address = (function << 4) | HIDPP.softwareID
        let report = makeReport(deviceIndex: deviceIndex, featureIndex: featureIndex,
                                address: address, parameters: parameters)

        let acceptedIndices: Set<UInt8> = deviceIndex == HIDPP.directIndex
            ? HIDPP.directReplyIndices
            : [deviceIndex]

        let matcher: (Data) -> Bool = { data in
            let reply = [UInt8](data)
            guard reply.count >= HIDPP.shortReportLength,
                  reply[0] == HIDPP.shortReportID || reply[0] == HIDPP.longReportID,
                  acceptedIndices.contains(reply[1])
            else {
                return false
            }
            // HID++ 2.0 error: 0xFF, then the feature and address we asked for.
            if reply[2] == HIDPP.errorFeatureIndex {
                return reply.count >= 6 && reply[3] == featureIndex && reply[4] == address
            }
            // HID++ 1.0 error, only meaningful for register access.
            if reply[2] == HIDPP.legacyErrorSubID {
                return reply.count >= 6 && reply[3] == featureIndex
            }
            return reply[2] == featureIndex && reply[3] == address
        }

        requestLock.lock()
        let data = endpoint.transact(output: report, timeout: timeout, matching: matcher)
        requestLock.unlock()

        guard let data else { return .failure(.timeout) }

        let reply = [UInt8](data)
        guard reply.count >= 4 else { return .failure(.malformedResponse) }

        if reply[2] == HIDPP.errorFeatureIndex {
            guard reply.count >= 6 else { return .failure(.malformedResponse) }
            let code = HIDPPErrorCode(rawValue: reply[5]) ?? .unknown
            return .failure(.device(code))
        }
        if reply[2] == HIDPP.legacyErrorSubID {
            guard reply.count >= 6 else { return .failure(.malformedResponse) }
            return .failure(.legacy(reply[5]))
        }

        return .success(HIDPPResponse(
            deviceIndex: reply[1],
            featureIndex: reply[2],
            address: reply[3],
            payload: Array(reply.dropFirst(4))
        ))
    }

    /// HID++ 1.0 short-register read, used for receiver housekeeping.
    public func readRegister(
        deviceIndex: UInt8,
        register: UInt8,
        parameters: [UInt8] = [],
        long: Bool = false,
        timeout: TimeInterval = HIDPP.defaultTimeout
    ) -> Result<HIDPPResponse, HIDPPError> {
        legacyRequest(subID: long ? 0x83 : 0x81, deviceIndex: deviceIndex,
                      register: register, parameters: parameters, timeout: timeout)
    }

    /// HID++ 1.0 short-register write.
    @discardableResult
    public func writeRegister(
        deviceIndex: UInt8,
        register: UInt8,
        parameters: [UInt8],
        long: Bool = false,
        timeout: TimeInterval = HIDPP.defaultTimeout
    ) -> Result<HIDPPResponse, HIDPPError> {
        legacyRequest(subID: long ? 0x82 : 0x80, deviceIndex: deviceIndex,
                      register: register, parameters: parameters, timeout: timeout)
    }

    private func legacyRequest(
        subID: UInt8,
        deviceIndex: UInt8,
        register: UInt8,
        parameters: [UInt8],
        timeout: TimeInterval
    ) -> Result<HIDPPResponse, HIDPPError> {
        let report = makeReport(deviceIndex: deviceIndex, featureIndex: subID,
                                address: register, parameters: parameters)

        let matcher: (Data) -> Bool = { data in
            let reply = [UInt8](data)
            guard reply.count >= HIDPP.shortReportLength,
                  reply[0] == HIDPP.shortReportID || reply[0] == HIDPP.longReportID,
                  reply[1] == deviceIndex
            else {
                return false
            }
            if reply[2] == HIDPP.legacyErrorSubID {
                return reply.count >= 6 && reply[3] == subID && reply[4] == register
            }
            return reply[2] == subID && reply[3] == register
        }

        requestLock.lock()
        let data = endpoint.transact(output: report, timeout: timeout, matching: matcher)
        requestLock.unlock()

        guard let data else { return .failure(.timeout) }
        let reply = [UInt8](data)
        guard reply.count >= 4 else { return .failure(.malformedResponse) }

        if reply[2] == HIDPP.legacyErrorSubID {
            guard reply.count >= 6 else { return .failure(.malformedResponse) }
            return .failure(.legacy(reply[5]))
        }

        return .success(HIDPPResponse(
            deviceIndex: reply[1],
            featureIndex: reply[2],
            address: reply[3],
            payload: Array(reply.dropFirst(4))
        ))
    }

    private func makeReport(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        address: UInt8,
        parameters: [UInt8]
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: reportLength)
        bytes[0] = reportID
        bytes[1] = deviceIndex
        bytes[2] = featureIndex
        bytes[3] = address
        for (offset, value) in parameters.enumerated() where offset + 4 < bytes.count {
            bytes[offset + 4] = value
        }
        return Data(bytes)
    }

    /// Observes unsolicited HID++ notifications, such as diverted button
    /// presses. The closure runs on the endpoint's dispatch queue.
    public func observeNotifications(_ closure: @escaping (HIDPPResponse) -> Void) -> HIDObservation {
        endpoint.observeInputReports { data in
            let reply = [UInt8](data)
            guard reply.count >= 4,
                  reply[0] == HIDPP.shortReportID || reply[0] == HIDPP.longReportID
            else {
                return
            }
            // Notifications carry a software ID of zero in the low nibble;
            // replies to our own requests carry ours.
            guard reply[3] & 0x0F == 0 else { return }
            closure(HIDPPResponse(
                deviceIndex: reply[1],
                featureIndex: reply[2],
                address: reply[3],
                payload: Array(reply.dropFirst(4))
            ))
        }
    }
}
