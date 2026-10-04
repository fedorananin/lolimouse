// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation

/// Turns a stream of finger positions into "N fingers swiped that way"
/// decisions.
///
/// Pure and synchronous, like `FingerTapDetector`, so it can be tested without
/// a trackpad. One episode runs from the first finger touching down to the
/// last one lifting, and yields at most one swipe: it fires while the fingers
/// are still moving, the moment they have travelled far enough, and then
/// stays quiet until the hand is off the surface.
///
/// A swipe is *every* finger moving the same way. The mean position alone is
/// not enough — two fingers scrolling beside a resting thumb move the mean of
/// three contacts just as a three-finger swipe does, and that must stay a
/// scroll.
public struct FingerSwipeDetector: Sendable {
    /// One finger in one frame, in 0…1 surface units. `y` grows away from the
    /// user, so a swipe up is `y` increasing.
    public struct Contact: Sendable {
        /// The same number for one finger from touch-down to lift.
        public let id: Int
        public let x: Double
        public let y: Double

        public init(id: Int, x: Double, y: Double) {
            self.id = id
            self.x = x
            self.y = y
        }
    }

    public struct Swipe: Equatable, Sendable {
        public let fingers: Int
        public let direction: GestureDirection

        public init(fingers: Int, direction: GestureDirection) {
            self.fingers = fingers
            self.direction = direction
        }
    }

    /// The finger counts that can swipe. One detector watches all of them, so
    /// that an episode can only ever be one of them.
    public let fingerCounts: Set<Int>
    /// How far the fingers must travel, as a fraction of the surface's
    /// height. About a centimetre and a bit on a MacBook trackpad — well past
    /// the drift a tap is allowed.
    public var minimumTravel: Double
    /// The travel has to happen within this long. Fingers that rest on the
    /// surface and creep are not a swipe.
    public var window: TimeInterval
    /// How long the full set of fingers must have been down before a swipe
    /// may fire. A hand rarely lands all at once; without this a fast
    /// four-finger swipe is taken for a three-finger one in the few
    /// milliseconds before the last finger arrives.
    public var settleTime: TimeInterval
    /// Width of the surface over its height. Positions arrive as fractions of
    /// each side, so the same hand movement reads smaller across than up and
    /// down; this puts both axes in the same unit. Trackpads sit between 1.4
    /// and 1.6, close enough that one figure serves for all of them.
    public var aspectRatio: Double
    /// How much of `minimumTravel` each single finger must have covered.
    public var fingerShare: Double
    /// How many times further along the swipe's axis than across it the
    /// fingers must have gone. A diagonal is nobody's swipe.
    public var dominance: Double

    private var peakFingers = 0
    private var fired = false
    /// Where each finger was when the current measurement began.
    private var anchor: [Int: (x: Double, y: Double)] = [:]
    private var anchorTime: TimeInterval = 0
    /// When the current set of fingers was first seen complete.
    private var formedTime: TimeInterval = 0

    public init(
        fingerCounts: Set<Int>,
        minimumTravel: Double = 0.15,
        window: TimeInterval = 0.3,
        settleTime: TimeInterval = 0.04,
        aspectRatio: Double = 1.5,
        fingerShare: Double = 0.5,
        dominance: Double = 1.5
    ) {
        self.fingerCounts = fingerCounts
        self.minimumTravel = minimumTravel
        self.window = window
        self.settleTime = settleTime
        self.aspectRatio = aspectRatio
        self.fingerShare = fingerShare
        self.dominance = dominance
    }

    /// Feeds one frame. Returns the swipe on the frame that completes it.
    public mutating func process(contacts: [Contact], timestamp: TimeInterval) -> Swipe? {
        guard !contacts.isEmpty else {
            peakFingers = 0
            fired = false
            anchor.removeAll(keepingCapacity: true)
            return nil
        }

        peakFingers = max(peakFingers, contacts.count)
        // Fewer fingers than the episode has already seen is a hand lifting
        // off, finger by finger, and must not read as a smaller swipe.
        guard !fired, contacts.count == peakFingers, fingerCounts.contains(contacts.count) else {
            anchor.removeAll(keepingCapacity: true)
            return nil
        }

        let sameFingers = anchor.count == contacts.count && contacts.allSatisfy { anchor[$0.id] != nil }
        guard sameFingers else {
            setAnchor(contacts, at: timestamp)
            formedTime = timestamp
            return nil
        }

        var sumX = 0.0, sumY = 0.0
        for contact in contacts {
            let moved = travel(of: contact)
            sumX += moved.x
            sumY += moved.y
        }
        let meanX = sumX / Double(contacts.count)
        let meanY = sumY / Double(contacts.count)
        let horizontal = abs(meanX) > abs(meanY)
        let along = horizontal ? meanX : meanY
        let across = horizontal ? meanY : meanX

        if abs(along) >= minimumTravel,
           abs(along) >= abs(across) * dominance,
           timestamp - formedTime >= settleTime
        {
            let sign = along < 0 ? -1.0 : 1.0
            let together = contacts.allSatisfy { contact in
                let moved = travel(of: contact)
                return (horizontal ? moved.x : moved.y) * sign >= minimumTravel * fingerShare
            }
            if together {
                fired = true
                let direction: GestureDirection = horizontal
                    ? (along > 0 ? .right : .left)
                    : (along > 0 ? .up : .down)
                return Swipe(fingers: contacts.count, direction: direction)
            }
        }

        // Too slow to be a swipe so far: measure afresh from here, so that
        // fingers which rested first and swipe afterwards still count.
        if timestamp - anchorTime > window {
            setAnchor(contacts, at: timestamp)
        }
        return nil
    }

    /// How far a finger has gone since the anchor, with both axes in units of
    /// the surface's height.
    private func travel(of contact: Contact) -> (x: Double, y: Double) {
        guard let start = anchor[contact.id] else { return (0, 0) }
        return ((contact.x - start.x) * aspectRatio, contact.y - start.y)
    }

    private mutating func setAnchor(_ contacts: [Contact], at timestamp: TimeInterval) {
        anchor.removeAll(keepingCapacity: true)
        for contact in contacts {
            anchor[contact.id] = (contact.x, contact.y)
        }
        anchorTime = timestamp
    }
}
