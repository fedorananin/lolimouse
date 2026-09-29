// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation
import HIDKit
import os.log

/// Runs the finger-tap actions for the trackpads they are switched on for.
///
/// Main thread except where noted. The multitouch stream is opened only while
/// at least one trackpad has the setting on and the master switch is up —
/// the same rule the event tap follows.
final class TrackpadGestureController {
    private static let log = LoLiLog.events

    private let actions: ActionRunner
    private let monitor = MultitouchMonitor()

    /// Actions keyed by finger count, for one trackpad.
    private struct Binding {
        let actions: [Int: Action]
        /// The same, inside each application whose profile is switched on,
        /// keyed by bundle identifier. A profile that switches every tap off
        /// is present with no actions, so it still overrides `actions`.
        let applicationActions: [String: [Int: Action]]
        let device: ManagedDevice

        /// The actions for the application under the pointer. The window
        /// server is asked only when some profile exists.
        func actionsUnderPointer() -> [Int: Action] {
            guard !applicationActions.isEmpty,
                  let bundleIdentifier = ApplicationUnderPointer.shared.bundleIdentifierUnderPointer(),
                  let actions = applicationActions[bundleIdentifier]
            else { return actions }
            return actions
        }

        var isEmpty: Bool {
            actions.isEmpty && applicationActions.values.allSatisfy(\.isEmpty)
        }

        static func actions(for settings: TrackpadSettings) -> [Int: Action] {
            var actions: [Int: Action] = [:]
            for fingers in TrackpadSettings.offeredFingerCounts {
                if let setting = settings.tap(fingers: fingers), setting.enabled {
                    actions[fingers] = setting.value
                }
            }
            return actions
        }
    }

    /// Guards everything below; the monitor calls back on its own thread.
    private let lock = NSLock()
    private var bindings: [UInt64: Binding] = [:]
    /// A trackpad the framework reports but the registry could not pair with
    /// a "Multitouch ID" falls back to this — the one configured trackpad, if
    /// there is exactly one. Mismatched hardware is then still usable.
    private var fallback: Binding?
    /// One detector per finger count per trackpad; they watch the same frames
    /// and only one of them can fire for a given episode.
    private var detectors: [UInt64: [FingerTapDetector]] = [:]

    init(actions: ActionRunner) {
        self.actions = actions
        monitor.onFrame = { [weak self] frame in self?.handle(frame) }
    }

    func update(devices: [ManagedDevice], configuration: Configuration) {
        var bindings: [UInt64: Binding] = [:]
        var configured: [Binding] = []
        if configuration.enabled {
            for device in devices where device.isTrackpad {
                let deviceConfiguration = configuration.device(device.key)
                let binding = Binding(
                    actions: Binding.actions(for: deviceConfiguration.trackpad),
                    applicationActions: deviceConfiguration.applicationConfigurations
                        .mapValues { Binding.actions(for: $0.trackpad) },
                    device: device
                )
                guard !binding.isEmpty else { continue }
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
        var detectors = self.detectors[frame.deviceID]
            ?? TrackpadSettings.offeredFingerCounts.map { FingerTapDetector(fingers: $0) }
        var tapped: Int?
        for index in detectors.indices {
            if detectors[index].process(fingerCount: frame.fingerCount, centroid: frame.centroid, timestamp: frame.timestamp) {
                tapped = detectors[index].fingers
            }
        }
        self.detectors[frame.deviceID] = detectors
        lock.unlock()

        guard let tapped, let binding, let action = binding.actionsUnderPointer()[tapped] else { return }
        os_log("%{public}d-finger tap on %{public}@ → %{public}@",
               log: Self.log, type: .info, tapped, binding.device.displayName, action.displayName)
        DispatchQueue.main.async { [actions] in
            actions.run(action, device: binding.device)
        }
    }
}
