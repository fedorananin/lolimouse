// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation
import IOKitSPI
import os.log

/// Streams finger counts from every multitouch trackpad through the private
/// MultitouchSupport framework.
///
/// Why private: macOS offers no public way to learn how many fingers rest on
/// a trackpad from outside the focused app. See the note in IOKitSPI.h.
///
/// Safety: `MTDeviceStart` talks to the trackpad driver through its own user
/// client. It never goes through `IOHIDDeviceOpen`, so the rules about not
/// opening HID devices are untouched — but the same discipline applies: the
/// stream runs only while a trackpad setting needs it, and `stop()` puts
/// everything back.
public final class MultitouchMonitor {
    private static let log = LoLiLog.hid

    /// A reduced frame: what the tap detector needs and nothing else.
    public struct Frame: Sendable {
        public let deviceID: UInt64
        public let fingerCount: Int
        /// Mean position of the fingers in 0…1 surface units, or `nil` when
        /// none are down.
        public let centroid: (x: Double, y: Double)?
        public let timestamp: TimeInterval
    }

    /// Called on the framework's own thread. Keep it short.
    public var onFrame: ((Frame) -> Void)?

    private var devices: [(id: UInt64, ref: UnsafeMutableRawPointer, object: AnyObject)] = []
    private var isRunning = false

    public init() {}

    deinit { stop() }

    /// IDs of every trackpad the framework knows, running or not. Empty when
    /// the framework could not be loaded.
    public static func availableDeviceIDs() -> Set<UInt64> {
        guard let api = Library.shared else { return [] }
        return Set(api.deviceList().map(\.id))
    }

    public var deviceIDs: Set<UInt64> { Set(devices.map(\.id)) }

    /// Starts streaming from every trackpad. Main thread.
    public func start() {
        guard !isRunning else { return }
        guard let api = Library.shared else {
            os_log("MultitouchSupport unavailable; trackpad gestures off", log: Self.log, type: .error)
            return
        }
        devices = api.deviceList()
        Self.registerActive(self)
        for device in devices {
            api.registerCallback(device.ref, Self.frameCallback)
            api.start(device.ref, 0)
            os_log("multitouch stream started on 0x%llX", log: Self.log, type: .info, device.id)
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning, let api = Library.shared else { return }
        for device in devices {
            api.stop(device.ref)
            api.unregisterCallback(device.ref, Self.frameCallback)
            os_log("multitouch stream stopped on 0x%llX", log: Self.log, type: .info, device.id)
        }
        devices.removeAll()
        Self.unregisterActive(self)
        isRunning = false
    }

    // MARK: - C callback plumbing

    /// The framework takes a bare C function pointer, so the instance has to
    /// be found from a static. There is one monitor per process.
    private static let activeLock = NSLock()
    private static weak var active: MultitouchMonitor?

    private static func registerActive(_ monitor: MultitouchMonitor) {
        activeLock.lock(); active = monitor; activeLock.unlock()
    }

    private static func unregisterActive(_ monitor: MultitouchMonitor) {
        activeLock.lock()
        if active === monitor { active = nil }
        activeLock.unlock()
    }

    private static let frameCallback: LoLiMTContactFrameCallback = { device, touches, count, timestamp, _ in
        activeLock.lock()
        let monitor = active
        activeLock.unlock()
        guard let monitor else { return 0 }
        monitor.deliver(device: device, touches: touches, count: Int(count), timestamp: timestamp)
        return 0
    }

    private func deliver(device: UnsafeMutableRawPointer, touches: UnsafeMutablePointer<LoLiMTTouch>?, count: Int, timestamp: Double) {
        guard let entry = devices.first(where: { $0.ref == device }) else { return }
        var centroid: (x: Double, y: Double)?
        if count > 0, let touches {
            var sx = 0.0, sy = 0.0
            for index in 0..<count {
                sx += Double(touches[index].normalized.position.x)
                sy += Double(touches[index].normalized.position.y)
            }
            centroid = (sx / Double(count), sy / Double(count))
        }
        onFrame?(Frame(deviceID: entry.id, fingerCount: count, centroid: centroid, timestamp: timestamp))
    }

    // MARK: - dlsym bindings

    private final class Library {
        static let shared = Library()

        typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
        typealias GetDeviceID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
        typealias RegisterCallback = @convention(c) (UnsafeMutableRawPointer, LoLiMTContactFrameCallback) -> Void
        typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
        typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void

        private let createList: CreateList
        private let getDeviceID: GetDeviceID
        let registerCallback: RegisterCallback
        let unregisterCallback: RegisterCallback
        let start: Start
        let stop: Stop

        private init?() {
            let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
            guard let handle = dlopen(path, RTLD_NOW) else {
                os_log("dlopen MultitouchSupport failed", log: MultitouchMonitor.log, type: .error)
                return nil
            }
            func symbol<T>(_ name: String, _: T.Type) -> T? {
                guard let pointer = dlsym(handle, name) else {
                    os_log("MultitouchSupport lacks %{public}@", log: MultitouchMonitor.log, type: .error, name)
                    return nil
                }
                return unsafeBitCast(pointer, to: T.self)
            }
            guard let createList = symbol("MTDeviceCreateList", CreateList.self),
                  let getDeviceID = symbol("MTDeviceGetDeviceID", GetDeviceID.self),
                  let register = symbol("MTRegisterContactFrameCallback", RegisterCallback.self),
                  let unregister = symbol("MTUnregisterContactFrameCallback", RegisterCallback.self),
                  let start = symbol("MTDeviceStart", Start.self),
                  let stop = symbol("MTDeviceStop", Stop.self)
            else { return nil }
            self.createList = createList
            self.getDeviceID = getDeviceID
            registerCallback = register
            unregisterCallback = unregister
            self.start = start
            self.stop = stop
        }

        /// The framework's current device list. The objects are kept alive by
        /// the caller holding them; the raw pointer is what the C API wants.
        func deviceList() -> [(id: UInt64, ref: UnsafeMutableRawPointer, object: AnyObject)] {
            guard let list = createList()?.takeRetainedValue() as? [AnyObject] else { return [] }
            return list.compactMap { object in
                let ref = Unmanaged.passUnretained(object).toOpaque()
                var id: UInt64 = 0
                guard getDeviceID(ref, &id) == 0 else { return nil }
                return (id, ref, object)
            }
        }
    }
}
