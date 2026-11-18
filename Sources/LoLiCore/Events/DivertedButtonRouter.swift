// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation
import HIDKit
import HIDPP
import os.log

/// Handles the buttons macOS never sees.
///
/// The wheel-mode button and the thumb button do not produce ordinary HID mouse
/// events — the firmware handles them internally. Once `HardwareReconciler` has
/// diverted them, they arrive here as HID++ notifications instead, and this is
/// where they become actions.
///
/// The thumb button also streams pointer movement while held, which is what
/// makes flick gestures possible: hold, move, release, and the direction
/// decides what runs. On an MX Master 4 there are two such controls — the
/// haptic panel under the thumb and the gesture button on the side — and each
/// runs its own settings.
public final class DivertedButtonRouter {
    private static let log = LoLiLog.events

    private let actions: ActionRunner
    private let stateLock = NSLock()
    private var states: [String: DeviceState] = [:]
    private var attachments = AttachmentTable<HIDObservation>()

    /// Supplies the current configuration for a device.
    public var configurationProvider: ((String) -> DeviceConfiguration)?

    public init(actions: ActionRunner) {
        self.actions = actions
    }

    private final class DeviceState {
        var pressed: Set<HIDPPControlID> = []
        var gestureAccumulatorX: Double = 0
        var gestureAccumulatorY: Double = 0
        /// The gesture source being held, whose release resolves the flick.
        /// Raw XY does not say which control it belongs to, so only one
        /// source gestures at a time: the first one pressed.
        var heldGestureSource: HIDPPControlID?
        /// The first raw-XY sample after contact is a jump to wherever the
        /// thumb landed on the haptic panel, not movement. OpenLogi drops it
        /// for every gesture source; one sample of the gesture button is
        /// worth nothing either way.
        var discardNextRawXY = false
    }

    /// Starts listening to `device`. Safe to call repeatedly; a device already
    /// being watched *on this same object* is left alone.
    ///
    /// The qualifier is the whole point. A rescan replaces every
    /// `ManagedDevice` with a fresh object carrying the same key, and the
    /// closure below holds its device weakly — so a subscription made for the
    /// previous object stops resolving the moment the registry drops it, and
    /// every diverted press is dropped on the `guard`. Matching on object
    /// identity makes the rescan re-subscribe instead of walking away.
    public func attach(_ device: ManagedDevice) {
        guard let target = device.target else { return }
        let identity = ObjectIdentifier(device)

        stateLock.lock()
        let alreadyAttached = attachments.holds(key: device.key, device: identity)
        stateLock.unlock()
        guard !alreadyAttached else { return }

        // Registering a second observer costs nothing at the HID layer — the
        // endpoint multiplexes them and is already open — so the replaced
        // subscription can be cancelled after this one is in place.
        let observation = target.channel.observeNotifications { [weak self, weak device] response in
            guard let self, let device else { return }
            guard let event = target.decodeControlEvent(response) else { return }
            handle(event, device: device)
        }

        stateLock.lock()
        let replaced = attachments.insert(key: device.key, device: identity, observation: observation)
        // Which buttons were down is a property of the object we were watching;
        // starting again on a new one means starting from nothing held.
        states[device.key] = DeviceState()
        stateLock.unlock()
        replaced?.cancel()

        os_log("%{public}@ for diverted buttons on %{public}@",
               log: Self.log, type: .info,
               replaced == nil ? "listening" : "listening again", device.displayName)
    }

    public func detach(_ key: String) {
        stateLock.lock()
        let observation = attachments.remove(key: key)
        states.removeValue(forKey: key)
        stateLock.unlock()
        observation?.cancel()
    }

    public func detachAll() {
        stateLock.lock()
        let observations = attachments.removeAll()
        states.removeAll()
        stateLock.unlock()
        for observation in observations { observation.cancel() }
    }

    /// Keeps only the devices still present.
    public func retain(_ devices: [ManagedDevice]) {
        let keep = Set(devices.map(\.key))
        stateLock.lock()
        let stale = attachments.removeAll(except: keep)
        for key in states.keys.filter({ !keep.contains($0) }) { states.removeValue(forKey: key) }
        stateLock.unlock()
        for observation in stale { observation.cancel() }
    }

    // MARK: - Event handling

    private func handle(_ event: HIDPPControlEvent, device: ManagedDevice) {
        guard let configuration = configurationProvider?(device.key) else { return }

        stateLock.lock()
        let state = states[device.key] ?? DeviceState()
        states[device.key] = state
        stateLock.unlock()

        switch event {
        case let .buttonsPressed(current):
            handleButtons(current, state: state, device: device, configuration: configuration)
        case let .rawXY(dx, dy):
            guard state.heldGestureSource != nil else { return }
            if state.discardNextRawXY {
                state.discardNextRawXY = false
                return
            }
            state.gestureAccumulatorX += Double(dx)
            state.gestureAccumulatorY += Double(dy)
        }
    }

    private func handleButtons(
        _ current: Set<HIDPPControlID>,
        state: DeviceState,
        device: ManagedDevice,
        configuration: DeviceConfiguration
    ) {
        let previous = state.pressed
        state.pressed = current

        let newlyPressed = current.subtracting(previous)
        let released = previous.subtracting(current)

        for control in newlyPressed {
            if control == HIDPPControl.wheelModeButton {
                if let action = configuration.buttons.wheelModeButton.effective {
                    _ = actions.run(action, device: device)
                }
                continue
            }

            if HIDPPControl.gestureSources.contains(control), state.heldGestureSource == nil {
                state.heldGestureSource = control
                state.gestureAccumulatorX = 0
                state.gestureAccumulatorY = 0
                state.discardNextRawXY = true
            }
        }

        for control in released where control == state.heldGestureSource {
            state.heldGestureSource = nil
            guard let role = HIDPPControl.gestureRole(of: control, hasHapticPanel: Self.hasHapticPanel(device))
            else { continue }
            resolveGesture(state: state, device: device, role: role,
                           settings: configuration.buttons.settings(for: role))
        }
    }

    /// Whether the gesture button is the thumb button on this mouse, or a
    /// separate one beside a haptic panel. The control table is what the
    /// reconciler diverted by, so it wins when it has been read; it is only
    /// ever read from the cache here, since a transaction issued on the
    /// notification thread would wait for an answer that thread delivers.
    private static func hasHapticPanel(_ device: ManagedDevice) -> Bool {
        if let table = device.target?.cachedControlTable {
            return table.contains { $0.controlID == HIDPPControl.hapticPanel && $0.isDivertable }
        }
        return device.capabilities?.hapticPanel ?? false
    }

    /// Decides whether a thumb-button press was a flick or a plain tap, and runs
    /// whatever is bound to it.
    ///
    /// With gestures switched off the button is simply a button: the movement
    /// is ignored and the tap action always runs. That is deliberate — someone
    /// who only wants one extra button should not have to hold the mouse still
    /// to get it.
    private func resolveGesture(
        state: DeviceState,
        device: ManagedDevice,
        role: HIDPPControl.GestureRole,
        settings: GestureButtonSettings
    ) {
        let dx = state.gestureAccumulatorX
        let dy = state.gestureAccumulatorY
        state.gestureAccumulatorX = 0
        state.gestureAccumulatorY = 0

        if let gestures = settings.gestures.effective {
            let threshold = max(settings.threshold, 1)
            if max(abs(dx), abs(dy)) >= threshold {
                let direction: GestureDirection
                if abs(dx) >= abs(dy) {
                    direction = dx > 0 ? .right : .left
                } else {
                    // IOKit's Y axis grows downwards.
                    direction = dy > 0 ? .down : .up
                }
                if let action = gestures[direction] {
                    os_log("%{public}@ gesture %{public}@ on %{public}@",
                           log: Self.log, type: .info,
                           role == .thumbRest ? "thumb" : "gesture-button",
                           direction.rawValue, device.displayName)
                    _ = actions.run(action, device: device)
                }
                return
            }
        }

        if let action = settings.tap.effective {
            _ = actions.run(action, device: device)
        }
    }
}
