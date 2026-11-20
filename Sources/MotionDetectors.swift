import CoreGraphics
import Foundation

/// Detects real jumps from the hips rising above the player's standing height, measured
/// relative to torso length so it works near or far, for kids or grown-ups.
/// Also keeps track of one player across frames, which other detectors can reuse.
final class JumpDetector {
    var takeoffRise: CGFloat = 0.22   // hips this far above standing height (in torso lengths) = jump
    var landingRise: CGFloat = 0.08   // back below this = landed
    var minGap: TimeInterval = 0.35

    /// The player being tracked on the latest camera frame.
    private(set) var player: Body?
    private(set) var torso: CGFloat = 0
    private(set) var lastJump: TimeInterval = -10
    private(set) var airborne = false
    /// True when the latest `update` saw a new camera frame.
    private(set) var newFrame = false
    private(set) var frameDT: Double = 1.0 / 30

    private var trackedCenter: CGPoint?
    private var standingHip: CGFloat?
    private var airborneSince: TimeInterval = 0
    private var lastTimestamp: Double = 0

    /// Call every game frame. Returns true once, on the frame a jump takes off.
    func update(_ pose: PoseFrame, now: TimeInterval) -> Bool {
        newFrame = pose.timestamp != lastTimestamp
        guard newFrame else { return false }
        if lastTimestamp > 0 { frameDT = min(max(pose.timestamp - lastTimestamp, 1.0 / 120), 0.5) }
        lastTimestamp = pose.timestamp

        player = pickPlayer(pose.bodies)
        guard let body = player, let hip = Self.hipY(body), let neck = body[.neck] else { return false }
        torso = neck.y - hip
        guard torso > 0.03 else { return false }

        guard let standing = standingHip else { standingHip = hip; return false }
        let rise = (hip - standing) / torso

        if airborne {
            if rise < landingRise {
                airborne = false
            } else if now - airborneSince > 1.5 {
                // Stuck "in the air" (stepped onto something, camera moved): re-learn standing height.
                airborne = false
                standingHip = hip
            }
        } else if rise > takeoffRise, now - lastJump > minGap {
            airborne = true
            airborneSince = now
            lastJump = now
            return true
        } else {
            // Slowly follow the standing height as the player moves around.
            standingHip = standing + (hip - standing) * 0.08
        }
        return false
    }

    static func hipY(_ body: Body) -> CGFloat? {
        if let l = body[.leftHip], let r = body[.rightHip] { return (l.y + r.y) / 2 }
        return body[.root]?.y ?? body[.leftHip]?.y ?? body[.rightHip]?.y
    }

    private func center(_ body: Body) -> CGPoint {
        let sum = body.values.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(max(body.count, 1)), y: sum.y / CGFloat(max(body.count, 1)))
    }

    /// Stick with the same player across frames; pick the most visible one at the start.
    private func pickPlayer(_ bodies: [Body]) -> Body? {
        let candidates = bodies.filter { $0.count >= 6 }
        let chosen: Body?
        if let last = trackedCenter {
            chosen = candidates.min { hypot(center($0).x - last.x, center($0).y - last.y) < hypot(center($1).x - last.x, center($1).y - last.y) }
        } else {
            chosen = candidates.max { $0.count < $1.count }
        }
        if let chosen {
            let c = center(chosen)
            if let last = trackedCenter, hypot(c.x - last.x, c.y - last.y) > 0.25 { standingHip = nil } // switched player
            trackedCenter = c
        } else {
            trackedCenter = nil
        }
        return chosen
    }
}

/// Detects walking (or marching in place) from the knees taking turns going up and down.
/// Measures how far the left-minus-right knee height swings over a short window, so camera
/// jitter (tiny swings) doesn't count but real steps (big swings) do.
/// `pace` is 0 when standing still and rises toward 1 for big, brisk marching.
final class WalkDetector {
    var startSwing: CGFloat = 0.2    // knee swing (in torso lengths) needed to count as walking
    var fullPaceSwing: CGFloat = 0.6 // swing that maps to full pace
    var window: Double = 0.7         // seconds of history; about one full step cycle

    private(set) var swing: CGFloat = 0
    private var history: [(time: Double, diff: CGFloat)] = []
    private var clock: Double = 0
    private var smoothedDiff: CGFloat?

    var pace: CGFloat {
        guard swing > startSwing else { return 0 }
        return min(0.35 + (swing - startSwing) / (fullPaceSwing - startSwing) * 0.65, 1)
    }

    /// Call when `JumpDetector` reports a new frame, passing its player and torso length.
    func update(player: Body?, torso: CGFloat, frameDT: Double, airborne: Bool) {
        clock += frameDT
        history.removeAll { clock - $0.time > window }
        guard let body = player, torso > 0.03, let raw = Self.legDifference(body) else {
            smoothedDiff = nil
            swing *= 0.85
            return
        }
        let diff = (smoothedDiff ?? raw) + (raw - (smoothedDiff ?? raw)) * 0.5
        smoothedDiff = diff
        if !airborne { history.append((clock, diff / torso)) } // both legs move together in a jump
        guard history.count >= 4, let lo = history.map(\.diff).min(), let hi = history.map(\.diff).max() else {
            swing *= 0.85
            return
        }
        swing = hi - lo
    }

    /// Height difference between the two legs: swings back and forth while marching.
    private static func legDifference(_ body: Body) -> CGFloat? {
        if let l = body[.leftKnee], let r = body[.rightKnee] { return l.y - r.y }
        if let l = body[.leftAnkle], let r = body[.rightAnkle] { return l.y - r.y }
        return nil
    }
}
