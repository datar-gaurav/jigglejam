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

    /// Games that need feet in view get the too-close warning; hands-only games opt out.
    var needsFullBody: Bool { true }

    /// Games that steer with hands turn on the dedicated hand tracker.
    var wantsHandTracking: Bool { false }

    /// Short live readout for the tracking window (e.g. the steering value).
    var debugText: String { "" }

    var currentPose: PoseFrame { frameProvider?() ?? PoseFrame() }

    /// Whether this frame has someone to play with. Hands-only games also accept just hands.
    func hasPlayer(_ pose: PoseFrame) -> Bool { !pose.bodies.isEmpty }

    enum PauseReason: Equatable {
        case tooClose
        case lookingForPlayer(cameraStalled: Bool)
    }

    private var lastUpdate: TimeInterval = 0
    private var closeTime: TimeInterval = 0
    private var farTime: TimeInterval = 0
    private var tooCloseActive = false
    private var missingTime: TimeInterval = 0
    private var lastPauseSpeech: TimeInterval = 0
    private var clock: TimeInterval = 0
    private(set) var pauseReason: PauseReason?
    private var overlay: SKNode?

    /// How long nobody (or no fresh camera frame) can be seen before the game pauses.
    private let lookingGrace: TimeInterval = 1.5

    // MARK: - Loop

    /// Subclasses put their game logic in `tick`, which doesn't run while paused.
    /// Stale camera frames never reach `tick` as input: the game sees an empty pose instead.
    override func update(_ currentTime: TimeInterval) {
        let dt = lastUpdate == 0 ? 1.0 / 60 : min(currentTime - lastUpdate, 1.0 / 20)
        lastUpdate = currentTime
        clock += dt

        let raw = currentPose
        let fresh = raw.isFresh()
        let pose = fresh ? raw : raw.withoutInput
        updatePause(pose, fresh: fresh, dt: dt)
        if pauseReason == nil { tick(dt: dt, pose: pose) }
    }

    func tick(dt: TimeInterval, pose: PoseFrame) {}

    /// Hook for games with extra state to pause, such as music.
    func pauseChanged(paused: Bool) {}

    /// Called when play resumes after a pause: tracking may have changed (another player, a gap),
    /// so games should reset their motion detectors and anything mid-move.
    func trackingDidResume() {}

    // MARK: - Pausing (too close / looking for the player)

    private func updatePause(_ pose: PoseFrame, fresh: Bool, dt: TimeInterval) {
        if distanceWarningEnabled && needsFullBody && pose.tooClose {
            closeTime += dt; farTime = 0
        } else {
            farTime += dt; closeTime = 0
        }
        if !tooCloseActive && closeTime > 0.5 { tooCloseActive = true }
        if tooCloseActive && farTime > 1.0 { tooCloseActive = false }

        let seen = fresh && hasPlayer(pose)
        missingTime = seen ? 0 : missingTime + dt

        let wanted: PauseReason?
        if missingTime > lookingGrace {
            wanted = .lookingForPlayer(cameraStalled: !fresh)
        } else if tooCloseActive {
            wanted = .tooClose
        } else if case .lookingForPlayer = pauseReason, missingTime > 0 {
            wanted = pauseReason // need a steady view before resuming
        } else {
            wanted = nil
        }
        if wanted != pauseReason { setPause(wanted) }

        if let reason = pauseReason, clock - lastPauseSpeech > 7 {
            lastPauseSpeech = clock
            switch reason {
            case .tooClose:
                say(["Whoa, too close! Take a big step back!", "Back up, back up! I can't see your feet!"].randomElement()!)
            case .lookingForPlayer:
                say(["Where did you go? Come and play!", "I'm looking for you! Stand in front of the camera."].randomElement()!)
            }
        }
    }

    private func setPause(_ reason: PauseReason?) {
        let wasPaused = pauseReason != nil
        pauseReason = reason
        for child in children where child !== overlay { child.isPaused = reason != nil }

        overlay?.run(.sequence([.fadeOut(withDuration: 0.2), .removeFromParent()]))
        overlay = nil
        if let reason {
            let node = makeOverlay(for: reason)
            overlay = node
            addChild(node)
            node.alpha = 0
            node.run(.fadeIn(withDuration: 0.2))
            lastPauseSpeech = clock - 6 // speak about a second after pausing, not instantly
        } else if wasPaused {
            say(["There you are! Let's play!", "Perfect! Let's play!"].randomElement()!)
            trackingDidResume()
        }
        if wasPaused != (reason != nil) { pauseChanged(paused: reason != nil) }
    }

    private func makeOverlay(for reason: PauseReason) -> SKNode {
        let node = SKNode()
        node.zPosition = 100

        let dim = SKShapeNode(rect: CGRect(origin: .zero, size: size))
        dim.fillColor = NSColor.black.withAlphaComponent(0.6)
        dim.strokeColor = .clear
        node.addChild(dim)

        let (titleText, subtitleText, icon): (String, String, String)
        switch reason {
        case .tooClose:
            (titleText, subtitleText, icon) = ("✋ Too close!", "Take a big step back 👣", "🧒")
        case .lookingForPlayer(let stalled):
            (titleText, subtitleText, icon) = stalled
                ? ("👀 Looking for you…", "The camera stopped. Check the iPhone is close and locked.", "📷")
                : ("👀 Looking for you…", "Stand where the camera can see you", "🧒")
        }

        let title = makeLabel(titleText, size: 0.13)
        title.position = CGPoint(x: size.width / 2, y: size.height * 0.68)
        node.addChild(title)

        let subtitle = makeLabel(subtitleText, size: 0.06)
        subtitle.position = CGPoint(x: size.width / 2, y: size.height * 0.5)
        node.addChild(subtitle)

        let figure = makeLabel(icon, size: 0.16)
        figure.position = CGPoint(x: size.width / 2, y: size.height * 0.27)
        node.addChild(figure)
        if case .tooClose = reason {
            // A kid shrinking into the distance = "move back".
            figure.run(.repeatForever(.sequence([
                .group([.scale(to: 0.45, duration: 1.0), .fadeAlpha(to: 0.6, duration: 1.0)]),
                .wait(forDuration: 0.3),
                .group([.scale(to: 1, duration: 0), .fadeAlpha(to: 1, duration: 0)])
            ])))
        } else {
            figure.run(.repeatForever(.sequence([.moveBy(x: -30, y: 0, duration: 0.6), .moveBy(x: 30, y: 0, duration: 0.6)])))
        }
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
