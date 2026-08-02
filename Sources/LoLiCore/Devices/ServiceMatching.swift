// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation

/// Decides which pointer services belong to which HID++ device.
///
/// Kept free of IOKit types so the logic is testable: getting this wrong is
/// invisible in code review but very visible to the user — an unclaimed
/// service resurfaces as a phantom second copy of the same mouse, and scroll
/// events routed to the phantom silently ignore the settings made on the real
/// entry.
public enum ServiceMatching {
    /// The identifying properties matching runs on, shared by HID devices and
    /// pointer services alike.
    public struct Identity: Equatable {
        public var vendorID: Int?
        public var productID: Int?
        public var locationID: Int?
        public var product: String?

        public init(
            vendorID: Int? = nil,
            productID: Int? = nil,
            locationID: Int? = nil,
            product: String? = nil
        ) {
            self.vendorID = vendorID
            self.productID = productID
            self.locationID = locationID
            self.product = product
        }
    }

    /// Indices into `services` of the ones that belong to `endpoint`.
    ///
    /// Tries a strict match first — vendor, product and location all agree —
    /// because the location ID is what tells two identical receivers apart.
    /// Over Bluetooth, though, macOS splits a mouse's collections into separate
    /// registry entries whose location IDs do not always agree, so when the
    /// strict pass claims nothing the location requirement is dropped rather
    /// than letting the service fall through and become a phantom device.
    public static func indicesMatching(endpoint: Identity, services: [Identity]) -> [Int] {
        let strict = services.indices.filter { index in
            let service = services[index]
            return service.vendorID == endpoint.vendorID
                && service.productID == endpoint.productID
                && (service.locationID == nil || endpoint.locationID == nil
                    || service.locationID == endpoint.locationID)
        }
        if !strict.isEmpty { return strict }

        return services.indices.filter { index in
            let service = services[index]
            return service.vendorID == endpoint.vendorID
                && service.productID == endpoint.productID
        }
    }

    /// Whether a service left unclaimed by every endpoint is actually a known
    /// HID++ device reached over another transport.
    ///
    /// A Bluetooth connection reports the mouse's own product string, so a
    /// leftover service from the right vendor carrying the same marketing name
    /// as a discovered device is that device — not a new one.
    public static func service(
        _ service: Identity,
        belongsToDeviceNamed name: String,
        vendorID: Int
    ) -> Bool {
        guard service.vendorID == vendorID, let product = service.product else { return false }
        return product.caseInsensitiveCompare(name) == .orderedSame
    }
}
