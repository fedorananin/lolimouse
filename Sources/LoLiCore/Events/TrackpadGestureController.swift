// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation
import HIDKit
import os.log

/// Runs the three-finger-tap action for the trackpads it is switched on for.
///
/// Main thread except where noted. The multitouch stream is opened only while
/// at least one trackpad has the setting on and the master switch is up —
/// the same rule the event tap follows.
final class TrackpadGestureController {
    private static let log = LoLiLog.events

    private let actions: ActionRunner
    private let monitor = MultitouchMonitor()

    private struct Binding {
        let action: Action
        let device: ManagedDevice
    }

    /// Guards everything below; the monitor calls back on its own thread.
    private let lock = NSLock()
    private var bindings: [UInt64: Binding] = [:]
    /// A trackpad the framework reports but the registry could not pair with
    /// a "Multitouch ID" falls back to this — the one configured trackpad, if
    /// there is exactly one. Mismatched hardware is then still usable.
    private var fallback: Binding?
    private var detectors: [UInt64: ThreeFingerTapDetector] = [:]

    init(actions: ActionRunner) {
        self.actions = actions
        monitor.onFrame = { [weak self] frame in self?.handle(frame) }
    }

    func update(devices: [ManagedDevice], configuration: Configuration) {
        var bindings: [UInt64: Binding] = [:]
        var configured: [Binding] = []
        if configuration.enabled {
            for device in devices where device.isTrackpad {
                let setting = configuration.device(device.key).trackpad.threeFingerTap
                guard setting.enabled else { continue }
                let binding = Binding(action: setting.value, device: device)
                configured.append(binding)
                if let id = device.multitouchID {
                    bindings[id] = binding
                } else {
                    os_log("%{public}@ has no Multitouch ID; will use the fallback binding",
                           log: Self.log, type: .info, device.displayName)
                }
            }
        }

        lock.lock()
        self.bindings = bindings
        fallback = configured.count == 1 ? configured[0] : nil
        lock.unlock()

        if configured.isEmpty {
            monitor.stop()
            return
        }
        // Restart when the framework's device list may have changed, e.g. an
        // external trackpad arrived; the list is a snapshot taken at start.
        let known = MultitouchMonitor.availableDeviceIDs()
        if monitor.deviceIDs != known { monitor.stop() }
        monitor.start()
    }

    func stop() {
        monitor.stop()
    }

    /// Framework thread.
    private func handle(_ frame: MultitouchMonitor.Frame) {
        lock.lock()
        let binding = bindings[frame.deviceID] ?? fallback
        var detector = detectors[frame.deviceID] ?? ThreeFingerTapDetector()
        let tapped = detector.process(fingerCount: frame.fingerCount, centroid: frame.centroid, timestamp: frame.timestamp)
        detectors[frame.deviceID] = detector
        lock.unlock()

        guard tapped, let binding else { return }
        os_log("three-finger tap on %{public}@ → %{public}@",
               log: Self.log, type: .info, binding.device.displayName, binding.action.displayName)
        DispatchQueue.main.async { [actions] in
            actions.run(binding.action, device: binding.device)
        }
    }
}
