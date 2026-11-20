import CoreGraphics
import Foundation

/// Follows one player across frames: picks the most visible person at the start, then sticks
/// with whoever is nearest. Reports when the player was lost or swapped, so detectors can
/// recalibrate instead of comparing two different people (or the same person across a gap).
final class PlayerTracker {
    /// Moving farther than this between frames (normalized units) counts as a different player.
    var swapDistance: CGFloat = 0.25
    /// A gap between frames longer than this means tracking was interrupted.
    var maxFrameGap: Double = 0.3

    private(set) var player: Body?
    private(set) var center: CGPoint?
    /// True on a frame where the player changed, reappeared after being lost, or after a frame gap.
    private(set) var discontinuity = true

    func update(_ bodies: [Body], frameGap: Double) -> Body? {
        let candidates = bodies.filter { $0.count >= 6 }
        let chosen: Body?
        if let last = center {
            chosen = candidates.min { Self.distance(Self.centroid(of: $0), last) < Self.distance(Self.centroid(of: $1), last) }
        } else {
            chosen = candidates.max { $0.count < $1.count }
        }

        if let chosen {
            let c = Self.centroid(of: chosen)
            let swapped = center.map { Self.distance(c, $0) > swapDistance } ?? true
            discontinuity = swapped || frameGap > maxFrameGap || player == nil
            center = c
        } else {
            discontinuity = true
            center = nil
        }
        player = chosen
        return chosen
    }

    func reset() {
        player = nil
        center = nil
        discontinuity = true
    }

    static func centroid(of body: Body) -> CGPoint {
        let sum = body.values.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(max(body.count, 1)), y: sum.y / CGFloat(max(body.count, 1)))
    }

    /// Bounding box of the body's joints.
    static func bounds(of body: Body) -> CGRect {
        let xs = body.values.map(\.x), ys = body.values.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .null }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

/// Detects real jumps: the hips rise above standing height *and* the feet leave the ground.
/// Heights are measured in torso lengths, so it works near or far, for kids or grown-ups.
/// Checking the feet stops "standing up from a squat" from counting as a jump.
/// Recalibrates whenever the player is lost, swapped, or frames stop for a moment.
final class JumpDetector {
    var takeoffRise: CGFloat = 0.22   // hips this far above standing height (torso lengths) = jump
    var landingRise: CGFloat = 0.08   // back below this = landed
    var feetLift: CGFloat = 0.1       // ankles this far above the ground (torso lengths) = feet left the floor
    var minGap: TimeInterval = 0.35
    var calibrationFrames = 6         // steady frames needed after (re)calibrating before jumps count
    /// After this many "almost jumps" in a row (hips rose at least halfway), make jumping easier.
    /// 0 turns easing off.
    var easeAfterNearMisses = 3

    /// True once jumping was made easier; `easedJustNow` is true only on that frame.
    private(set) var eased = false
    private(set) var easedJustNow = false
    private(set) var nearMisses = 0
    private var attemptArmed = true

    let tracker = PlayerTracker()

    /// The player being tracked on the latest camera frame.
    var player: Body? { tracker.player }
    private(set) var torso: CGFloat = 0
    private(set) var lastJump: TimeInterval = -10
    private(set) var airborne = false
    /// True when the latest `update` saw a new camera frame.
    private(set) var newFrame = false
    private(set) var frameDT: Double = 1.0 / 30
    /// True while learning the player's standing height; no jumps are counted.
    var calibrating: Bool { standingHip == nil || steadyFrames < calibrationFrames }

    private var standingHip: CGFloat?
    private var groundAnkle: CGFloat?
    private var steadyFrames = 0
    private var airborneSince: TimeInterval = 0
    private var lastTimestamp: Double = 0

    /// Call every game frame. Returns true once, on the frame a jump takes off.
    func update(_ pose: PoseFrame, now: TimeInterval) -> Bool {
        easedJustNow = false
        if pose.isStale {
            // Camera stalled: forget the player now; recalibrate when frames come back.
            newFrame = false
            tracker.reset()
            recalibrate()
            return false
        }
        newFrame = pose.timestamp != lastTimestamp
        guard newFrame else { return false }
        let gap = lastTimestamp > 0 ? pose.timestamp - lastTimestamp : 0
        frameDT = min(max(gap, 1.0 / 120), 0.5)
        lastTimestamp = pose.timestamp

        tracker.update(pose.bodies, frameGap: gap)
        if tracker.discontinuity { recalibrate() }
        guard let body = player, let hip = Self.hipY(body), let neck = body[.neck] else {
            recalibrate()
            return false
        }
        torso = neck.y - hip
        guard torso > 0.03 else { return false }
        let ankle = Self.ankleY(body)

        guard let standing = standingHip else {
            standingHip = hip
            groundAnkle = ankle
            steadyFrames = 0
            return false
        }
        if steadyFrames < calibrationFrames {
            steadyFrames += 1
            standingHip = standing + (hip - standing) * 0.3
            if let ankle { groundAnkle = groundAnkle.map { $0 + (ankle - $0) * 0.3 } ?? ankle }
            return false
        }

        let rise = (hip - standing) / torso
        let feetUp: Bool = {
            guard let ankle, let ground = groundAnkle else { return true } // feet not visible: trust the hips
            return (ankle - ground) / torso > feetLift
        }()

        if airborne {
            if rise < landingRise {
                airborne = false
            } else if now - airborneSince > 1.5 {
                // Stuck "in the air" (stepped onto something, camera moved): re-learn standing height.
                airborne = false
                recalibrate()
            }
        } else if rise > takeoffRise, feetUp, now - lastJump > minGap {
            airborne = true
            airborneSince = now
            lastJump = now
            nearMisses = 0
            attemptArmed = false
            return true
        } else {
            noteNearMiss(rise: rise)
            // Slowly follow the standing height as the player moves around. (Standing up from a
            // squat raises the hips a lot, but the feet stay down, so it isn't mistaken for a jump.)
            // Only follow quickly near standing height: the start of a hop (or a squat) shouldn't
            // drag the baseline along and shrink the measured rise.
            let follow: CGFloat = abs(rise) < landingRise ? 0.08 : 0.01
            standingHip = standing + (hip - standing) * follow
            if let ankle, let ground = groundAnkle, (ankle - ground) / torso < feetLift {
                groundAnkle = ground + (ankle - ground) * 0.1
            }
        }
        return false
    }

    /// An attempt that got at least halfway counts once, then re-arms when the hips settle.
    private func noteNearMiss(rise: CGFloat) {
        if rise < landingRise {
            attemptArmed = true
        } else if attemptArmed, rise > takeoffRise * 0.5 {
            attemptArmed = false
            nearMisses += 1
            if easeAfterNearMisses > 0, !eased, nearMisses >= easeAfterNearMisses { ease() }
        }
    }

    /// Wider jump window: smaller hops (and a smaller foot lift) count from now on.
    func ease() {
        guard !eased else { return }
        eased = true
        easedJustNow = true
        takeoffRise *= 0.65
        feetLift *= 0.6
    }

    func reset() {
        tracker.reset()
        recalibrate()
        lastTimestamp = 0
    }

    private func recalibrate() {
        standingHip = nil
        groundAnkle = nil
        steadyFrames = 0
        airborne = false
    }

    static func hipY(_ body: Body) -> CGFloat? {
        if let l = body[.leftHip], let r = body[.rightHip] { return (l.y + r.y) / 2 }
        return body[.root]?.y ?? body[.leftHip]?.y ?? body[.rightHip]?.y
    }

    /// The lower ankle: during a jump both feet are up, so the lower one rising means liftoff.
    static func ankleY(_ body: Body) -> CGFloat? {
        switch (body[.leftAnkle], body[.rightAnkle]) {
        case let (l?, r?): return min(l.y, r.y)
        case let (l?, nil): return l.y
        case let (nil, r?): return r.y
        default: return nil
        }
    }
}

/// Detects walking (or marching in place): the knees must take turns lifting. One knee lifted
/// and held, or the same knee lifted again and again, doesn't count. Each change of the leading
/// knee is a step; walking continues for a short grace period after the last step.
/// `pace` is 0 when not walking and rises toward 1 for quick steps.
final class WalkDetector {
    var liftThreshold: CGFloat = 0.1   // one knee this much higher than the other (torso lengths)
    var slowStep: Double = 1.0         // seconds between steps that maps to the slowest walk
    var quickStep: Double = 0.35       // seconds between steps that maps to full pace
    var grace: Double = 0.9            // keep walking this long after a step

    private var clock: Double = 0
    private var smoothedDiff: CGFloat?
    private var leadingSide: Int = 0   // +1 left knee up, -1 right knee up, 0 unknown
    private var lastStep: Double?
    private var stepInterval: Double?

    var pace: CGFloat {
        guard let last = lastStep, clock - last <= max(grace, (stepInterval ?? 0) * 1.6) else { return 0 }
        guard let interval = stepInterval else { return 0.5 } // first step: walk gently
        let t = (slowStep - interval) / (slowStep - quickStep)
        return CGFloat(min(max(0.35 + t * 0.65, 0.35), 1))
    }

    /// Call when `JumpDetector` reports a new frame, passing its player and torso length.
    func update(player: Body?, torso: CGFloat, frameDT: Double, airborne: Bool) {
        clock += frameDT
        guard let body = player, torso > 0.03, let raw = Self.legDifference(body) else {
            smoothedDiff = nil
            leadingSide = 0
            return
        }
        let diff = (smoothedDiff ?? raw) + (raw - (smoothedDiff ?? raw)) * 0.5
        smoothedDiff = diff
        guard !airborne else { return } // both legs move together in a jump

        let lift = diff / torso
        let side = lift > liftThreshold ? 1 : (lift < -liftThreshold ? -1 : 0)
        guard side != 0, side != leadingSide else { return }
        defer { leadingSide = side }
        guard leadingSide != 0 else { return } // the first lifted knee only sets which side leads

        if let last = lastStep {
            let interval = clock - last
            stepInterval = interval > 2 ? nil : (stepInterval.map { $0 + (interval - $0) * 0.5 } ?? interval)
        }
        lastStep = clock
    }

    func reset() {
        smoothedDiff = nil
        leadingSide = 0
        lastStep = nil
        stepInterval = nil
    }

    /// Height difference between the two legs: swings back and forth while marching.
    private static func legDifference(_ body: Body) -> CGFloat? {
        if let l = body[.leftKnee], let r = body[.rightKnee] { return l.y - r.y }
        if let l = body[.leftAnkle], let r = body[.rightAnkle] { return l.y - r.y }
        return nil
    }
}

/// Walking and jumping input for a game, from one player. Stale poses (camera stalled) clear
/// movement immediately, so nothing keeps walking on old data while the game waits to pause.
final class Locomotion {
    let jumper = JumpDetector()
    let walker = WalkDetector()

    var pace: CGFloat { walker.pace }

    /// Call every game frame with the gated pose. Returns true on the frame a jump takes off.
    func update(_ pose: PoseFrame, now: TimeInterval) -> Bool {
        if pose.isStale {
            _ = jumper.update(pose, now: now)
            walker.reset()
            return false
        }
        let jumped = jumper.update(pose, now: now)
        if jumper.newFrame {
            walker.update(player: jumper.player, torso: jumper.torso, frameDT: jumper.frameDT, airborne: jumper.airborne)
        }
        return jumped
    }

    func reset() {
        jumper.reset()
        walker.reset()
    }
}

/// Judges one Freeze Dance freeze from fresh motion samples only. If too little of the freeze was
/// actually seen (tracking dropped out), the verdict is "not enough seen" so the game replays it
/// instead of awarding or withholding a star on a guess.
struct FreezeJudge {
    var stillThreshold: CGFloat = 0.45   // motion below this counts as frozen
    var successShare = 0.7               // share of observed time that must be still
    var minCoverage = 0.6                // share of the judged window that must be observed
    var maxSampleDuration = 0.1          // one sample never vouches for more than this long

    private(set) var observed: Double = 0
    private(set) var still: Double = 0

    enum Verdict: Equatable { case froze, wiggly, notEnoughSeen }

    mutating func reset() { observed = 0; still = 0 }

    /// Adds one fresh camera sample. Returns whether the player was still in it.
    @discardableResult
    mutating func addSample(motion: CGFloat, duration: Double) -> Bool {
        let d = min(max(duration, 0), maxSampleDuration)
        observed += d
        let isStill = motion < stillThreshold
        if isStill { still += d }
        return isStill
    }

    func verdict(judgedWindow: Double) -> Verdict {
        guard observed >= judgedWindow * minCoverage, observed > 0 else { return .notEnoughSeen }
        return still / observed >= successShare ? .froze : .wiggly
    }
}

/// Picks the two hands to steer with. Hands from the dedicated hand tracker are preferred; each
/// hand is given to the nearest person, and the pair is used only if both belong to the driver.
/// (Up close, the body tracker often sees just the head and shoulders, so "is the hand inside the
/// driver's body box" wrongly rejects hands held at chest height; nearest-person doesn't.)
/// Falls back to the driver's own wrists or elbows.
enum WheelHands {
    struct Pair {
        var a: CGPoint
        var b: CGPoint
        var fromHandTracker: Bool
    }

    static func pick(hands: [CGPoint], bodies: [Body], driver: Body?) -> Pair? {
        if hands.count >= 2 {
            let (h0, h1) = (hands[0], hands[1])
            let separation = PlayerTracker.distance(h0, h1)
            if separation > 0.04, belongToDriver([h0, h1], bodies: bodies, driver: driver) {
                return Pair(a: h0, b: h1, fromHandTracker: true)
            }
        }
        if let driver,
           let a = driver[.leftWrist] ?? driver[.leftElbow], let b = driver[.rightWrist] ?? driver[.rightElbow] {
            return Pair(a: a, b: b, fromHandTracker: false)
        }
        return nil
    }

    /// True if every hand's nearest person is the driver (or there's nobody else to confuse it with).
    static func belongToDriver(_ hands: [CGPoint], bodies: [Body], driver: Body?) -> Bool {
        guard let driver, bodies.count > 1 else { return true }
        let driverCenter = PlayerTracker.centroid(of: driver)
        guard let driverIndex = bodies.firstIndex(where: { PlayerTracker.distance(PlayerTracker.centroid(of: $0), driverCenter) < 0.0001 })
        else { return true }
        return hands.allSatisfy { owner(of: $0, among: bodies) == driverIndex }
    }

    /// Index of the person whose arm (wrist, elbow or shoulder) is closest to the point.
    static func owner(of point: CGPoint, among bodies: [Body]) -> Int? {
        let armJoints: [Joint] = [.leftWrist, .rightWrist, .leftElbow, .rightElbow, .leftShoulder, .rightShoulder]
        func distance(_ body: Body) -> CGFloat {
            let points = armJoints.compactMap { body[$0] }
            let candidates = points.isEmpty ? [PlayerTracker.centroid(of: body)] : points
            return candidates.map { PlayerTracker.distance($0, point) }.min() ?? .infinity
        }
        return bodies.indices.min { distance(bodies[$0]) < distance(bodies[$1]) }
    }
}
