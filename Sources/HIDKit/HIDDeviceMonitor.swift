// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation
import IOKit.hid
import os.log

/// Watches the HID device tree and reports arrivals and removals.
///
/// This is the single source of truth for "what is plugged in right now".
/// Everything else in the app — the pointer devices we tune, the HID++
/// endpoints we talk to — is derived from the set this publishes.
public final class HIDDeviceMonitor {
    private static let log = LoLiLog.hid

    /// USB vendor ID shared by every Logitech device.
    public static let logitechVendorID = 0x046D

    public struct Callbacks {
        public var added: (HIDDevice) -> Void
        public var removed: (HIDDevice) -> Void

        public init(added: @escaping (HIDDevice) -> Void, removed: @escaping (HIDDevice) -> Void) {
            self.added = added
            self.removed = removed
        }
    }

    private let manager: IOHIDManager
    private let queue = DispatchQueue(label: "\(LoLiLog.subsystem).hid-monitor", qos: .userInitiated)
    private let lock = NSLock()
    private var devicesByRef: [IOHIDDevice: HIDDevice] = [:]
    private var callbacks: Callbacks?
    private var running = false

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit { stop() }

    /// Every device currently known, newest snapshot.
    public var devices: [HIDDevice] {
        lock.lock()
        defer { lock.unlock() }
        return Array(devicesByRef.values)
    }

    public func start(_ callbacks: Callbacks) {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        self.callbacks = callbacks
        lock.unlock()

        // Match Logitech devices only.
        //
        // Two rules govern this whole file, both learned the hard way:
        //
        //   1. Never match a device we have no intention of talking to. A
        //      generic mouse or trackpad needs no HID access at all — its
        //      settings go through IOHIDServiceClient, which opens nothing.
        //   2. Never call IOHIDManagerOpen. It opens *every matched device*,
        //      and a device this process holds open when it dies can stay
        //      seized by the kernel until the machine is restarted. Losing the
        //      built-in keyboard and trackpad that way is not a recoverable
        //      situation for the person sitting in front of it.
        //
        // Matching callbacks are delivered by Activate alone; the open is
        // unnecessary, and individual HID++ endpoints are opened one at a time
        // by HIDDevice.open() with its own usage-page guard.
        let matching: [[String: Any]] = [
            [kIOHIDVendorIDKey: Self.logitechVendorID],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.matchedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.removedCallback, context)
        IOHIDManagerSetDispatchQueue(manager, queue)
        IOHIDManagerActivate(manager)
    }

    public func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        let known = Array(devicesByRef.values)
        devicesByRef.removeAll()
        callbacks = nil
        lock.unlock()

        // Close every endpoint we opened before tearing the manager down, so
        // nothing is left seized if this process is about to exit.
        for device in known {
            device.invalidate()
        }

        // Only Cancel. Re-registering callbacks on an activated manager traps
        // with EXC_BREAKPOINT, and Close would be wrong because Open was never
        // called.
        IOHIDManagerCancel(manager)
    }

    private static let matchedCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<HIDDeviceMonitor>.fromOpaque(context).takeUnretainedValue().handleMatched(device)
    }

    private static let removedCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<HIDDeviceMonitor>.fromOpaque(context).takeUnretainedValue().handleRemoved(device)
    }

    private func handleMatched(_ ref: IOHIDDevice) {
        lock.lock()
        guard running, devicesByRef[ref] == nil else {
            lock.unlock()
            return
        }
        let device = HIDDevice(ref)
        devicesByRef[ref] = device
        let callback = callbacks?.added
        lock.unlock()

        os_log("HID device added: %{public}@", log: Self.log, type: .info, device.description)
        callback?(device)
    }

    private func handleRemoved(_ ref: IOHIDDevice) {
        lock.lock()
        guard let device = devicesByRef.removeValue(forKey: ref) else {
            lock.unlock()
            return
        }
        let callback = callbacks?.removed
        lock.unlock()

        os_log("HID device removed: %{public}@", log: Self.log, type: .info, device.description)
        device.invalidate()
        callback?(device)
    }
}
