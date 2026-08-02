// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import CoreGraphics
import Foundation
import IOKitSPI

/// A typed view over a scroll `CGEvent`.
///
/// A single scroll event carries the same movement four times over, in four
/// different units, and applications disagree about which one they read:
///
///   * `deltaAxis`      — whole wheel clicks, what most apps use
///   * `pointDeltaAxis` — pixels, used by anything doing smooth scrolling
///   * `fixedPtDeltaAxis` — the same movement in fixed point
///   * the IOHIDEvent's `ScrollX/Y` — raw wheel units, where a
///     high-resolution Logitech wheel reports eight or more per detent
///
/// Changing one and leaving the rest alone is the single most common way to
/// produce scrolling that works in Safari and misbehaves everywhere else, so
/// every writer here updates all four.
public struct ScrollWheelEvent {
    public let event: CGEvent
    private let hidEvent: IOHIDEvent?

    public init(_ event: CGEvent) {
        self.event = event
        hidEvent = CGEventCopyIOHIDEvent(event)
    }

    // MARK: - Phase

    /// True for trackpad-style continuous scrolling.
    public var isContinuous: Bool {
        get { event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 }
        nonmutating set { event.setIntegerValueField(.scrollWheelEventIsContinuous, value: newValue ? 1 : 0) }
    }

    public var momentumPhase: Int64 {
        event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    }

    public var scrollPhase: Int64 {
        event.getIntegerValueField(.scrollWheelEventScrollPhase)
    }

    /// A trackpad gesture rather than a wheel: continuous, and carrying a phase.
    public var looksLikeTrackpad: Bool {
        isContinuous && (scrollPhase != 0 || momentumPhase != 0)
    }

    // MARK: - Vertical

    public var deltaY: Int64 {
        get { event.getIntegerValueField(.scrollWheelEventDeltaAxis1) }
        nonmutating set { event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: newValue) }
    }

    public var pointDeltaY: Double {
        get { event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) }
        nonmutating set { event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: newValue) }
    }

    public var fixedPointDeltaY: Double {
        get { event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) }
        nonmutating set { event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: newValue) }
    }

    public var hidScrollY: Double {
        get {
            guard let hidEvent else { return 0 }
            return IOHIDEventGetFloatValue(hidEvent, kLoLiIOHIDEventFieldScrollY)
        }
        nonmutating set {
            guard let hidEvent else { return }
            IOHIDEventSetFloatValue(hidEvent, kLoLiIOHIDEventFieldScrollY, newValue)
        }
    }

    // MARK: - Horizontal

    public var deltaX: Int64 {
        get { event.getIntegerValueField(.scrollWheelEventDeltaAxis2) }
        nonmutating set { event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: newValue) }
    }

    public var pointDeltaX: Double {
        get { event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) }
        nonmutating set { event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: newValue) }
    }

    public var fixedPointDeltaX: Double {
        get { event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) }
        nonmutating set { event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: newValue) }
    }

    public var hidScrollX: Double {
        get {
            guard let hidEvent else { return 0 }
            return IOHIDEventGetFloatValue(hidEvent, kLoLiIOHIDEventFieldScrollX)
        }
        nonmutating set {
            guard let hidEvent else { return }
            IOHIDEventSetFloatValue(hidEvent, kLoLiIOHIDEventFieldScrollX, newValue)
        }
    }

    // MARK: - Derived

    public var hasMovement: Bool {
        deltaX != 0 || deltaY != 0
            || pointDeltaX != 0 || pointDeltaY != 0
            || fixedPointDeltaX != 0 || fixedPointDeltaY != 0
            || hidScrollX != 0 || hidScrollY != 0
    }

    /// Direction of travel on an axis: -1, 0 or +1, taken from whichever field
    /// actually carries a value.
    public func direction(vertical: Bool) -> Int {
        let candidates: [Double] = vertical
            ? [Double(deltaY), fixedPointDeltaY, pointDeltaY, hidScrollY]
            : [Double(deltaX), fixedPointDeltaX, pointDeltaX, hidScrollX]
        for value in candidates where value != 0 {
            return value < 0 ? -1 : 1
        }
        return 0
    }

    /// Movement on an axis in wheel units, where one unit is one detent on a
    /// wheel that is not in high-resolution mode.
    ///
    /// `multiplier` is the device's high-resolution multiplier, used to scale
    /// the fixed-point and point fields back into whole detents.
    public func units(vertical: Bool, multiplier: Int) -> Double {
        let sign = Double(direction(vertical: vertical))
        guard sign != 0 else { return 0 }

        let hid = abs(vertical ? hidScrollY : hidScrollX)
        if hid >= 0.5 {
            // The IOHIDEvent carries raw wheel units, which is what we want.
            return sign * hid
        }

        let scale = Double(max(multiplier, 1))
        let fixedPoint = abs(vertical ? fixedPointDeltaY : fixedPointDeltaX) * scale
        if fixedPoint >= 0.5 { return sign * fixedPoint }

        let points = abs(vertical ? pointDeltaY : pointDeltaX) * scale / 10
        if points >= 0.5 { return sign * points }

        let whole = abs(Double(vertical ? deltaY : deltaX))
        if whole > 0 { return sign * whole }

        return sign
    }

    /// Writes `steps` whole wheel clicks onto an axis, keeping every field
    /// consistent.
    public func setWholeSteps(_ steps: Int, vertical: Bool) {
        let points = Double(steps) * 10
        if vertical {
            deltaY = Int64(steps)
            pointDeltaY = points
            fixedPointDeltaY = Double(steps)
            hidScrollY = Double(steps)
        } else {
            deltaX = Int64(steps)
            pointDeltaX = points
            fixedPointDeltaX = Double(steps)
            hidScrollX = Double(steps)
        }
    }

    /// Writes a pixel distance onto an axis.
    public func setPixels(_ pixels: Double, vertical: Bool) {
        // The whole-click field still has to carry the sign, or apps that only
        // read it will see nothing happen.
        let clicks = Int64((pixels / 10).rounded(.towardZero))
        let signum: Int64 = pixels == 0 ? 0 : (pixels < 0 ? -1 : 1)
        if vertical {
            deltaY = clicks == 0 ? signum : clicks
            pointDeltaY = pixels
            fixedPointDeltaY = pixels / 10
            hidScrollY = pixels / 10
        } else {
            deltaX = clicks == 0 ? signum : clicks
            pointDeltaX = pixels
            fixedPointDeltaX = pixels / 10
            hidScrollX = pixels / 10
        }
    }

    /// Multiplies every representation of an axis by `factor`.
    ///
    /// Every field is read before any of them is written. CoreGraphics derives
    /// the pixel and fixed-point deltas from the whole-click delta, so writing
    /// the click field first silently overwrites the very values we are about
    /// to scale.
    public func scale(_ factor: Double, vertical: Bool) {
        if vertical {
            let clicks = Double(deltaY)
            let points = pointDeltaY
            let fixed = fixedPointDeltaY
            let hid = hidScrollY

            let scaled = clicks * factor
            deltaY = Int64(scaled.rounded(scaled < 0 ? .down : .up))
            pointDeltaY = points * factor
            fixedPointDeltaY = fixed * factor
            hidScrollY = hid * factor
        } else {
            let clicks = Double(deltaX)
            let points = pointDeltaX
            let fixed = fixedPointDeltaX
            let hid = hidScrollX

            let scaled = clicks * factor
            deltaX = Int64(scaled.rounded(scaled < 0 ? .down : .up))
            pointDeltaX = points * factor
            fixedPointDeltaX = fixed * factor
            hidScrollX = hid * factor
        }
    }

    public func zero(vertical: Bool) {
        if vertical {
            deltaY = 0
            pointDeltaY = 0
            fixedPointDeltaY = 0
            hidScrollY = 0
        } else {
            deltaX = 0
            pointDeltaX = 0
            fixedPointDeltaX = 0
            hidScrollX = 0
        }
    }

    /// Reverses an axis. Reads before writing, for the same reason as `scale`.
    public func negate(vertical: Bool) {
        if vertical {
            let clicks = deltaY
            let points = pointDeltaY
            let fixed = fixedPointDeltaY
            let hid = hidScrollY

            deltaY = -clicks
            pointDeltaY = -points
            fixedPointDeltaY = -fixed
            hidScrollY = -hid
        } else {
            let clicks = deltaX
            let points = pointDeltaX
            let fixed = fixedPointDeltaX
            let hid = hidScrollX

            deltaX = -clicks
            pointDeltaX = -points
            fixedPointDeltaX = -fixed
            hidScrollX = -hid
        }
    }
}

public extension CGEvent {
    /// Marker written into events LoLiMouse creates, so the tap can recognise
    /// its own output and leave it alone instead of transforming it twice.
    static let syntheticMarker: Int64 = 0x4C4F_4C49 // "LOLI"

    var isSynthetic: Bool {
        getIntegerValueField(.eventSourceUserData) == CGEvent.syntheticMarker
    }

    func markSynthetic() {
        setIntegerValueField(.eventSourceUserData, value: CGEvent.syntheticMarker)
    }

    /// The registry ID of the device that produced this event, when macOS knows.
    var senderID: UInt64? {
        guard let hidEvent = CGEventCopyIOHIDEvent(self) else { return nil }
        let id = IOHIDEventGetSenderID(hidEvent)
        return id == 0 ? nil : id
    }
}
