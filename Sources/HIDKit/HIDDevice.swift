// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation
import IOKit.hid
import os.log

/// Common `Transport` property values reported by IOKit.
public enum HIDTransport {
    public static let usb = "USB"
    public static let bluetooth = "Bluetooth"
    public static let bluetoothLowEnergy = "Bluetooth Low Energy"
    public static let spi = "SPI"
}

/// A thin, thread-safe wrapper around one `IOHIDDevice`.
///
/// The device is scheduled on its own serial dispatch queue (never a run loop),
/// so a synchronous report transaction can simply block the calling thread on a
/// semaphore while the reply arrives on the device queue. Callers must not
/// invoke `transact` from the device queue itself.
public final class HIDDevice {
    private static let log = LoLiLog.hid

    public let device: IOHIDDevice

    // Snapshot of the immutable IOKit properties, read once at construction so
    // they stay available even after the device goes away.
    public let vendorID: Int?
    public let productID: Int?
    public let product: String?
    public let serialNumber: String?
    public let transport: String?
    public let locationID: Int?
    public let primaryUsagePage: Int?
    public let primaryUsage: Int?
    public let maxInputReportSize: Int?
    public let maxOutputReportSize: Int?
    public let maxFeatureReportSize: Int?
    public let registryEntryID: UInt64?

    private let queue: DispatchQueue

    private let stateLock = NSLock()
    /// Our own reference to the device, created in `open()`. The one handed to
    /// us by IOHIDManager must never be scheduled or activated by us.
    private var ownedDevice: IOHIDDevice?
    private var opened = false
    private var activated = false
    private var invalidated = false

    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var reportBufferLength = 0

    /// Guards `pending`; signalled from the device queue.
    private let pendingLock = NSLock()
    private var pending: PendingTransaction?

    /// Serialises whole transactions so two callers cannot interleave a request
    /// and steal each other's reply.
    private let transactionLock = NSLock()

    private let observerLock = NSLock()
    private var observers: [UUID: (Data) -> Void] = [:]

    /// One in-flight request. `response` is filled in on the device queue and
    /// consumed by the waiting caller, which is also the only place that clears
    /// `pending` — so a second matching report cannot overwrite the first.
    private final class PendingTransaction {
        let matches: (Data) -> Bool
        let semaphore: DispatchSemaphore
        var response: Data?

        init(matches: @escaping (Data) -> Bool, semaphore: DispatchSemaphore) {
            self.matches = matches
            self.semaphore = semaphore
        }
    }

    public init(_ device: IOHIDDevice) {
        self.device = device
        vendorID = HIDDevice.property(device, kIOHIDVendorIDKey)
        productID = HIDDevice.property(device, kIOHIDProductIDKey)
        product = HIDDevice.property(device, kIOHIDProductKey)
        serialNumber = HIDDevice.property(device, kIOHIDSerialNumberKey)
        transport = HIDDevice.property(device, kIOHIDTransportKey)
        locationID = HIDDevice.property(device, kIOHIDLocationIDKey)
        primaryUsagePage = HIDDevice.property(device, kIOHIDPrimaryUsagePageKey)
        primaryUsage = HIDDevice.property(device, kIOHIDPrimaryUsageKey)
        maxInputReportSize = HIDDevice.property(device, kIOHIDMaxInputReportSizeKey)
        maxOutputReportSize = HIDDevice.property(device, kIOHIDMaxOutputReportSizeKey)
        maxFeatureReportSize = HIDDevice.property(device, kIOHIDMaxFeatureReportSizeKey)
        registryEntryID = HIDDevice.readRegistryEntryID(device)

        let label = String(format: "%@.hid.%04X-%04X",
                           LoLiLog.subsystem,
                           vendorID ?? 0,
                           productID ?? 0)
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    deinit {
        invalidate()
        reportBuffer?.deallocate()
    }

    private static func property<T>(_ device: IOHIDDevice, _ key: String) -> T? {
        IOHIDDeviceGetProperty(device, key as CFString) as? T
    }

    private static func readRegistryEntryID(_ device: IOHIDDevice) -> UInt64? {
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return nil }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { return nil }
        return id
    }

    // MARK: - Lifecycle

    /// Every top-level collection this device exposes, as usage page / usage
    /// pairs.
    ///
    /// The primary usage alone is not enough to recognise a HID++ endpoint. A
    /// Logitech mouse on Bluetooth arrives as a single HID device whose primary
    /// usage is Mouse, with the vendor-defined HID++ collection listed here
    /// alongside it. Looking only at the primary usage misses it entirely.
    public var usagePairs: [(page: Int, usage: Int)] {
        guard let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString)
            as? [[String: Int]]
        else {
            return []
        }
        return pairs.compactMap { pair in
            guard let page = pair[kIOHIDDeviceUsagePageKey], let usage = pair[kIOHIDDeviceUsageKey] else {
                return nil
            }
            return (page: page, usage: usage)
        }
    }

    /// Whether the device exposes a vendor-defined collection — the private
    /// channel Logitech uses for HID++. Usage pages from `0xFF00` up are
    /// reserved for vendors; Logitech's mice use `0xFF43`.
    public var hasVendorDefinedCollection: Bool {
        if let primary = primaryUsagePage, primary >= 0xFF00 { return true }
        return usagePairs.contains { $0.page >= 0xFF00 }
    }

    /// Whether this device is safe for LoLiMouse to open.
    ///
    /// Two conditions, both required: it must be a Logitech device, and it must
    /// expose a vendor-defined collection. Anything else — keyboards,
    /// trackpads, ordinary mice — is refused, because we have no reason to open
    /// them and a device left open by a process that then dies can stay seized
    /// by the kernel until the machine restarts. When that device is the
    /// built-in keyboard and trackpad, the person in front of the machine has
    /// no way to recover short of a hard restart.
    ///
    /// This is the last line of defence, below the manager's matching rules.
    public var isOpenable: Bool {
        vendorID == 0x046D && hasVendorDefinedCollection
    }

    /// Opens the device and starts delivering input reports.
    ///
    /// Returns `false` when the device is not one we are allowed to open, or
    /// when macOS refuses — almost always a missing Input Monitoring grant,
    /// reported as `kIOReturnNotPermitted`.
    @discardableResult
    public func open() -> Bool {
        guard isOpenable else {
            os_log("refusing to open %{public}@ — not a vendor-defined HID++ collection",
                   log: Self.log, type: .error, description)
            return false
        }

        stateLock.lock()
        defer { stateLock.unlock() }

        if invalidated { return false }
        if opened { return true }

        // The reference handed over by IOHIDManager already belongs to the
        // manager: it has been scheduled and activated, and registering our own
        // input-report callback on it trips an IOKit assertion reading "Device
        // has already been activated/cancelled". Build an independent reference
        // from the same IOService and drive that instead.
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL,
              let owned = IOHIDDeviceCreate(kCFAllocatorDefault, service)
        else {
            os_log("could not create an owned reference for %{public}@",
                   log: Self.log, type: .error, description)
            return false
        }

        let result = IOHIDDeviceOpen(owned, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            os_log("IOHIDDeviceOpen failed for %{public}@: 0x%{public}X",
                   log: Self.log, type: .error, description, result)
            return false
        }

        let length = max(maxInputReportSize ?? 0, 64)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        buffer.initialize(repeating: 0, count: length)
        reportBuffer?.deallocate()
        reportBuffer = buffer
        reportBufferLength = length

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(owned, buffer, length, Self.inputReportCallback, context)
        IOHIDDeviceSetDispatchQueue(owned, queue)
        // With the dispatch-queue API the close belongs in the cancel handler.
        // Calling IOHIDDeviceClose directly after IOHIDDeviceCancel asserts, in
        // the same family as "Device has already been activated/cancelled".
        IOHIDDeviceSetCancelHandler(owned) {
            IOHIDDeviceClose(owned, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        IOHIDDeviceActivate(owned)

        ownedDevice = owned
        opened = true
        activated = true

        return true
    }

    /// Cancels the dispatch source and closes the device. Idempotent.
    public func invalidate() {
        stateLock.lock()
        let wasActivated = activated
        let wasOpened = opened
        activated = false
        opened = false
        invalidated = true
        stateLock.unlock()

        // Fail any in-flight transaction so the caller is not stuck until timeout.
        pendingLock.lock()
        let semaphore = pending?.semaphore
        pending = nil
        pendingLock.unlock()
        semaphore?.signal()

        stateLock.lock()
        let owned = ownedDevice
        ownedDevice = nil
        stateLock.unlock()

        guard let owned else { return }
        if wasActivated {
            // The cancel handler installed in `open()` performs the close.
            IOHIDDeviceCancel(owned)
        } else if wasOpened {
            IOHIDDeviceClose(owned, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    public var isValid: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !invalidated
    }

    // MARK: - Input reports

    private static let inputReportCallback: IOHIDReportCallback = { context, _, _, _, _, report, length in
        guard let context, length > 0 else { return }
        let this = Unmanaged<HIDDevice>.fromOpaque(context).takeUnretainedValue()
        this.handleInputReport(Data(bytes: report, count: length))
    }

    private func handleInputReport(_ report: Data) {
        pendingLock.lock()
        var toSignal: DispatchSemaphore?
        if let current = pending, current.response == nil, current.matches(report) {
            current.response = report
            toSignal = current.semaphore
        }
        pendingLock.unlock()
        toSignal?.signal()

        observerLock.lock()
        let callbacks = Array(observers.values)
        observerLock.unlock()
        for callback in callbacks {
            callback(report)
        }
    }

    /// Observes every input report. The closure runs on the device queue and
    /// must return quickly.
    public func observeInputReports(_ closure: @escaping (Data) -> Void) -> HIDObservation {
        let id = UUID()
        observerLock.lock()
        observers[id] = closure
        observerLock.unlock()

        return HIDObservation { [weak self] in
            guard let self else { return }
            observerLock.lock()
            observers.removeValue(forKey: id)
            observerLock.unlock()
        }
    }

    // MARK: - Transactions

    /// Sends an output report and waits for the first input report accepted by
    /// `matching`, or `nil` on timeout.
    ///
    /// Must not be called from the device's own dispatch queue.
    public func transact(
        output report: Data,
        timeout: TimeInterval,
        matching: @escaping (Data) -> Bool
    ) -> Data? {
        guard !report.isEmpty, isValid else { return nil }

        transactionLock.lock()
        defer { transactionLock.unlock() }

        guard open() else { return nil }

        stateLock.lock()
        let target = ownedDevice
        stateLock.unlock()
        guard let target else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        pendingLock.lock()
        pending = PendingTransaction(matches: matching, semaphore: semaphore)
        pendingLock.unlock()

        let sendResult: IOReturn = report.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(
                target,
                kIOHIDReportTypeOutput,
                CFIndex(report[report.startIndex]),
                base,
                report.count
            )
        }

        guard sendResult == kIOReturnSuccess else {
            pendingLock.lock()
            pending = nil
            pendingLock.unlock()
            return nil
        }

        _ = semaphore.wait(timeout: .now() + timeout)

        pendingLock.lock()
        let response = pending?.response
        pending = nil
        pendingLock.unlock()

        return response
    }
}

extension HIDDevice: CustomStringConvertible {
    public var description: String {
        String(
            format: "%@ (VID=0x%04X PID=0x%04X %@)",
            product ?? "(unknown)",
            vendorID ?? 0,
            productID ?? 0,
            transport ?? "-"
        )
    }
}

extension HIDDevice: Equatable, Hashable {
    public static func == (lhs: HIDDevice, rhs: HIDDevice) -> Bool { lhs.device == rhs.device }
    public func hash(into hasher: inout Hasher) { hasher.combine(device) }
}

/// Cancels an observation when released, or explicitly via `cancel()`.
public final class HIDObservation {
    private var onCancel: (() -> Void)?
    private let lock = NSLock()

    init(_ onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    deinit { cancel() }

    public func cancel() {
        lock.lock()
        let block = onCancel
        onCancel = nil
        lock.unlock()
        block?()
    }
}
