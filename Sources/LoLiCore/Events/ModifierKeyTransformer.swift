// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import AppKit
import CoreGraphics
import Foundation
import HIDKit
import os.log

/// Applies a device's modifier-key scroll actions, ahead of the ordinary
/// scroll pipeline.
///
/// The technique follows LinearMouse's `ModifierActionsTransformer`: look at
/// the flags on the scroll event, run the configured action, and — crucially —
/// **remove the handled flag from the event**, so the application never sees
/// "⌘ + scroll" and cannot add its own modifier behaviour on top of ours.
///
/// The two zoom flavours post synthetic input instead of transforming the
/// event, so posting is injected as closures — the logic stays testable
/// without sending real keystrokes from the test process.
public final class ModifierKeyTransformer {
    private static let log = LoLiLog.events

    /// Which action each held modifier triggers. Swapped in place on
    /// configuration changes, like `ScrollProcessor.settings`.
    public var actions: [ModifierKey: ModifierKeyAction]

    /// Posts the application zoom shortcut; `direction` is +1 in, -1 out.
    public var postZoom: (_ direction: Int) -> Void
    /// Posts one step of a synthetic pinch gesture.
    public var postPinch: (_ phase: PinchPhase, _ magnification: Double) -> Void

    public enum PinchPhase {
        case began, changed, ended
    }

    /// How much magnification one point of scroll travel produces. The value
    /// LinearMouse ships with; it feels close to a real trackpad pinch.
    public static let pinchMagnificationPerPoint = 0.005

    private var pinchActive = false
    private var pinchReversed = false

    public init(
        actions: [ModifierKey: ModifierKeyAction] = [:],
        postZoom: @escaping (Int) -> Void = SyntheticInput.postZoomShortcut,
        postPinch: @escaping (PinchPhase, Double) -> Void = SyntheticInput.postPinch
    ) {
        self.actions = actions
        self.postZoom = postZoom
        self.postPinch = postPinch
    }


    /// Transforms a scroll event, or returns `nil` to swallow it.
    ///
    /// `flagsChanged` events must also be routed here whenever a pinch action
    /// is configured: releasing the modifier is what ends the gesture.
    public func process(_ event: CGEvent, type: CGEventType) -> CGEvent? {
        if type == .flagsChanged {
            endPinchIfNeeded()
            return event
        }

        guard type == .scrollWheel, !actions.isEmpty else { return event }

        // While a pinch is in progress every scroll event feeds the gesture,
        // even if its flags momentarily disagree — the gesture ends on
        // `flagsChanged`, not on a per-event flag check, so a single event
        // with stale flags cannot split one pinch into two.
        if pinchActive {
            feedPinch(event)
            return nil
        }

        var current = event
        for modifier in ModifierKey.allCases {
            let flag = modifier.flag
            guard current.flags.contains(flag) else { continue }
            guard let action = actions[modifier] else { continue }
            guard let transformed = apply(action, to: current) else { return nil }
            current = transformed
            // The application must never see the modifier we acted on.
            current.flags.remove(flag)
        }
        return current
    }

    /// Ends an in-flight pinch. Called when the tap is torn down, so a gesture
    /// is never left dangling — applications that saw "began" without "ended"
    /// keep their content half-zoomed.
    public func deactivate() {
        endPinchIfNeeded()
    }

    // MARK: - Actions

    private func apply(_ action: ModifierKeyAction, to event: CGEvent) -> CGEvent? {
        let view = ScrollWheelEvent(event)

        switch action {
        case .ignore:
            // Stripping the flag is the whole action: the app sees plain
            // scrolling instead of its own modifier behaviour.
            break

        case .preventDefault:
            return nil

        case .alterOrientation:
            swapAxes(view)

        case let .changeSpeed(scale):
            view.scale(scale, vertical: true)
            view.scale(scale, vertical: false)

        case .zoom, .zoomReversed:
            var direction = view.direction(vertical: true)
            if direction == 0 { direction = view.direction(vertical: false) }
            guard direction != 0 else { return event }
            if action == .zoomReversed { direction = -direction }
            postZoom(direction)
            return nil

        case .pinchZoom, .pinchZoomReversed:
            pinchReversed = action == .pinchZoomReversed
            pinchActive = true
            postPinch(.began, 0)
            os_log("pinch zoom began", log: Self.log, type: .info)
            feedPinch(event)
            return nil
        }

        return event
    }

    private func feedPinch(_ event: CGEvent) {
        let view = ScrollWheelEvent(event)
        let direction = pinchReversed ? -1.0 : 1.0
        let magnification = view.pointDeltaY * Self.pinchMagnificationPerPoint * direction
        guard magnification != 0 else { return }
        postPinch(.changed, magnification)
    }

    private func endPinchIfNeeded() {
        guard pinchActive else { return }
        pinchActive = false
        pinchReversed = false
        postPinch(.ended, 0)
        os_log("pinch zoom ended", log: Self.log, type: .info)
    }

    /// Swaps the vertical and horizontal movement, all four representations at
    /// once — reading everything before writing anything, for the same reason
    /// as `ScrollWheelEvent.scale`.
    private func swapAxes(_ view: ScrollWheelEvent) {
        let deltaY = view.deltaY
        let pointY = view.pointDeltaY
        let fixedY = view.fixedPointDeltaY
        let hidY = view.hidScrollY
        let deltaX = view.deltaX
        let pointX = view.pointDeltaX
        let fixedX = view.fixedPointDeltaX
        let hidX = view.hidScrollX

        view.deltaY = deltaX
        view.pointDeltaY = pointX
        view.fixedPointDeltaY = fixedX
        view.hidScrollY = hidX
        view.deltaX = deltaY
        view.pointDeltaX = pointY
        view.fixedPointDeltaX = fixedY
        view.hidScrollX = hidY
    }
}

public extension ModifierKey {
    /// The flag this modifier sets on a CGEvent.
    var flag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .shift: return .maskShift
        case .option: return .maskAlternate
        case .control: return .maskControl
        }
    }

    /// The modifiers held according to an event's flags.
    static func held(in flags: CGEventFlags) -> Set<ModifierKey> {
        Set(allCases.filter { flags.contains($0.flag) })
    }
}

/// Posts the synthetic input the zoom actions need.
///
/// Everything here is marked with the synthetic marker so our own tap ignores
/// it — the zoom shortcut in particular would otherwise re-enter the pipeline.
public enum SyntheticInput {
    /// Sends the near-universal application zoom shortcut: ⌘= to zoom in,
    /// ⌘− to zoom out — the same pair the `zoomIn`/`zoomOut` button actions
    /// already use.
    ///
    /// The events carry exactly `⌘` in their flags, nothing else: the user is
    /// physically holding the modifier that triggered this, and letting it
    /// leak into the synthetic keystroke would turn ⌘= into ⌥⌘= for an
    /// option-triggered zoom.
    public static func postZoomShortcut(direction: Int) {
        let keyCode: CGKeyCode = direction > 0 ? 0x18 : 0x1B // ⌘= / ⌘−
        let source = CGEventSource(stateID: .hidSystemState)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.markSynthetic()
        up.markSynthetic()
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// Synthesises one step of a trackpad pinch ("magnify") gesture.
    ///
    /// There is no public API for creating gesture events. The field numbers
    /// come from WebKit's CoreGraphics SPI headers and are the ones LinearMouse
    /// has shipped for years:
    ///
    ///   * event type 29        — NSEvent.EventType.gesture
    ///   * field 110            — the embedded IOHIDEvent type; 8 is "zoom"
    ///   * field 132            — gesture phase (CGSGesturePhase)
    ///   * field 113            — zoom magnification, a Double
    public static func postPinch(phase: ModifierKeyTransformer.PinchPhase, magnification: Double) {
        guard let gestureType = CGEventType(rawValue: 29),
              let event = CGEvent(source: nil)
        else { return }

        event.type = gestureType
        event.flags = []
        event.setIntegerValueField(gestureHIDTypeField, value: zoomHIDType)
        event.setIntegerValueField(gesturePhaseField, value: phase.cgsValue)
        event.setDoubleValueField(gestureZoomValueField, value: magnification)
        event.markSynthetic()
        event.post(tap: .cgSessionEventTap)
    }

    private static let gestureHIDTypeField = CGEventField(rawValue: 110)!
    private static let gestureZoomValueField = CGEventField(rawValue: 113)!
    private static let gesturePhaseField = CGEventField(rawValue: 132)!
    /// kIOHIDEventTypeZoom.
    private static let zoomHIDType: Int64 = 8
}

extension ModifierKeyTransformer.PinchPhase {
    /// CGSGesturePhase, per WebKit's CoreGraphicsTestSPI.h.
    var cgsValue: Int64 {
        switch self {
        case .began: return 1
        case .changed: return 2
        case .ended: return 4
        }
    }
}
