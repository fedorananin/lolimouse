// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation

/// Turns a stream of finger counts into "N fingers tapped" decisions.
///
/// Pure and synchronous so it can be tested without a trackpad. One episode
/// runs from the first finger touching down to the last one lifting; it is a
/// tap when exactly `fingers` were down at the peak, they did not travel,
/// and the whole thing was over quickly. Anything else — one finger more, a
/// swipe, a slow press — is left entirely to macOS.
public struct FingerTapDetector: Sendable {
    /// How many fingers make the tap. Three and four are what macOS itself
    /// distinguishes; anything else is accepted but untested on hardware.
    public let fingers: Int
    /// Longest an episode may last and still be a tap.
    public var maximumDuration: TimeInterval
    /// How far the three-finger centroid may drift, in 0…1 surface units.
    /// Roughly a fifth of a centimetre on a MacBook trackpad.
    public var maximumTravel: Double

    private var episodeStart: TimeInterval?
    private var peakFingers = 0
    private var origin: (x: Double, y: Double)?
    private var travel: Double = 0

    public init(fingers: Int, maximumDuration: TimeInterval = 0.35, maximumTravel: Double = 0.05) {
        self.fingers = fingers
        self.maximumDuration = maximumDuration
        self.maximumTravel = maximumTravel
    }

    /// Feeds one frame. Returns `true` on the frame that completes a tap.
    public mutating func process(fingerCount: Int, centroid: (x: Double, y: Double)?, timestamp: TimeInterval) -> Bool {
        if fingerCount > 0 {
            if episodeStart == nil {
                episodeStart = timestamp
                peakFingers = 0
                origin = nil
                travel = 0
            }
            peakFingers = max(peakFingers, fingerCount)
            // Movement only counts while the full set is down: the centroid
            // jumps on its own as fingers land and lift.
            if fingerCount == fingers, let centroid {
                if let origin {
                    travel = max(travel, hypot(centroid.x - origin.x, centroid.y - origin.y))
                } else {
                    origin = centroid
                }
            }
            return false
        }

        guard let start = episodeStart else { return false }
        episodeStart = nil
        return peakFingers == fingers
            && timestamp - start <= maximumDuration
            && travel <= maximumTravel
    }
}
