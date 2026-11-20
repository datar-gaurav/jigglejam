import CoreGraphics
import Foundation
import Vision

/// A body part that can pop things in a game.
struct Popper {
    enum Kind { case hand, foot }
    var kind: Kind
    /// Normalized image coordinates (0...1), already mirrored, origin bottom-left.
    var point: CGPoint
}

typealias Joint = VNHumanBodyPoseObservation.JointName

/// All confidently-tracked joints of one person (normalized, mirrored, origin bottom-left).
typealias Body = [Joint: CGPoint]

/// Monotonic clock shared by the camera and the games (seconds).
func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

/// The latest body-tracking result, read by games every frame.
struct PoseFrame {
    var poppers: [Popper] = []
    var bodies: [Body] = []
    var peopleCount = 0
    /// Someone is so close to the camera that their whole body no longer fits.
    var tooClose = false
    /// Hand centers from the dedicated hand tracker (only filled when hand tracking is on).
    /// Normalized, mirrored, origin bottom-left. Works up close and with the body hidden.
    var hands: [CGPoint] = []
    var imageSize = CGSize(width: 1280, height: 720)
    /// Camera timestamp in seconds; changes only when a new camera frame was analysed.
    var timestamp: Double = 0
    /// `uptime()` when this frame was produced; 0 = never.
    var receivedAt: Double = 0
    /// Average brightness (0...1) of the middle of the picture; only measured during the latency test.
    var brightness: Double?

    /// Frames older than this are not trusted as live input (camera stalled or disconnected).
    static let freshness: Double = 0.5

    func isFresh(at now: Double = uptime()) -> Bool {
        receivedAt > 0 && now - receivedAt < Self.freshness
    }

    /// The same frame with all player input removed, for when it can't be trusted.
    var withoutInput: PoseFrame {
        PoseFrame(imageSize: imageSize, timestamp: timestamp, receivedAt: receivedAt, brightness: brightness)
    }
}
