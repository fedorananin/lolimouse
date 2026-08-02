// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import CoreGraphics
import Foundation

/// Folds a high-resolution wheel's many increments back into whole detents.
///
/// A Logitech wheel in high-resolution mode reports eight or more increments
/// for one physical click. Software that scrolls smoothly likes that; software
/// that advances one photo, one slide or one list item per wheel event does
/// not, and jumps eight items instead of one. Accumulating the increments and
/// emitting one event per completed detent fixes that without giving up the
/// wheel's precision elsewhere.
public struct DetentAccumulator {
    /// After this long without movement the leftover fraction is dropped, so a
    /// scroll started ten minutes ago cannot contribute to this one.
    public static let idleReset: TimeInterval = 1

    private var remainder: Double = 0
    private var direction: Int = 0
    private var lastEvent: TimeInterval?

    /// Feeds `units` into the accumulator.
    ///
    /// Returns the number of whole detents to emit, or `nil` when the movement
    /// so far is less than half a detent and the event should be swallowed.
    public init() {}

    public mutating func consume(units: Double, multiplier: Int, now: TimeInterval) -> Int? {
        guard units != 0 else { return nil }
        guard multiplier > 1 else {
            return Int(units.rounded(.toNearestOrAwayFromZero))
        }

        let currentDirection = units > 0 ? 1 : -1
        if let lastEvent, now - lastEvent > Self.idleReset {
            remainder = 0
        }
        // Reversing direction mid-scroll must not be damped by the fraction
        // left over from the other direction.
        if direction != 0, currentDirection != direction {
            remainder = 0
        }

        direction = currentDirection
        lastEvent = now
        remainder += units

        let scale = Double(multiplier)
        guard abs(remainder) * 2 >= scale else { return nil }

        let steps = Int((remainder / scale).rounded(.toNearestOrAwayFromZero))
        remainder -= Double(steps) * scale
        return steps
    }

    public mutating func reset() {
        remainder = 0
        direction = 0
        lastEvent = nil
    }
}

/// Applies one device's scrolling configuration to scroll events.
///
/// The settings are swapped in place rather than rebuilding the object, so the
/// accumulators keep their state while the user drags a slider — otherwise
/// every change would produce a visible hitch in mid-scroll.
public final class ScrollProcessor {
    public var settings: ScrollingSettings
    /// The device's high-resolution multiplier, or 1 when the wheel is not in
    /// high-resolution mode.
    public var highResolutionMultiplier: Int

    private var vertical = DetentAccumulator()
    private var horizontal = DetentAccumulator()

    public init(settings: ScrollingSettings = ScrollingSettings(), highResolutionMultiplier: Int = 1) {
        self.settings = settings
        self.highResolutionMultiplier = highResolutionMultiplier
    }

    public func reset() {
        vertical.reset()
        horizontal.reset()
    }

    /// Transforms a scroll event, or returns `nil` to swallow it.
    public func process(_ event: CGEvent, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CGEvent? {
        guard !event.isSynthetic else { return event }

        let view = ScrollWheelEvent(event)

        // Trackpad gestures share this event type. Transforming them would
        // wreck two-finger scrolling, which the user never asked us to touch.
        guard !view.looksLikeTrackpad else { return event }
        guard settings.managesAnything else { return event }

        var alive = false
        alive = apply(axis: settings.vertical, vertical: true, view: view, now: now) || alive
        alive = apply(axis: settings.horizontal, vertical: false, view: view, now: now) || alive

        // Everything was swallowed by the detent accumulator; sending an event
        // with no movement makes some applications flash their scroll bars.
        return alive || view.hasMovement ? event : nil
    }

    /// Returns `true` if this axis still carries movement afterwards.
    private func apply(
        axis: AxisScrolling,
        vertical isVertical: Bool,
        view: ScrollWheelEvent,
        now: TimeInterval
    ) -> Bool {
        let direction = view.direction(vertical: isVertical)
        guard direction != 0 else { return false }

        if axis.reverse.effective == true {
            view.negate(vertical: isVertical)
        }

        // Detent normalisation is a vertical-only affair: the multiplier comes
        // from the main wheel (HID++ 0x2121), and only that wheel has detents
        // to fold increments back into. The thumbwheel is free-spinning —
        // quantising it to "clicks" it does not have turns smooth horizontal
        // panning into the same stepped scrolling as the vertical wheel.
        let multiplier = isVertical && settings.normalizeHighResolutionWheel.effective == true
            ? max(highResolutionMultiplier, 1)
            : 1

        // Normalisation and a fixed step size both work in whole detents, so
        // they share the accumulator.
        let wantsWholeDetents = multiplier > 1 || axis.distance.effective != nil

        if wantsWholeDetents {
            let units = view.units(vertical: isVertical, multiplier: multiplier)
            var accumulator = isVertical ? vertical : horizontal
            let steps = accumulator.consume(units: units, multiplier: multiplier, now: now)
            if isVertical { vertical = accumulator } else { horizontal = accumulator }

            guard let steps, steps != 0 else {
                view.zero(vertical: isVertical)
                return false
            }

            switch axis.distance.effective {
            case let .lines(count):
                view.setWholeSteps(steps * max(count, 1), vertical: isVertical)
            case let .pixels(count):
                view.setPixels(Double(steps * max(count, 1)), vertical: isVertical)
            case .system, .none:
                view.setWholeSteps(steps, vertical: isVertical)
            }
        }

        // A fixed step size is by definition unaccelerated, so acceleration is
        // only applied when the user has not asked for one.
        if axis.distance.effective == nil, let acceleration = axis.acceleration.effective, acceleration != 1 {
            let magnitude = abs(view.units(vertical: isVertical, multiplier: multiplier))
            if magnitude > 0 {
                view.scale(pow(magnitude, acceleration - 1), vertical: isVertical)
            }
        }

        if let speed = axis.speed.effective, speed != 1 {
            view.scale(max(speed, 0.01), vertical: isVertical)
        }

        return view.direction(vertical: isVertical) != 0
    }
}
