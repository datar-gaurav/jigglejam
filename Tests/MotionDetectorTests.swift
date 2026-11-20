import XCTest
import CoreGraphics

/// Pose replay tests: synthetic players at 30 fps, driven through the real detectors.
/// Repeatable jitter, so every run sees exactly the same poses.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
var testRNG = SeededRNG(state: 42)

final class MotionDetectorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        testRNG = SeededRNG(state: 42)
    }

    // MARK: - Synthetic player

    /// A standing person. `scale` 1 ≈ a child filling part of the frame; bigger = taller/closer.
    struct Player {
        var x: CGFloat = 0.5
        var feet: CGFloat = 0.15     // ankle height in the frame when standing
        var scale: CGFloat = 1
        var hipDrop: CGFloat = 0     // squat: hips (and upper body) lower, feet stay down
        var lift: CGFloat = 0        // jump: whole body up, feet included
        var leftKnee: CGFloat = 0    // knee lifts while marching
        var rightKnee: CGFloat = 0
        var jitter: CGFloat = 0.004

        func body() -> Body {
            func n() -> CGFloat { .random(in: -jitter...jitter, using: &testRNG) }
            let s = scale
            let ankle = feet + lift
            let hip = ankle + 0.24 * s - hipDrop
            var b: Body = [:]
            b[.leftAnkle] = CGPoint(x: x - 0.03 * s + n(), y: ankle + leftKnee + n())
            b[.rightAnkle] = CGPoint(x: x + 0.03 * s + n(), y: ankle + rightKnee + n())
            b[.leftKnee] = CGPoint(x: x - 0.03 * s + n(), y: ankle + 0.12 * s + leftKnee + n())
            b[.rightKnee] = CGPoint(x: x + 0.03 * s + n(), y: ankle + 0.12 * s + rightKnee + n())
            b[.leftHip] = CGPoint(x: x - 0.03 * s + n(), y: hip + n())
            b[.rightHip] = CGPoint(x: x + 0.03 * s + n(), y: hip + n())
            b[.root] = CGPoint(x: x, y: hip)
            b[.neck] = CGPoint(x: x + n(), y: hip + 0.25 * s + n())
            b[.leftShoulder] = CGPoint(x: x - 0.06 * s, y: hip + 0.23 * s)
            b[.rightShoulder] = CGPoint(x: x + 0.06 * s, y: hip + 0.23 * s)
            return b
        }
    }

    struct Result { var jumps = 0; var paces: [CGFloat] = [] }

    /// Runs `seconds` of frames; `scene(t)` returns the bodies visible at time t (nil = no camera frame).
    @discardableResult
    func replay(_ seconds: Double, jumper: JumpDetector = JumpDetector(), walker: WalkDetector = WalkDetector(),
                start: Double = 0, _ scene: (Double) -> [Body]?) -> Result {
        var result = Result()
        var t = start
        while t < start + seconds {
            if let bodies = scene(t) {
                let frame = PoseFrame(bodies: bodies, timestamp: 1 + t, receivedAt: 1 + t)
                if jumper.update(frame, now: t) { result.jumps += 1 }
                walker.update(player: jumper.player, torso: jumper.torso, frameDT: jumper.frameDT, airborne: jumper.airborne)
                result.paces.append(walker.pace)
            }
            t += 1.0 / 30
        }
        return result
    }

    /// Hip/feet lift for a jump starting at `start`, lasting 0.4 s, peaking at `height`.
    func jumpLift(_ t: Double, start: Double, height: CGFloat = 0.09) -> CGFloat {
        let p = t - start
        guard p > 0, p < 0.4 else { return 0 }
        return CGFloat(sin(p / 0.4 * .pi)) * height
    }

    func average(_ xs: ArraySlice<CGFloat>) -> CGFloat { xs.isEmpty ? 0 : xs.reduce(0, +) / CGFloat(xs.count) }

    // MARK: - Jumping

    func testStandingStillIsNotAJumpOrAWalk() {
        let r = replay(6) { _ in [Player().body()] }
        XCTAssertEqual(r.jumps, 0)
        XCTAssertEqual(r.paces.max(), 0)
    }

    func testCountsRealJumps() {
        let r = replay(7) { t in
            var p = Player()
            p.lift = [1.5, 3.5, 5.5].map { jumpLift(t, start: $0) }.reduce(0, +)
            return [p.body()]
        }
        XCTAssertEqual(r.jumps, 3)
    }

    func testStandingUpFromASquatIsNotAJump() {
        let r = replay(6) { t in
            var p = Player()
            if t > 1, t < 3.5 { p.hipDrop = 0.1 }   // squat for 2.5 s, then stand up
            return [p.body()]
        }
        XCTAssertEqual(r.jumps, 0)
    }

    /// Review finding: a taller player stepping in after a tracking gap registered a jump.
    func testTallerPlayerAfterTrackingGapIsNotAJump() {
        for gap in [GapKind.noBodies, .noFrames] {
            let r = replay(6) { t in
                if t > 2, t < 2.6 { return gap == .noBodies ? [] : nil }
                var p = Player()
                if t >= 2.6 { p.scale = 1.6 }   // a grown-up: hips far higher than the child's
                return [p.body()]
            }
            XCTAssertEqual(r.jumps, 0, "gap kind \(gap)")
        }
    }

    enum GapKind { case noBodies, noFrames }

    func testPlayerSwapWithoutGapIsNotAJump() {
        let r = replay(6) { t in
            var p = Player()
            if t >= 3 { p = Player(x: 0.85, feet: 0.1, scale: 1.4) } // someone else, elsewhere, taller
            return [p.body()]
        }
        XCTAssertEqual(r.jumps, 0)
    }

    func testJumpsStillCountAfterRecalibrating() {
        let jumper = JumpDetector()
        replay(2, jumper: jumper) { _ in [Player().body()] }
        replay(0.6, jumper: jumper, start: 2) { _ in [] }                   // lost
        let r = replay(4, jumper: jumper, start: 2.6) { t in
            var p = Player(scale: 1.4)
            p.lift = jumpLift(t, start: 4.5, height: 0.12)
            return [p.body()]
        }
        XCTAssertEqual(r.jumps, 1)
    }

    // MARK: - Walking

    func testMarchingWalks() {
        let r = replay(6) { t in
            let s = CGFloat(sin(t * 2 * .pi))  // 2 steps per second
            var p = Player()
            p.leftKnee = max(s, 0) * 0.07
            p.rightKnee = max(-s, 0) * 0.07
            return [p.body()]
        }
        XCTAssertEqual(r.jumps, 0, "marching must never count as jumping")
        XCTAssertGreaterThan(average(r.paces.suffix(120)), 0.6)
    }

    func testSlowMarchingWalksSlowly() {
        let r = replay(8) { t in
            let s = CGFloat(sin(t * 1.1 * .pi))
            var p = Player()
            p.leftKnee = max(s, 0) * 0.05
            p.rightKnee = max(-s, 0) * 0.05
            return [p.body()]
        }
        let pace = average(r.paces.suffix(150))
        XCTAssertGreaterThan(pace, 0.2)
        XCTAssertLessThan(pace, 0.75)
    }

    /// Review finding: raising one knee once produced a walk pace of 0.88.
    func testOneKneeLiftIsNotWalking() {
        let r = replay(5) { t in
            var p = Player()
            if t > 1.5, t < 2.3 { p.leftKnee = 0.08 }
            return [p.body()]
        }
        XCTAssertEqual(r.paces.max(), 0)
    }

    func testSameKneeOverAndOverIsNotWalking() {
        let r = replay(6) { t in
            var p = Player()
            p.leftKnee = max(CGFloat(sin(t * 2 * .pi)), 0) * 0.08
            return [p.body()]
        }
        XCTAssertEqual(r.paces.max(), 0)
    }

    func testWalkingStopsShortlyAfterMarchingStops() {
        let r = replay(6) { t in
            var p = Player()
            if t < 3 {
                let s = CGFloat(sin(t * 2 * .pi))
                p.leftKnee = max(s, 0) * 0.07
                p.rightKnee = max(-s, 0) * 0.07
            }
            return [p.body()]
        }
        XCTAssertGreaterThan(average(r.paces[60..<90]), 0.5)  // walking at 2–3 s
        XCTAssertEqual(r.paces.suffix(30).max(), 0)            // stopped by 5–6 s
    }

    // MARK: - Freshness

    func testFramesGoStale() {
        let frame = PoseFrame(bodies: [Player().body()], timestamp: 1, receivedAt: 100)
        XCTAssertTrue(frame.isFresh(at: 100.2))
        XCTAssertFalse(frame.isFresh(at: 100.2 + PoseFrame.freshness))
        XCTAssertFalse(PoseFrame().isFresh(at: 5), "a frame that never arrived is never fresh")
        XCTAssertTrue(frame.withoutInput.bodies.isEmpty)
    }
}

extension MotionDetectorTests {
    /// Small hops (hips rise ~80% of a full jump) miss at first; after three
    /// near misses the detector eases and the same hops count.
    func testRepeatedNearMissesWidenTheJumpWindow() {
        let jumper = JumpDetector()
        let hopStarts = stride(from: 1.5, to: 9.5, by: 1.0).map { $0 }
        var easedAt: Double?
        var jumpsAfterEase = 0
        replay(10, jumper: jumper) { t in
            if jumper.easedJustNow { easedAt = t }
            var p = Player()
            p.lift = hopStarts.map { jumpLift(t, start: $0, height: 0.045) }.reduce(0, +)
            return [p.body()]
        }
        // Count again, separately, to see hops being accepted once eased.
        let r = replay(4, jumper: jumper, start: 10) { t in
            var p = Player()
            p.lift = [11.0, 12.0, 13.0].map { jumpLift(t, start: $0, height: 0.045) }.reduce(0, +)
            return [p.body()]
        }
        jumpsAfterEase = r.jumps
        XCTAssertTrue(jumper.eased)
        XCTAssertNotNil(easedAt)
        XCTAssertEqual(jumpsAfterEase, 3)
    }

    func testSquatsDoNotCountAsJumpsEvenWhenEased() {
        let jumper = JumpDetector()
        jumper.ease()
        let r = replay(10, jumper: jumper) { t in
            var p = Player()
            let phase = t.truncatingRemainder(dividingBy: 2.5)
            if t > 1, phase > 0.5, phase < 1.5 { p.hipDrop = 0.1 }
            return [p.body()]
        }
        XCTAssertEqual(r.jumps, 0)
    }
}

// MARK: - Tracking loss (game-loop level)

extension MotionDetectorTests {
    /// Review finding: during a camera stall Fox Trail kept walking at pace 0.85 for 1.4 s, because
    /// the stale stand-in frame kept the old timestamp. This drives `Locomotion` exactly like the
    /// game loop does: 60 updates per second, each with the latest camera frame gated by freshness.
    func testCameraStallStopsWalkingAsSoonAsTheFrameIsStale() {
        let moves = Locomotion()
        var latest = PoseFrame()
        var staleSince: Double?
        var pacesWhileStale: [CGFloat] = []
        var paceBeforeStall: CGFloat = 0

        var t = 0.0
        var nextCameraFrame = 0.0
        while t < 6 {
            let stalled = t >= 3 && t < 5           // camera sends nothing from 3 s to 5 s
            if !stalled, t >= nextCameraFrame {
                let s = CGFloat(sin(t * 2 * .pi))
                var p = Player()
                p.leftKnee = max(s, 0) * 0.07
                p.rightKnee = max(-s, 0) * 0.07
                latest = PoseFrame(bodies: [p.body()], timestamp: 1 + t, receivedAt: 1 + t)
                nextCameraFrame += 1.0 / 30
            }
            let gated = latest.gated(at: 1 + t)
            _ = moves.update(gated, now: t)
            if t > 2.8, t < 3 { paceBeforeStall = max(paceBeforeStall, moves.pace) }
            if gated.isStale {
                staleSince = staleSince ?? t
                pacesWhileStale.append(moves.pace)
            }
            t += 1.0 / 60
        }

        XCTAssertGreaterThan(paceBeforeStall, 0.6, "should be walking before the stall")
        XCTAssertNotNil(staleSince)
        XCTAssertLessThanOrEqual(staleSince! - 3, PoseFrame.freshness + 0.05, "frame goes stale within the freshness window")
        XCTAssertEqual(pacesWhileStale.max(), 0, "no walking at all once the frame is stale")
    }

    func testWalkingResumesAfterAStall() {
        let moves = Locomotion()
        var paces: [CGFloat] = []
        var t = 0.0
        while t < 7 {
            let frame: PoseFrame
            if t >= 2 && t < 3 {
                frame = PoseFrame(timestamp: 1 + 1.99, receivedAt: 1 + 1.99).gated(at: 1 + t)
            } else {
                let s = CGFloat(sin(t * 2 * .pi))
                var p = Player()
                p.leftKnee = max(s, 0) * 0.07
                p.rightKnee = max(-s, 0) * 0.07
                frame = PoseFrame(bodies: [p.body()], timestamp: 1 + t, receivedAt: 1 + t)
            }
            _ = moves.update(frame, now: t)
            paces.append(moves.pace)
            t += 1.0 / 30
        }
        XCTAssertGreaterThan(average(paces.suffix(60)), 0.6, "walks again once frames return")
    }

    func testStaleFramesNeverCountAsJumps() {
        let moves = Locomotion()
        var jumps = 0
        var t = 0.0
        while t < 4 {
            var p = Player()
            p.lift = jumpLift(t, start: 2.5, height: 0.12)
            // Camera froze on a mid-jump frame at 2.6 s: games keep receiving that same frame.
            let stamp = t < 2.6 ? t : 2.6
            let frame = PoseFrame(bodies: [p.body()], timestamp: 1 + stamp, receivedAt: 1 + stamp).gated(at: 1 + t)
            if moves.update(frame, now: t) { jumps += 1 }
            t += 1.0 / 60
        }
        XCTAssertLessThanOrEqual(jumps, 1)
    }
}

// MARK: - Freeze Dance judging

extension MotionDetectorTests {
    func testFreezeJudgeAwardsAStillFreeze() {
        var judge = FreezeJudge()
        for _ in 0..<80 { judge.addSample(motion: 0.1, duration: 1.0 / 30) }   // 2.7 s of 2.7 s, still
        XCTAssertEqual(judge.verdict(judgedWindow: 2.7), .froze)
    }

    func testFreezeJudgeSpotsWiggles() {
        var judge = FreezeJudge()
        for i in 0..<80 { judge.addSample(motion: i % 2 == 0 ? 1.0 : 0.1, duration: 1.0 / 30) }
        XCTAssertEqual(judge.verdict(judgedWindow: 2.7), .wiggly)
    }

    /// Review finding: a star could be awarded after seeing only a fraction of the freeze.
    func testFreezeJudgeWontScoreWhatItBarelySaw() {
        var judge = FreezeJudge()
        for _ in 0..<15 { judge.addSample(motion: 0.1, duration: 1.0 / 30) }   // only 0.5 s seen
        XCTAssertEqual(judge.verdict(judgedWindow: 2.7), .notEnoughSeen)
    }

    func testOneSampleAfterAGapDoesNotVouchForTheGap() {
        var judge = FreezeJudge()
        judge.addSample(motion: 0.1, duration: 2.5)   // first frame after a long dropout
        XCTAssertEqual(judge.verdict(judgedWindow: 2.7), .notEnoughSeen)
    }
}

// MARK: - Vroom Vroom hand selection

extension MotionDetectorTests {
    /// Up close, only the head and shoulders are tracked.
    private func closeUpDriver(x: CGFloat = 0.5) -> Body {
        [.nose: CGPoint(x: x, y: 0.78), .leftEye: CGPoint(x: x - 0.03, y: 0.8), .rightEye: CGPoint(x: x + 0.03, y: 0.8),
         .leftEar: CGPoint(x: x - 0.06, y: 0.78), .rightEar: CGPoint(x: x + 0.06, y: 0.78), .neck: CGPoint(x: x, y: 0.62),
         .leftShoulder: CGPoint(x: x - 0.14, y: 0.6), .rightShoulder: CGPoint(x: x + 0.14, y: 0.6)]
    }

    /// Regression: hands holding the plate at chest height were rejected because they fell outside
    /// a close-up driver's head-and-shoulders box, so the car couldn't steer.
    func testCloseUpDriverHandsAtChestHeightAreUsed() {
        let driver = closeUpDriver()
        let hands = [CGPoint(x: 0.36, y: 0.3), CGPoint(x: 0.64, y: 0.24)] // plate held low, tilted
        let pair = WheelHands.pick(hands: hands, bodies: [driver], driver: driver)
        XCTAssertNotNil(pair)
        XCTAssertEqual(pair?.fromHandTracker, true)
    }

    func testHandsWithNoTrackedBodyAreUsed() {
        let hands = [CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.6, y: 0.5)]
        XCTAssertNotNil(WheelHands.pick(hands: hands, bodies: [], driver: nil))
    }

    func testAnotherPersonsHandIsNotPairedWithTheDriver() {
        let driver = closeUpDriver(x: 0.35)
        var other = closeUpDriver(x: 0.8)
        other[.rightWrist] = CGPoint(x: 0.9, y: 0.5)
        let hands = [CGPoint(x: 0.3, y: 0.45), CGPoint(x: 0.9, y: 0.5)] // driver's hand + the other person's
        let pair = WheelHands.pick(hands: hands, bodies: [driver, other], driver: driver)
        XCTAssertFalse(pair?.fromHandTracker ?? false, "mixed pair must not steer")
    }

    func testDriversHandsAreUsedEvenWithSomeoneElseInView() {
        let driver = closeUpDriver(x: 0.35)
        let other = closeUpDriver(x: 0.85)
        let hands = [CGPoint(x: 0.25, y: 0.35), CGPoint(x: 0.45, y: 0.32)]
        XCTAssertEqual(WheelHands.pick(hands: hands, bodies: [driver, other], driver: driver)?.fromHandTracker, true)
    }
}
