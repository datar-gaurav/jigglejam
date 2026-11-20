import SpriteKit
import AVFoundation
import AppKit

/// Shared plumbing for every game: pose input, coordinate mapping, speech and confetti.
class GameScene: SKScene {
    var frameProvider: (() -> PoseFrame)?

    let palette: [NSColor] = [.systemPink, .systemTeal, .systemYellow, .systemGreen, .systemPurple, .systemOrange, .systemBlue]
    private let speech = AVSpeechSynthesizer()

    var currentPose: PoseFrame { frameProvider?() ?? PoseFrame() }

    /// Maps a normalized camera point to the scene, matching the preview's aspect-fill crop.
    func scenePoint(_ p: CGPoint, imageSize: CGSize) -> CGPoint {
        let scale = max(size.width / imageSize.width, size.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGPoint(x: (size.width - w) / 2 + p.x * w, y: (size.height - h) / 2 + p.y * h)
    }

    func say(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.45
        utterance.pitchMultiplier = 1.25
        speech.stopSpeaking(at: .word)
        speech.speak(utterance)
    }

    func makeLabel(_ text: String, size relative: CGFloat) -> SKLabelNode {
        let label = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        label.text = text
        label.fontColor = .white
        label.fontSize = size.height * relative
        label.verticalAlignmentMode = .center
        label.zPosition = 10
        return label
    }

    func confetti(count: Int = 50) {
        for _ in 0..<count {
            let piece = SKShapeNode(rectOf: CGSize(width: size.height * 0.015, height: size.height * 0.03), cornerRadius: 2)
            piece.fillColor = palette.randomElement()!
            piece.strokeColor = .clear
            piece.position = CGPoint(x: .random(in: 0...size.width), y: size.height + 20)
            piece.zPosition = 8
            addChild(piece)
            let fall = TimeInterval.random(in: 1.8...3.2)
            piece.run(.sequence([
                .group([.moveBy(x: .random(in: -80...80), y: -size.height - 60, duration: fall),
                        .rotate(byAngle: .random(in: -8...8), duration: fall)]),
                .removeFromParent()
            ]))
        }
    }

    /// Called when leaving the game: silence everything.
    func tearDown() {
        speech.stopSpeaking(at: .immediate)
        removeAllActions()
        isPaused = true
    }
}
