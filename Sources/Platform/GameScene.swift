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
        let pose = raw.gated()
        let fresh = !pose.isStale
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
        let h = size.height

        let dim = SKShapeNode(rect: CGRect(origin: .zero, size: size))
        dim.fillColor = NSColor.black.withAlphaComponent(0.5)
        dim.strokeColor = .clear
        node.addChild(dim)

        let (titleText, subtitleText, icon, accent): (String, String, String, NSColor)
        switch reason {
        case .tooClose:
            (titleText, subtitleText, icon, accent) = ("Too close!", "Take a big step back 👣", "✋", .systemOrange)
        case .lookingForPlayer(let stalled):
            (titleText, subtitleText, icon, accent) = stalled
                ? ("Looking for you…", "The camera stopped. Check the iPhone is close and locked.", "📷", .systemBlue)
                : ("Looking for you…", "Stand where the camera can see you", "👀", .systemBlue)
        }

        let title = RoundedLabel(titleText, size: h * 0.1)
        let subtitle = RoundedLabel(subtitleText, size: h * 0.042, weight: .semibold)
        subtitle.fontColor = NSColor.white.withAlphaComponent(0.8)

        // Card, sized to fit its text.
        let textWidth = max(title.frame.width, subtitle.frame.width)
        let cardSize = CGSize(width: min(max(textWidth + h * 0.16, h * 0.9), size.width * 0.92), height: h * 0.5)
        let cardRect = CGRect(x: (size.width - cardSize.width) / 2, y: (h - cardSize.height) / 2 - h * 0.02,
                              width: cardSize.width, height: cardSize.height)
        let card = SKShapeNode(path: CGPath(roundedRect: cardRect, cornerWidth: h * 0.05, cornerHeight: h * 0.05, transform: nil))
        card.fillColor = NSColor(white: 0.08, alpha: 0.85)
        card.strokeColor = NSColor.white.withAlphaComponent(0.14)
        card.lineWidth = 2
        node.addChild(card)

        // Icon badge, half outside the top of the card
        let badgeRadius = h * 0.085
        let badgeCenter = CGPoint(x: size.width / 2, y: cardRect.maxY)
        let halo = SKShapeNode(circleOfRadius: badgeRadius * 1.35)
        halo.fillColor = accent.withAlphaComponent(0.3)
        halo.strokeColor = .clear
        halo.position = badgeCenter
        node.addChild(halo)
        let badge = SKShapeNode(circleOfRadius: badgeRadius)
        badge.fillColor = accent
        badge.strokeColor = NSColor.white.withAlphaComponent(0.5)
        badge.lineWidth = 3
        badge.position = badgeCenter
        node.addChild(badge)
        let iconLabel = RoundedLabel(icon, size: badgeRadius * 1.05)
        iconLabel.shadowed = false
        iconLabel.position = badgeCenter
        node.addChild(iconLabel)
        halo.run(.repeatForever(.sequence([.scale(to: 1.15, duration: 0.8), .scale(to: 1, duration: 0.8)])))

        title.position = CGPoint(x: size.width / 2, y: cardRect.midY + h * 0.03)
        node.addChild(title)
        subtitle.position = CGPoint(x: size.width / 2, y: cardRect.midY - h * 0.075)
        node.addChild(subtitle)

        if case .tooClose = reason {
            // A kid shrinking into the distance = "move back".
            let kid = RoundedLabel("🧒", size: h * 0.09)
            kid.position = CGPoint(x: size.width / 2, y: cardRect.minY + h * 0.07)
            node.addChild(kid)
            kid.run(.repeatForever(.sequence([
                .group([.scale(to: 0.5, duration: 1.0), .fadeAlpha(to: 0.5, duration: 1.0)]),
                .wait(forDuration: 0.3),
                .group([.scale(to: 1, duration: 0), .fadeAlpha(to: 1, duration: 0)])
            ])))
        } else {
            // Three dots "searching".
            for i in 0..<3 {
                let dot = SKShapeNode(circleOfRadius: h * 0.012)
                dot.fillColor = .white
                dot.strokeColor = .clear
                dot.position = CGPoint(x: size.width / 2 + CGFloat(i - 1) * h * 0.04, y: cardRect.minY + h * 0.07)
                dot.alpha = 0.3
                node.addChild(dot)
                dot.run(.sequence([.wait(forDuration: Double(i) * 0.2),
                                   .repeatForever(.sequence([.fadeAlpha(to: 1, duration: 0.3), .fadeAlpha(to: 0.3, duration: 0.3), .wait(forDuration: 0.3)]))]))
            }
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
        guard !Snapshot.isActive else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.45
        utterance.pitchMultiplier = 1.25
        speech.stopSpeaking(at: .word)
        speech.speak(utterance)
    }

    /// Rounded, shadowed text sized relative to the scene height. Also used for emoji sprites.
    func makeLabel(_ text: String, size relative: CGFloat) -> SKLabelNode {
        let label = RoundedLabel(text, size: size.height * relative)
        label.zPosition = 10
        return label
    }

    func confetti(count: Int = 50) {
        let unit = size.height * 0.016
        for i in 0..<count {
            let piece: SKShapeNode
            switch i % 3 {
            case 0: piece = SKShapeNode(rectOf: CGSize(width: unit, height: unit * 2), cornerRadius: unit * 0.3)
            case 1: piece = SKShapeNode(circleOfRadius: unit * 0.7)
            default: piece = SKShapeNode(rectOf: CGSize(width: unit * 2.4, height: unit * 0.7), cornerRadius: unit * 0.35)
            }
            piece.fillColor = palette.randomElement()!
            piece.strokeColor = .clear
            piece.position = CGPoint(x: .random(in: 0...size.width), y: size.height + 20)
            piece.zPosition = 80
            addChild(piece)
            let fall = TimeInterval.random(in: 1.8...3.2)
            let sway = SKAction.sequence([.moveBy(x: 30, y: 0, duration: 0.4), .moveBy(x: -30, y: 0, duration: 0.4)])
            piece.run(.sequence([
                .group([.moveBy(x: .random(in: -80...80), y: -size.height - 60, duration: fall),
                        .rotate(byAngle: .random(in: -8...8), duration: fall),
                        .repeat(sway, count: Int(fall / 0.8) + 1),
                        .sequence([.wait(forDuration: fall * 0.7), .fadeOut(withDuration: fall * 0.3)])]),
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
