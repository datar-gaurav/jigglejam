import SpriteKit
import AVFoundation
import AppKit

/// Shared plumbing for every game: pose input, coordinate mapping, speech and confetti.
class GameScene: SKScene {
    var frameProvider: (() -> PoseFrame)?

    let palette: [NSColor] = [.systemPink, .systemTeal, .systemYellow, .systemGreen, .systemPurple, .systemOrange, .systemBlue]
    private let speech = AVSpeechSynthesizer()

    /// When on, the game pauses with a "step back" warning if a player gets too close.
    var distanceWarningEnabled = true

    var currentPose: PoseFrame { frameProvider?() ?? PoseFrame() }

    private var lastUpdate: TimeInterval = 0
    private var closeTime: TimeInterval = 0
    private var farTime: TimeInterval = 0
    private var lastWarningSpeech: TimeInterval = 0
    private var clock: TimeInterval = 0
    private(set) var pausedForDistance = false
    private var warning: SKNode?

    // MARK: - Loop

    /// Subclasses put their game logic in `tick`, which doesn't run while paused for distance.
    override func update(_ currentTime: TimeInterval) {
        let dt = lastUpdate == 0 ? 1.0 / 60 : min(currentTime - lastUpdate, 1.0 / 20)
        lastUpdate = currentTime
        clock += dt
        let pose = currentPose
        updateDistance(pose, dt: dt)
        if !pausedForDistance { tick(dt: dt, pose: pose) }
    }

    func tick(dt: TimeInterval, pose: PoseFrame) {}

    /// Hook for games with extra state to pause, such as music.
    func distancePauseChanged(paused: Bool) {}

    // MARK: - Too close

    private func updateDistance(_ pose: PoseFrame, dt: TimeInterval) {
        if distanceWarningEnabled && pose.tooClose {
            closeTime += dt; farTime = 0
        } else {
            farTime += dt; closeTime = 0
        }
        if !pausedForDistance && closeTime > 0.5 {
            setPausedForDistance(true)
        } else if pausedForDistance && farTime > 1.0 {
            setPausedForDistance(false)
        }
        if pausedForDistance && clock - lastWarningSpeech > 6 {
            lastWarningSpeech = clock
            say(["Whoa, too close! Take a big step back!", "Back up, back up! I can't see your feet!"].randomElement()!)
        }
    }

    private func setPausedForDistance(_ paused: Bool) {
        pausedForDistance = paused
        for child in children where child !== warning { child.isPaused = paused }
        if paused {
            let node = makeWarning()
            warning = node
            addChild(node)
            node.alpha = 0
            node.run(.fadeIn(withDuration: 0.2))
        } else {
            warning?.run(.sequence([.fadeOut(withDuration: 0.2), .removeFromParent()]))
            warning = nil
            say("Perfect! Let's play!")
        }
        distancePauseChanged(paused: paused)
    }

    private func makeWarning() -> SKNode {
        let node = SKNode()
        node.zPosition = 100

        let dim = SKShapeNode(rect: CGRect(origin: .zero, size: size))
        dim.fillColor = NSColor.black.withAlphaComponent(0.6)
        dim.strokeColor = .clear
        node.addChild(dim)

        let title = makeLabel("✋ Too close!", size: 0.13)
        title.position = CGPoint(x: size.width / 2, y: size.height * 0.68)
        node.addChild(title)

        let subtitle = makeLabel("Take a big step back 👣", size: 0.07)
        subtitle.position = CGPoint(x: size.width / 2, y: size.height * 0.5)
        node.addChild(subtitle)

        // A kid shrinking into the distance = "move back".
        let kid = makeLabel("🧒", size: 0.16)
        kid.position = CGPoint(x: size.width / 2, y: size.height * 0.27)
        node.addChild(kid)
        kid.run(.repeatForever(.sequence([
            .group([.scale(to: 0.45, duration: 1.0), .fadeAlpha(to: 0.6, duration: 1.0)]),
            .wait(forDuration: 0.3),
            .group([.scale(to: 1, duration: 0), .fadeAlpha(to: 1, duration: 0)])
        ])))
        return node
    }

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
