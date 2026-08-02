// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation
import HIDKit
import os.log

/// One addressable HID++ 2.0 device: a channel plus the index it answers on.
///
/// Feature indices are cached because resolving them costs a round trip and
/// they never change while the device stays connected. A feature the device
/// does not implement is cached as a negative result so we stop asking.
public final class HIDPPTarget {
    private static let log = LoLiLog.hidpp

    public let channel: HIDPPChannel
    public let deviceIndex: UInt8

    private let cacheLock = NSLock()
    private var featureIndices: [HIDPPFeatureID: UInt8] = [:]
    private var unsupported: Set<HIDPPFeatureID> = []
    private var controlTableCache: [HIDPPControlInfo]?

    /// The device's control table, once it has been read. Fixed in firmware, so
    /// it only has to be fetched once per connection.
    var cachedControlTable: [HIDPPControlInfo]? {
        get {
            cacheLock.lock()
            defer { cacheLock.unlock() }
            return controlTableCache
        }
        set {
            cacheLock.lock()
            controlTableCache = newValue
            cacheLock.unlock()
        }
    }

    public init(channel: HIDPPChannel, deviceIndex: UInt8) {
        self.channel = channel
        self.deviceIndex = deviceIndex
    }

    public var isValid: Bool { channel.isValid }

    /// True when the channel can carry 16-byte parameter payloads. A handful of
    /// functions (`getCidInfo`, `setCidReporting`) require them.
    public var supportsLongReports: Bool { channel.reportLength == HIDPP.longReportLength }

    /// Drops every cached feature index. Call after a reconnect: a device that
    /// re-paired into a different slot can renumber its feature table.
    public func invalidateFeatureCache() {
        cacheLock.lock()
        featureIndices.removeAll()
        unsupported.removeAll()
        controlTableCache = nil
        cacheLock.unlock()
    }

    /// Round-trips the root feature to check the device is awake and reachable.
    public func ping() -> Bool {
        let marker: UInt8 = 0x5A
        let result = channel.request(
            deviceIndex: deviceIndex,
            featureIndex: 0x00,
            function: 0x01,
            parameters: [0x00, 0x00, marker],
            timeout: 0.6
        )
        guard case let .success(response) = result else { return false }
        // Byte 2 of the reply echoes the ping marker.
        return response.byte(2) == marker
    }

    /// Resolves a feature ID to its index on this device.
    public func featureIndex(_ feature: HIDPPFeatureID) -> Result<UInt8, HIDPPError> {
        if feature == .root { return .success(0x00) }

        cacheLock.lock()
        if let cached = featureIndices[feature] {
            cacheLock.unlock()
            return .success(cached)
        }
        if unsupported.contains(feature) {
            cacheLock.unlock()
            return .failure(.featureUnsupported(feature))
        }
        cacheLock.unlock()

        let result = channel.request(
            deviceIndex: deviceIndex,
            featureIndex: 0x00,
            function: 0x00,
            parameters: feature.bytes
        )

        switch result {
        case let .success(response):
            guard let index = response.byte(0), index != 0 else {
                cacheLock.lock()
                unsupported.insert(feature)
                cacheLock.unlock()
                return .failure(.featureUnsupported(feature))
            }
            cacheLock.lock()
            featureIndices[feature] = index
            cacheLock.unlock()
            return .success(index)

        case let .failure(error):
            // A device that is merely asleep must not be remembered as lacking
            // the feature — only a definitive answer is cached.
            if !error.isTransient {
                cacheLock.lock()
                unsupported.insert(feature)
                cacheLock.unlock()
            }
            return .failure(error)
        }
    }

    public func supports(_ feature: HIDPPFeatureID) -> Bool {
        if case .success = featureIndex(feature) { return true }
        return false
    }

    /// Calls a function on a feature, resolving the feature index as needed.
    @discardableResult
    public func call(
        _ feature: HIDPPFeatureID,
        function: UInt8,
        parameters: [UInt8] = [],
        timeout: TimeInterval = HIDPP.defaultTimeout
    ) -> Result<HIDPPResponse, HIDPPError> {
        switch featureIndex(feature) {
        case let .success(index):
            return channel.request(
                deviceIndex: deviceIndex,
                featureIndex: index,
                function: function,
                parameters: parameters,
                timeout: timeout
            )
        case let .failure(error):
            return .failure(error)
        }
    }

    /// The cached index for `feature`, without issuing a request.
    public func cachedFeatureIndex(_ feature: HIDPPFeatureID) -> UInt8? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return featureIndices[feature]
    }
}

extension HIDPPTarget: CustomStringConvertible {
    public var description: String {
        String(format: "%@#%02X", channel.endpoint.description, deviceIndex)
    }
}
