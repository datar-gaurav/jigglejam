import SpriteKit
import AVFoundation
import AppKit

final class Bubble: SKShapeNode {
    var radius: CGFloat = 50
    var baseX: CGFloat = 0
    var phase: CGFloat = 0
    var rise: CGFloat = 80
    var color: NSColor = .systemPink
}

/// Bubble Pop: bubbles float up, the child pops them with hands or feet.
/// There's no way to lose: every pop is a win, and there's a cheer every 10.
final class BubbleScene: GameScene {
    private var markers: [SKShapeNode] = []
    private var markerKinds: [Popper.Kind] = []
    private var bubbles: [Bubble] = []
    private lazy var scorePill = makeScorePill("⭐️ 0")
    private var score = 0
    private var spawnTimer: TimeInterval = 0.5
    private var sounds: [NSSound] = []
    private let maxBubbles = 9

    private var handRadius: CGFloat { size.height * 0.055 }

    override func didMove(to view: SKView) {
        backgroundColor = .clear

        addChild(scorePill)

        layoutHUD()
        say("Pop the bubbles!")
    }

    override func didChangeSize(_ oldSize: CGSize) {
        layoutHUD()
        // Marker sizes depend on scene height; rebuild them at the new size.
        markers.forEach { $0.removeFromParent() }
        markers.removeAll()
        markerKinds.removeAll()
    }

    private func layoutHUD() {
        placeScorePill(scorePill)
    }

    // MARK: - Loop

    override func tick(dt: TimeInterval, pose: PoseFrame) {

        updateMarkers(pose)

        spawnTimer -= dt
        if spawnTimer <= 0, pose.peopleCount > 0, bubbles.count < maxBubbles {
            spawnBubble()
            spawnTimer = .random(in: 0.7...1.3)
        }
        moveBubbles(dt: CGFloat(dt))
        checkPops()
    }

    // MARK: - Hands & feet

    private func makeMarker(kind: Popper.Kind) -> SKShapeNode {
        let r = kind == .hand ? handRadius : handRadius * 0.8
        let color: NSColor = kind == .hand ? .white : .systemYellow
        let m = SKShapeNode(circleOfRadius: r)
        m.fillColor = color.withAlphaComponent(0.18)
        m.strokeColor = color
        m.lineWidth = 5
        m.zPosition = 5
        m.isHidden = true
        // Soft halo so hands read clearly over any background.
        let halo = SKShapeNode(circleOfRadius: r * 1.28)
        halo.fillColor = .clear
        halo.strokeColor = color.withAlphaComponent(0.28)
        halo.lineWidth = r * 0.3
        halo.zPosition = -1
        m.addChild(halo)
        return m
    }

    private func updateMarkers(_ pose: PoseFrame) {
        for (i, popper) in pose.poppers.enumerated() {
            if i >= markers.count || markerKinds[i] != popper.kind {
                if i < markers.count { markers[i].removeFromParent() }
                let m = makeMarker(kind: popper.kind)
                addChild(m)
                if i < markers.count { markers[i] = m; markerKinds[i] = popper.kind }
                else { markers.append(m); markerKinds.append(popper.kind) }
            }
            let m = markers[i]
            let target = scenePoint(popper.point, imageSize: pose.imageSize)
            if m.isHidden {
                m.position = target
                m.isHidden = false
            } else {
                // Smooth out jitter without feeling laggy.
                m.position = CGPoint(x: m.position.x + (target.x - m.position.x) * 0.8,
                                     y: m.position.y + (target.y - m.position.y) * 0.8)
            }
        }
        for i in pose.poppers.count..<max(markers.count, pose.poppers.count) {
            markers[i].isHidden = true
        }
    }

    // MARK: - Bubbles

    private func spawnBubble() {
        let r = size.height * .random(in: 0.065...0.1)
        let color = palette.randomElement()!
        let b = Bubble()
        b.radius = r
        b.color = color
        b.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        b.fillColor = color.withAlphaComponent(0.45)
        b.strokeColor = .white
        b.lineWidth = 4

        let shine = SKShapeNode(ellipseOf: CGSize(width: r * 0.55, height: r * 0.3))
        shine.fillColor = NSColor.white.withAlphaComponent(0.75)
        shine.strokeColor = .clear
        shine.position = CGPoint(x: -r * 0.35, y: r * 0.45)
        shine.zRotation = 0.5
        b.addChild(shine)

        b.baseX = .random(in: size.width * 0.1...size.width * 0.9)
        b.position = CGPoint(x: b.baseX, y: -r)
        b.phase = .random(in: 0...(2 * .pi))
        b.rise = size.height / .random(in: 6...9) // slow: about 6–9 s to cross the screen
        b.zPosition = 1
        b.setScale(0.3)
        b.run(.scale(to: 1, duration: 0.3))
        addChild(b)
        bubbles.append(b)
    }

    private func moveBubbles(dt: CGFloat) {
        for b in bubbles {
            b.phase += dt * 1.5
            b.position = CGPoint(x: b.baseX + sin(b.phase) * b.radius * 0.6, y: b.position.y + b.rise * dt)
        }
        let gone = bubbles.filter { $0.position.y > size.height + $0.radius }
        gone.forEach { $0.removeFromParent() }
        bubbles.removeAll { b in gone.contains { $0 === b } }
    }

    private func checkPops() {
        for b in bubbles {
            for (i, m) in markers.enumerated() where !m.isHidden {
                let reach = markerKinds[i] == .hand ? handRadius : handRadius * 0.8
                if hypot(b.position.x - m.position.x, b.position.y - m.position.y) < b.radius + reach {
                    pop(b)
                    break
                }
            }
        }
    }

    private func pop(_ b: Bubble) {
        bubbles.removeAll { $0 === b }
        burst(at: b.position, color: b.color, radius: b.radius)
        b.removeFromParent()

        score += 1
        scorePill.text = "⭐️ \(score)"
        scorePill.pulse()
        playPop()
        if score % 10 == 0 { celebrate() }
    }

    // MARK: - Juice

    private func burst(at point: CGPoint, color: NSColor, radius: CGFloat) {
        let ring = SKShapeNode(circleOfRadius: radius)
        ring.strokeColor = .white
        ring.lineWidth = 5
        ring.position = point
        ring.zPosition = 2
        addChild(ring)
        ring.run(.sequence([.group([.scale(to: 1.6, duration: 0.25), .fadeOut(withDuration: 0.25)]), .removeFromParent()]))

        for _ in 0..<12 {
            let drop = SKShapeNode(circleOfRadius: radius * .random(in: 0.08...0.16))
            drop.fillColor = color
            drop.strokeColor = .clear
            drop.position = point
            drop.zPosition = 2
            addChild(drop)
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let dist = radius * .random(in: 1.2...2.2)
            drop.run(.sequence([
                .group([.moveBy(x: cos(angle) * dist, y: sin(angle) * dist, duration: 0.4),
                        .fadeOut(withDuration: 0.4),
                        .scale(to: 0.3, duration: 0.4)]),
                .removeFromParent()
            ]))
        }
    }

    private func celebrate() {
        let cheers = ["Wow! \(score) bubbles!", "Amazing! \(score)!", "You're a super popper!", "Great job! \(score) bubbles!"]
        say(cheers.randomElement()!)
        confetti()
    }

    private func playPop() {
        guard !Snapshot.isActive else { return }
        // Keep a small pool so overlapping pops all play.
        guard let sound = NSSound(named: "Pop")?.copy() as? NSSound else { return }
        sounds.append(sound)
        if sounds.count > 6 { sounds.removeFirst() }
        sound.play()
    }
}
