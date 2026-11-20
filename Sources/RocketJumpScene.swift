import SpriteKit
import AppKit

/// Rocket Jump: every jump pushes the rocket one step closer to the Moon.
/// No timing or obstacles: each jump counts, the game counts out loud, and arriving is a party.
final class RocketJumpScene: GameScene {
    // Jump sensitivity lives in JumpDetector (MotionDetectors.swift).
    private let jumper = JumpDetector()
    private let jumpsPerTrip = 10
    private let destinations: [(emoji: String, name: String)] = [("🌙", "the Moon"), ("🪐", "Saturn"), ("⭐️", "the stars")]

    private var now: TimeInterval = 0

    // Game state
    private var jumps = 0
    private var totalJumps = 0
    private var trip = 0
    private var celebratingUntil: TimeInterval = 0
    private var lastNudge: TimeInterval = 0
    private var sounds: [NSSound] = []

    private lazy var totalLabel = makeLabel("🦘 0", size: 0.08)
    private lazy var promptLabel = makeLabel("JUMP! 🦘", size: 0.14)
    private lazy var rocket = makeLabel("🚀", size: 0.11)
    private lazy var destination = makeLabel("", size: 0.12)
    private let track = SKShapeNode()
    private var steps: [SKShapeNode] = []

    private var trackX: CGFloat { size.width * 0.87 }
    private var trackBottom: CGFloat { size.height * 0.12 }
    private var trackTop: CGFloat { size.height * 0.74 }

    override func trackingDidResume() { jumper.reset() }

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        rocket.zRotation = .pi / 4 // the emoji points up-right; make it point straight up
        rocket.zPosition = 6
        track.strokeColor = NSColor.white.withAlphaComponent(0.35)
        track.lineWidth = 6
        track.zPosition = 2
        [track, rocket, destination, totalLabel, promptLabel].forEach(addChild)
        promptLabel.run(.repeatForever(.sequence([.scale(to: 1.12, duration: 0.3), .scale(to: 1, duration: 0.3)])))
        layoutHUD()
        say("Rocket Jump! Jump to fly the rocket to the Moon!")
    }

    override func didChangeSize(_ oldSize: CGSize) { layoutHUD() }

    private func layoutHUD() {
        for (label, rel) in [(totalLabel, 0.08), (promptLabel, 0.14), (rocket, 0.11), (destination, 0.12)] {
            label.fontSize = size.height * rel
        }
        totalLabel.position = CGPoint(x: size.width / 2, y: size.height * 0.88)
        promptLabel.position = CGPoint(x: size.width / 2, y: size.height * 0.62)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: trackX, y: trackBottom))
        path.addLine(to: CGPoint(x: trackX, y: trackTop))
        track.path = path

        steps.forEach { $0.removeFromParent() }
        steps = (1...jumpsPerTrip).map { i in
            let dot = SKShapeNode(circleOfRadius: size.height * 0.012)
            dot.position = CGPoint(x: trackX, y: altitude(for: i))
            dot.strokeColor = .clear
            dot.zPosition = 3
            addChild(dot)
            return dot
        }
        refreshTrack()
        rocket.position = CGPoint(x: trackX, y: altitude(for: jumps))
    }

    private func altitude(for step: Int) -> CGFloat {
        trackBottom + (trackTop - trackBottom) * CGFloat(step) / CGFloat(jumpsPerTrip)
    }

    private func refreshTrack() {
        destination.text = destinations[trip % destinations.count].emoji
        destination.position = CGPoint(x: trackX, y: trackTop + size.height * 0.1)
        for (i, dot) in steps.enumerated() {
            dot.fillColor = i < jumps ? .systemYellow : NSColor.white.withAlphaComponent(0.4)
        }
    }

    // MARK: - Loop

    override func tick(dt: TimeInterval, pose: PoseFrame) {
        now += dt
        if jumper.update(pose, now: now), let body = jumper.player {
            jumped(body: body, imageSize: pose.imageSize)
        }

        let celebrating = now < celebratingUntil
        promptLabel.alpha += ((celebrating ? 0 : 1) - promptLabel.alpha) * 0.15

        if !celebrating, pose.peopleCount > 0, now - jumper.lastJump > 5, now - lastNudge > 8 {
            lastNudge = now
            say(["Jump! Jump!", "Big jump!", "Jump like a kangaroo!", "Can you jump?"].randomElement()!)
        }
    }

    // MARK: - Game

    private func jumped(body: Body, imageSize: CGSize) {
        totalJumps += 1
        totalLabel.text = "🦘 \(totalJumps)"
        totalLabel.run(.sequence([.scale(to: 1.25, duration: 0.08), .scale(to: 1, duration: 0.15)]))
        playBoing()
        if let ankle = body[.leftAnkle] ?? body[.rightAnkle] ?? body[.root] {
            stomp(at: scenePoint(ankle, imageSize: imageSize))
        }

        guard now >= celebratingUntil else { return } // jumps during the party still count, rocket waits
        jumps += 1
        refreshTrack()
        rocket.removeAction(forKey: "fly")
        rocket.run(.move(to: CGPoint(x: trackX, y: altitude(for: jumps)), duration: 0.35), withKey: "fly")
        exhaust()

        if jumps >= jumpsPerTrip {
            arrive()
        } else if jumps == jumpsPerTrip - 3 {
            say("\(jumps)! Almost there!")
        } else {
            say("\(jumps)!")
        }
    }

    private func arrive() {
        let place = destinations[trip % destinations.count]
        celebratingUntil = now + 4.5
        say("Hooray! You flew to \(place.name)!")
        confetti(count: 70)
        rocket.run(.sequence([
            .repeat(.sequence([.rotate(byAngle: 0.3, duration: 0.1), .rotate(byAngle: -0.3, duration: 0.1)]), count: 6),
            .wait(forDuration: 2.5),
            .run { [weak self] in self?.nextTrip() }
        ]))
        let banner = makeLabel("🎉 \(place.emoji) You made it!", size: 0.11)
        banner.position = CGPoint(x: size.width / 2, y: size.height * 0.5)
        addChild(banner)
        banner.setScale(0.3)
        banner.run(.sequence([.scale(to: 1, duration: 0.3), .wait(forDuration: 3.5), .fadeOut(withDuration: 0.4), .removeFromParent()]))
    }

    private func nextTrip() {
        trip += 1
        jumps = 0
        refreshTrack()
        rocket.run(.move(to: CGPoint(x: trackX, y: altitude(for: 0)), duration: 0.6))
        say("Next stop, \(destinations[trip % destinations.count].name)! Jump!")
    }

    // MARK: - Effects

    private func exhaust() {
        for _ in 0..<6 {
            let puff = makeLabel(["💨", "🔥", "✨"].randomElement()!, size: 0.045)
            puff.position = CGPoint(x: rocket.position.x + .random(in: -20...20), y: rocket.position.y - size.height * 0.06)
            puff.zPosition = 5
            addChild(puff)
            puff.run(.sequence([
                .group([.moveBy(x: .random(in: -40...40), y: -size.height * .random(in: 0.05...0.12), duration: 0.6),
                        .fadeOut(withDuration: 0.6)]),
                .removeFromParent()
            ]))
        }
    }

    /// A burst of stars where the player's feet are.
    private func stomp(at point: CGPoint) {
        for i in 0..<8 {
            let star = makeLabel("⭐️", size: 0.04)
            star.position = point
            star.zPosition = 4
            addChild(star)
            let angle = CGFloat(i) / 8 * 2 * .pi
            let dist = size.height * 0.12
            star.run(.sequence([
                .group([.moveBy(x: cos(angle) * dist, y: abs(sin(angle)) * dist, duration: 0.5),
                        .fadeOut(withDuration: 0.5)]),
                .removeFromParent()
            ]))
        }
    }

    private func playBoing() {
        guard let sound = NSSound(named: "Bottle")?.copy() as? NSSound else { return }
        sounds.append(sound)
        if sounds.count > 4 { sounds.removeFirst() }
        sound.play()
    }
}
