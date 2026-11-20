import XCTest
import CoreGraphics

/// Pose replay tests: synthetic players at 30 fps, driven through the real detectors.
final class MotionDetectorTests: XCTestCase {

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
            func n() -> CGFloat { .random(in: -jitter...jitter) }
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
