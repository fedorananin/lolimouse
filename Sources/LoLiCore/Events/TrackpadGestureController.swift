// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation
import HIDKit
import os.log

/// Decides, once per touch, when to look for Mission Control, and remembers
/// what was found until the hand lifts.
///
/// The look has to happen as the fingers land, not when the swipe is
/// recognised. macOS answers a swipe sooner than `FingerSwipeDetector` does —
/// it needs less travel — so by the time a swipe that dismisses Mission
/// Control has gone far enough for us, the overview may already be off the
/// screen, and the swipe would be taken for an ordinary one. Seen on
/// hardware: the window in front was minimised by the very swipe that closed
/// the overview.
public struct OverviewWatch: Sendable {
    /// The fewest fingers that can swipe. Fewer never trigger a look, so
    /// pointing and two-finger scrolling cost nothing.
    public let fingers: Int
    /// Whether the overview was up at some point during this touch.
    public private(set) var overviewSeen = false
    private var looked = false

    public init(fingers: Int) {
        self.fingers = fingers
    }

    /// Feeds one frame's finger count. Returns `true` on the one frame per
    /// touch on which to look: the first with enough fingers down.
    public mutating func shouldLook(fingerCount: Int) -> Bool {
        if fingerCount == 0 {
            looked = false
            overviewSeen = false
            return false
        }
        guard !looked, fingerCount >= fingers else { return false }
        looked = true
        return true
    }

    public mutating func sawOverview() {
        overviewSeen = true
    }
}

/// Runs the finger-tap and finger-swipe actions for the trackpads they are
/// switched on for.
///
/// Main thread except where noted. The multitouch stream is opened only while
/// at least one trackpad has the setting on and the master switch is up —
/// the same rule the event tap follows.
final class TrackpadGestureController {
    private static let log = LoLiLog.events

    private let actions: ActionRunner
    private let monitor = MultitouchMonitor()

    /// Actions keyed by gesture, for one trackpad.
    private struct Binding {
        let actions: [TrackpadGesture: Action]
        /// The same, inside each application whose profile is switched on,
        /// keyed by bundle identifier. A profile that switches every gesture
        /// off is present with no actions, so it still overrides `actions`.
        let applicationActions: [String: [TrackpadGesture: Action]]
        let device: ManagedDevice

        /// The actions for the application under the pointer. The window
        /// server is asked only when some profile exists.
        func actionsUnderPointer() -> [TrackpadGesture: Action] {
            guard !applicationActions.isEmpty,
                  let bundleIdentifier = ApplicationUnderPointer.shared.bundleIdentifierUnderPointer(),
                  let actions = applicationActions[bundleIdentifier]
            else { return actions }
            return actions
        }

        var isEmpty: Bool {
            actions.isEmpty && applicationActions.values.allSatisfy(\.isEmpty)
        }

        /// Whether any swipe is bound, here or in an application profile.
        /// Without one there is no reason to ask about Mission Control.
        var hasSwipes: Bool {
            ([actions] + applicationActions.values).contains { actions in
                actions.keys.contains { gesture in
                    if case .swipe = gesture { return true }
                    return false
                }
            }
        }
    }

    /// The detectors for one trackpad. They watch the same frames; a tap
    /// needs still fingers and a swipe moving ones, so at most one of them
    /// fires for a given episode.
    private struct Detectors {
        var taps = TrackpadSettings.offeredFingerCounts.map { FingerTapDetector(fingers: $0) }
        var swipes = FingerSwipeDetector(fingerCounts: Set(TrackpadSettings.offeredFingerCounts))
        var overview = OverviewWatch(fingers: TrackpadSettings.offeredFingerCounts.min() ?? 3)

        mutating func process(_ frame: MultitouchMonitor.Frame) -> TrackpadGesture? {
            var gesture: TrackpadGesture?
            for index in taps.indices {
                if taps[index].process(fingerCount: frame.fingerCount, centroid: frame.centroid, timestamp: frame.timestamp) {
                    gesture = .tap(fingers: taps[index].fingers)
                }
            }
            let contacts = frame.touches.map { FingerSwipeDetector.Contact(id: $0.id, x: $0.x, y: $0.y) }
            if let swipe = swipes.process(contacts: contacts, timestamp: frame.timestamp) {
                gesture = .swipe(fingers: swipe.fingers, direction: swipe.direction)
            }
            return gesture
        }
    }

    /// Guards everything below; the monitor calls back on its own thread.
    private let lock = NSLock()
    private var bindings: [UInt64: Binding] = [:]
    /// A trackpad the framework reports but the registry could not pair with
    /// a "Multitouch ID" falls back to this — the one configured trackpad, if
    /// there is exactly one. Mismatched hardware is then still usable.
    private var fallback: Binding?
    private var detectors: [UInt64: Detectors] = [:]

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
                    actions: deviceConfiguration.trackpad.actions,
                    applicationActions: deviceConfiguration.applicationConfigurations
                        .mapValues(\.trackpad.actions),
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
        let gesture = detectors[frame.deviceID, default: Detectors()].process(frame)
        let fingersLanded = detectors[frame.deviceID]?.overview.shouldLook(fingerCount: frame.fingerCount) ?? false
        var overviewSeen = detectors[frame.deviceID]?.overview.overviewSeen ?? false
        lock.unlock()

        // In Mission Control and App Exposé a swipe is how the overview is
        // dismissed. macOS acts on it whatever we do, so we must not as well:
        // swiping the overview away would otherwise also minimise the window
        // that was in front before it opened. See `OverviewWatch` for why
        // the question is asked as the fingers land. It is a round trip to
        // the window server, so it is made outside the lock, and only on a
        // trackpad that has a swipe to protect.
        if fingersLanded, binding?.hasSwipes == true, ApplicationUnderPointer.shared.isWindowOverviewShowing() {
            lock.lock()
            detectors[frame.deviceID]?.overview.sawOverview()
            lock.unlock()
            overviewSeen = true
            os_log("fingers down in Mission Control; swipes in this touch are left to it",
                   log: Self.log, type: .info)
        }

        guard let gesture, let binding, let action = binding.actionsUnderPointer()[gesture] else { return }
        // Looking again here covers an overview that opened after the fingers
        // landed.
        if case .swipe = gesture, overviewSeen || ApplicationUnderPointer.shared.isWindowOverviewShowing() {
            os_log("%{public}@ on %{public}@ left to Mission Control",
                   log: Self.log, type: .info, gesture.displayName, binding.device.displayName)
            return
        }
        os_log("%{public}@ on %{public}@ → %{public}@",
               log: Self.log, type: .info, gesture.displayName, binding.device.displayName, action.displayName)
        DispatchQueue.main.async { [actions] in
            actions.run(action, device: binding.device)
        }
    }
}
