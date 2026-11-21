import XCTest
import CoreGraphics

/// Garden Guard maps hands relative to the body so every square is reachable from one spot.
final class ReachMapperTests: XCTestCase {
    private let image = CGSize(width: 1280, height: 720)

    /// A standing child: torso 0.25 of the frame tall, centered at `x`, scaled by `scale`
    /// (smaller = further back).
    private func child(x: CGFloat = 0.5, scale: CGFloat = 1, leftHand: CGPoint, rightHand: CGPoint) -> Body {
        func p(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: x + dx * scale, y: 0.2 + dy * scale) }
        return [
            .neck: p(0, 0.25), .root: p(0, 0),
            .leftWrist: p(leftHand.x, leftHand.y), .rightWrist: p(rightHand.x, rightHand.y),
        ]
    }

    func testHandsHangingDownLandAtBottom() {
        let hands = ReachMapper.hands(of: child(leftHand: CGPoint(x: -0.05, y: -0.02), rightHand: CGPoint(x: 0.05, y: -0.02)),
                                      imageSize: image)
        XCTAssertEqual(hands.count, 2)
        for h in hands { XCTAssertLessThan(h.y, 0.15) }
    }

    func testHandsStretchedUpReachTop() {
        let hands = ReachMapper.hands(of: child(leftHand: CGPoint(x: -0.04, y: 0.55), rightHand: CGPoint(x: 0.04, y: 0.55)),
                                      imageSize: image)
        for h in hands { XCTAssertGreaterThan(h.y, 0.85) }
    }

    func testArmsOutWideReachTheSides() {
        // Arms out at shoulder height: about one torso length (0.25 of 720 px = 180 px) sideways.
        let reach = 0.25 * image.height / image.width * 1.3
        let hands = ReachMapper.hands(of: child(leftHand: CGPoint(x: -reach, y: 0.22), rightHand: CGPoint(x: reach, y: 0.22)),
                                      imageSize: image)
        XCTAssertLessThan(hands[0].x, 0.05)
        XCTAssertGreaterThan(hands[1].x, 0.95)
    }

    func testSamePoseMapsTheSameAnywhereInFrame() {
        let l = CGPoint(x: -0.08, y: 0.3), r = CGPoint(x: 0.1, y: 0.15)
        let near = ReachMapper.hands(of: child(x: 0.3, leftHand: l, rightHand: r), imageSize: image)
        let far = ReachMapper.hands(of: child(x: 0.7, scale: 0.6, leftHand: l, rightHand: r), imageSize: image)
        for (a, b) in zip(near, far) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.001)
            XCTAssertEqual(a.y, b.y, accuracy: 0.001)
        }
    }

    func testNoTorsoNoHands() {
        let body: Body = [.leftWrist: CGPoint(x: 0.4, y: 0.5)]
        XCTAssertTrue(ReachMapper.hands(of: body, imageSize: image).isEmpty)
    }
}
