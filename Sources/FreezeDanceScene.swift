import SpriteKit
import AppKit

/// Freeze Dance: dance while the music plays, freeze like a statue when it stops.
/// Gentle for little kids: a wobbly freeze just means "let's try again", never "you're out".
final class FreezeDanceScene: GameScene {
    private enum Phase {
        case intro(until: TimeInterval)
        case dancing(until: TimeInterval)
        case freezing(start: TimeInterval, until: TimeInterval)
        case result(until: TimeInterval)
    }

    // Tuning. Motion is average joint speed in camera-frame units (0...1) per second, smoothed.
    private let stillThreshold: CGFloat = 0.45   // below this counts as frozen
    private let reactionGrace: TimeInterval = 0.8 // time to stop after the music stops
    private let freezeLength: TimeInterval = 3.5
    private let freezeSuccessShare = 0.7          // share of judged time that must be still

    private let music = DanceMusic()
    private var phase: Phase = .intro(until: 0)
    private var now: TimeInterval = 0

    private var motion: CGFloat = 0
    private var previousBodies: [Body] = []
    private var previousTimestamp: Double = 0
    private var judgedTime: TimeInterval = 0
    private var stillTime: TimeInterval = 0
    private var lowMotionTime: TimeInterval = 0
    private var lastNudge: TimeInterval = 0
    private var lastSparkle: TimeInterval = 0

    private var stars = 0
    private lazy var scoreLabel = makeLabel("⭐️ 0", size: 0.08)
    private lazy var bigLabel = makeLabel("", size: 0.16)
    private lazy var statusLabel = makeLabel("", size: 0.07)
    private lazy var hintLabel = makeLabel("Come stand in front of the camera! 👋", size: 0.06)
    private let iceOverlay = SKShapeNode()

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        iceOverlay.fillColor = NSColor(calibratedRed: 0.55, green: 0.85, blue: 1, alpha: 1)
        iceOverlay.strokeColor = .clear
        iceOverlay.alpha = 0
        iceOverlay.zPosition = 3
        hintLabel.alpha = 0
        [iceOverlay, scoreLabel, bigLabel, statusLabel, hintLabel].forEach(addChild)
        layoutHUD()
    }

    override func didChangeSize(_ oldSize: CGSize) { layoutHUD() }

    private func layoutHUD() {
        iceOverlay.path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        for (label, rel) in [(scoreLabel, 0.08), (bigLabel, 0.16), (statusLabel, 0.07), (hintLabel, 0.06)] {
            label.fontSize = size.height * rel
        }
        scoreLabel.position = CGPoint(x: size.width / 2, y: size.height * 0.88)
        bigLabel.position = CGPoint(x: size.width / 2, y: size.height * 0.62)
        statusLabel.position = CGPoint(x: size.width / 2, y: size.height * 0.45)
        hintLabel.position = CGPoint(x: size.width / 2, y: size.height * 0.3)
    }

    override func trackingDidResume() {
        previousBodies = []
        previousTimestamp = 0
        motion = 0
        // Don't judge a freeze that was interrupted; just start dancing again.
        switch phase {
        case .freezing, .result: startDancing()
        default: break
        }
    }

    override func pauseChanged(paused: Bool) {
        if paused {
            music.stop()
        } else if case .dancing = phase {
            music.play()
        }
    }

    override func tearDown() {
        music.shutdown()
        super.tearDown()
    }

    // MARK: - Loop

    override func tick(dt: TimeInterval, pose: PoseFrame) {
        now += dt
        if case .intro(until: 0) = phase { startIntro() }

        updateMotion(pose)
        let someone = pose.peopleCount > 0
        hintLabel.alpha += ((someone ? 0 : 1) - hintLabel.alpha) * 0.1

        switch phase {
        case .intro(let until):
            if now >= until { startDancing() }

        case .dancing(let until):
            sparkle(pose)
            lowMotionTime = motion < stillThreshold ? lowMotionTime + dt : 0
            if someone, lowMotionTime > 3, now - lastNudge > 7 {
                lastNudge = now
                say(["Dance! Shake your body!", "Wiggle wiggle!", "Jump and dance!"].randomElement()!)
            }
            // Only freeze when someone is actually playing.
            if now >= until, someone { startFreeze() }

        case .freezing(let start, let until):
            if now - start >= reactionGrace, someone {
                judgedTime += dt
                let still = motion < stillThreshold
                if still { stillTime += dt }
                statusLabel.text = still ? "🧊 So still!" : "😄 Wiggly!"
                statusLabel.fontColor = still ? .white : .systemYellow
            }
            if now >= until { finishFreeze() }

        case .result(let until):
            if now >= until { startDancing() }
        }
    }

    // MARK: - Phases

    private func startIntro() {
        phase = .intro(until: now + 4)
        show("🎵 Freeze Dance!")
        say("Freeze Dance! Dance when the music plays. Freeze when it stops!")
    }

    private func startDancing() {
        phase = .dancing(until: now + .random(in: 5...10))
        lowMotionTime = 0
        lastNudge = now
        music.play(newSong: Bool.random())
        iceOverlay.run(.fadeAlpha(to: 0, duration: 0.3))
        statusLabel.text = ""
        show("💃 DANCE! 🕺")
        bigLabel.run(.repeatForever(.sequence([.scale(to: 1.1, duration: 0.24), .scale(to: 1, duration: 0.24)])), withKey: "bounce")
    }

    private func startFreeze() {
        phase = .freezing(start: now, until: now + freezeLength)
        judgedTime = 0
        stillTime = 0
        music.stop()
        say("Freeze!")
        bigLabel.removeAction(forKey: "bounce")
        show("🥶 FREEZE!")
        statusLabel.text = ""
        iceOverlay.run(.fadeAlpha(to: 0.3, duration: 0.2))
        snow()
    }

    private func finishFreeze() {
        phase = .result(until: now + 2.2)
        let froze = judgedTime > 0 && stillTime / judgedTime >= freezeSuccessShare
        if froze {
            stars += 1
            scoreLabel.text = "⭐️ \(stars)"
            scoreLabel.run(.sequence([.scale(to: 1.3, duration: 0.1), .scale(to: 1, duration: 0.2)]))
            show("⭐️ Great freeze!")
            statusLabel.text = ""
            say(["Great freeze!", "You're a statue!", "Wow, so still!", "Super freeze!"].randomElement()!)
            confetti()
        } else {
            show("😄 So wiggly!")
            statusLabel.text = "Let's try again!"
            statusLabel.fontColor = .white
            say("So wiggly! Let's try again!")
        }
    }

    private func show(_ text: String) {
        bigLabel.text = text
        bigLabel.setScale(0.5)
        bigLabel.run(.scale(to: 1, duration: 0.2))
    }

    // MARK: - Motion

    /// Average speed of every joint tracked in both frames, for the wiggliest person.
    private func updateMotion(_ pose: PoseFrame) {
        guard pose.timestamp != previousTimestamp else { return } // no new camera frame yet
        let frameDT = pose.timestamp - previousTimestamp
        defer { previousBodies = pose.bodies; previousTimestamp = pose.timestamp }
        guard previousTimestamp > 0, frameDT > 0, frameDT < 0.5 else { return }

        var fastest: CGFloat = 0
        for body in pose.bodies {
            guard let previous = nearest(to: body, in: previousBodies) else { continue }
            var total: CGFloat = 0, count: CGFloat = 0
            for (joint, p) in body {
                guard let q = previous[joint] else { continue }
                total += hypot(p.x - q.x, p.y - q.y)
                count += 1
            }
            if count >= 4 { fastest = max(fastest, total / count / CGFloat(frameDT)) }
        }
        motion += (fastest - motion) * 0.35
    }

    private func center(_ body: Body) -> CGPoint? {
        guard !body.isEmpty else { return nil }
        let sum = body.values.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(body.count), y: sum.y / CGFloat(body.count))
    }

    private func nearest(to body: Body, in candidates: [Body]) -> Body? {
        guard let c = center(body) else { return nil }
        return candidates.min { a, b in
            guard let ca = center(a) else { return false }
            guard let cb = center(b) else { return true }
            return hypot(ca.x - c.x, ca.y - c.y) < hypot(cb.x - c.x, cb.y - c.y)
        }
    }

    // MARK: - Effects

    /// Sparkles fly off the hands while dancing.
    private func sparkle(_ pose: PoseFrame) {
        guard motion > stillThreshold * 1.5, now - lastSparkle > 0.08 else { return }
        lastSparkle = now
        let r = size.height * 0.018
        for popper in pose.poppers where popper.kind == .hand {
            let star = SKLabelNode(text: ["✨", "⭐️", "🎵", "💖"].randomElement()!)
            star.fontSize = r * 3
            star.position = scenePoint(popper.point, imageSize: pose.imageSize)
            star.zPosition = 4
            addChild(star)
            star.run(.sequence([
                .group([.moveBy(x: .random(in: -60...60), y: .random(in: 40...120), duration: 0.7),
                        .fadeOut(withDuration: 0.7),
                        .rotate(byAngle: .random(in: -2...2), duration: 0.7)]),
                .removeFromParent()
            ]))
        }
    }

    private func snow() {
        for _ in 0..<30 {
            let flake = SKLabelNode(text: "❄️")
            flake.fontSize = size.height * .random(in: 0.03...0.06)
            flake.position = CGPoint(x: .random(in: 0...size.width), y: size.height + 30)
            flake.zPosition = 4
            addChild(flake)
            let fall = TimeInterval.random(in: 2.5...4)
            flake.run(.sequence([
                .wait(forDuration: .random(in: 0...0.8)),
                .group([.moveBy(x: .random(in: -60...60), y: -size.height - 80, duration: fall),
                        .rotate(byAngle: .random(in: -3...3), duration: fall)]),
                .removeFromParent()
            ]))
        }
    }
}
