import SpriteKit
import AppKit

/// Vroom Vroom: hold a dinner plate like a steering wheel and turn it to steer.
/// Steering comes from the tilt of the line between the two wrists, so any plate
/// (or an imaginary wheel) works. Leaving the road just slows the car: there are no crashes.
final class DrivingScene: GameScene {
    // Tuning
    private let fullLockAngle: CGFloat = .pi / 4  // tilting the plate 45° = full turn
    private let deadZone: CGFloat = 0.09          // ~5°: holding it roughly level drives straight
    private let cruiseSpeed: CGFloat = 0.55       // screen heights per second
    private let offRoadSpeed: CGFloat = 0.3
    private let acceleration: CGFloat = 0.6       // how quickly it speeds up to cruise (per second)

    override var needsFullBody: Bool { false }    // only hands matter here
    override var wantsHandTracking: Bool { true }

    private final class RoadItem {
        enum Kind { case star, puddle, decoration }
        let node: SKNode
        let d: CGFloat
        let offset: CGFloat // in road widths from the road center
        let kind: Kind
        init(node: SKNode, d: CGFloat, offset: CGFloat, kind: Kind) {
            self.node = node; self.d = d; self.offset = offset; self.kind = kind
        }
    }

    private final class Segment {
        let node = SKNode()
        var d: CGFloat = 0
        let dash: SKShapeNode
        init(dash: SKShapeNode) { self.dash = dash }
    }

    private var distance: CGFloat = 0
    private var steer: CGFloat = 0
    private var carX: CGFloat = 0
    private var carSpeed: CGFloat = 0
    private var handsMissing: TimeInterval = 0
    private var offRoadTime: TimeInterval = 0
    private var now: TimeInterval = 0
    private var lastNudge: TimeInterval = 0
    private var stars = 0
    private var nextStarD: CGFloat = 1.0
    private var nextPuddleD: CGFloat = 3.0
    private var nextDecorationD: CGFloat = 0
    private var items: [RoadItem] = []
    private var segments: [Segment] = []
    private var sounds: [NSSound] = []

    private var car = SKNode()
    private let wheel = SKNode()
    private let handsPanel = SKNode()
    private let handsFrame = SKShapeNode()
    private let handsLine = SKShapeNode()
    private let handDots = [SKShapeNode(circleOfRadius: 7), SKShapeNode(circleOfRadius: 7)]
    private lazy var scoreLabel = makeLabel("⭐️ 0", size: 0.08)
    private lazy var hintLabel = makeLabel("Hold your plate up with both hands 🍽️", size: 0.06)

    private var roadWidth: CGFloat { size.width * 0.42 }
    private var segmentHeight: CGFloat { size.height / 20 }
    private var carY: CGFloat { size.height * 0.2 }

    // MARK: - Setup

    override func didMove(to view: SKView) {
        backgroundColor = NSColor(calibratedRed: 0.36, green: 0.72, blue: 0.33, alpha: 1)
        scoreLabel.zPosition = 20
        hintLabel.zPosition = 20
        addChild(scoreLabel)
        addChild(hintLabel)
        addChild(wheel)
        handsFrame.fillColor = NSColor.black.withAlphaComponent(0.35)
        handsFrame.strokeColor = NSColor.white.withAlphaComponent(0.6)
        handsFrame.lineWidth = 2
        handsLine.strokeColor = .white
        handsLine.lineWidth = 3
        handsPanel.addChild(handsFrame)
        handsPanel.addChild(handsLine)
        handDots.forEach { $0.strokeColor = .clear; handsPanel.addChild($0) }
        handsPanel.zPosition = 20
        addChild(handsPanel)
        buildWorld()
        say("Vroom vroom! Hold your plate like a steering wheel, and turn it to steer!")
    }

    override func didChangeSize(_ oldSize: CGSize) {
        if oldSize != size, car.parent != nil { buildWorld() }
    }

    private func buildWorld() {
        segments.forEach { $0.node.removeFromParent() }
        items.forEach { $0.node.removeFromParent() }
        items.removeAll()
        car.removeFromParent()

        segments = (0..<22).map { i in
            let seg = makeSegment()
            seg.d = distance + CGFloat(i) * segmentHeight / size.height
            seg.dash.isHidden = i % 2 == 1
            addChild(seg.node)
            return seg
        }
        nextDecorationD = distance

        car = makeCar()
        if carX == 0 { carX = roadCenter(at: distance + carY / size.height) }
        addChild(car)

        buildWheel()
        let panelSize = handsPanelSize
        handsFrame.path = CGPath(roundedRect: CGRect(x: -panelSize.width / 2, y: -panelSize.height / 2,
                                                     width: panelSize.width, height: panelSize.height),
                                 cornerWidth: 10, cornerHeight: 10, transform: nil)
        handsPanel.position = CGPoint(x: size.width - panelSize.width / 2 - 24, y: panelSize.height / 2 + 24)
        scoreLabel.fontSize = size.height * 0.08
        scoreLabel.position = CGPoint(x: size.width / 2, y: size.height * 0.88)
        hintLabel.fontSize = size.height * 0.06
        hintLabel.position = CGPoint(x: size.width / 2, y: size.height * 0.62)
    }

    private func makeSegment() -> Segment {
        let h = segmentHeight + 2
        let dash = SKShapeNode(rectOf: CGSize(width: size.width * 0.008, height: h * 0.6))
        dash.fillColor = .systemYellow
        dash.strokeColor = .clear
        let seg = Segment(dash: dash)

        let asphalt = SKShapeNode(rectOf: CGSize(width: roadWidth, height: h))
        asphalt.fillColor = NSColor(white: 0.32, alpha: 1)
        asphalt.strokeColor = .clear
        seg.node.addChild(asphalt)
        for side: CGFloat in [-1, 1] {
            let edge = SKShapeNode(rectOf: CGSize(width: size.width * 0.012, height: h))
            edge.fillColor = .white
            edge.strokeColor = .clear
            edge.position.x = side * roadWidth / 2
            seg.node.addChild(edge)
        }
        seg.node.addChild(dash)
        seg.node.zPosition = 1
        return seg
    }

    private func makeCar() -> SKNode {
        let w = size.width * 0.06, h = w * 1.7
        let node = SKNode()
        node.zPosition = 10
        for (x, y) in [(-1.0, 1.0), (1.0, 1.0), (-1.0, -1.0), (1.0, -1.0)] as [(CGFloat, CGFloat)] {
            let tire = SKShapeNode(rectOf: CGSize(width: w * 0.24, height: h * 0.24), cornerRadius: 3)
            tire.fillColor = .black
            tire.strokeColor = .clear
            tire.position = CGPoint(x: x * w * 0.52, y: y * h * 0.3)
            node.addChild(tire)
        }
        let body = SKShapeNode(rectOf: CGSize(width: w, height: h), cornerRadius: w * 0.3)
        body.fillColor = .systemRed
        body.strokeColor = .white
        body.lineWidth = 3
        node.addChild(body)
        let windshield = SKShapeNode(rectOf: CGSize(width: w * 0.72, height: h * 0.2), cornerRadius: 4)
        windshield.fillColor = NSColor(calibratedRed: 0.7, green: 0.9, blue: 1, alpha: 1)
        windshield.strokeColor = .clear
        windshield.position.y = h * 0.15
        node.addChild(windshield)
        let rear = SKShapeNode(rectOf: CGSize(width: w * 0.6, height: h * 0.12), cornerRadius: 3)
        rear.fillColor = windshield.fillColor
        rear.strokeColor = .clear
        rear.position.y = -h * 0.28
        node.addChild(rear)
        for x: CGFloat in [-1, 1] {
            let light = SKShapeNode(circleOfRadius: w * 0.1)
            light.fillColor = .systemYellow
            light.strokeColor = .clear
            light.position = CGPoint(x: x * w * 0.3, y: h * 0.47)
            node.addChild(light)
        }
        return node
    }

    /// On-screen wheel that mirrors the plate, so he can see turning the plate turns the car.
    private func buildWheel() {
        wheel.removeAllChildren()
        let r = size.height * 0.09
        let rim = SKShapeNode(circleOfRadius: r)
        rim.strokeColor = .white
        rim.lineWidth = r * 0.18
        rim.fillColor = NSColor.black.withAlphaComponent(0.25)
        wheel.addChild(rim)
        for angle: CGFloat in [0, .pi * 2 / 3, .pi * 4 / 3] {
            let spoke = SKShapeNode(rectOf: CGSize(width: r * 0.12, height: r))
            spoke.fillColor = .white
            spoke.strokeColor = .clear
            spoke.position = CGPoint(x: -sin(angle) * r / 2, y: cos(angle) * r / 2)
            spoke.zRotation = angle
            wheel.addChild(spoke)
        }
        let hub = SKShapeNode(circleOfRadius: r * 0.22)
        hub.fillColor = .systemRed
        hub.strokeColor = .white
        hub.lineWidth = 3
        wheel.addChild(hub)
        wheel.position = CGPoint(x: size.width * 0.1, y: size.height * 0.16)
        wheel.zPosition = 20
    }

    // MARK: - Road shape

    /// Gentle, endless curves: the road center x at world distance `d` (in screen heights).
    private func roadCenter(at d: CGFloat) -> CGFloat {
        let wiggle = 0.17 * sin(d * 0.8) + 0.07 * sin(d * 2.1 + 1)
        return size.width * (0.5 + wiggle)
    }

    private func screenY(_ d: CGFloat) -> CGFloat { (d - distance) * size.height }

    // MARK: - Loop

    override func tick(dt: TimeInterval, pose: PoseFrame) {
        now += dt
        let dt = CGFloat(dt)

        // Steering
        let reading = plateSteering(pose)
        showHands(reading)
        if let reading {
            handsMissing = 0
            steer += (reading.value - steer) * 0.25
        } else {
            handsMissing += Double(dt)
            steer *= 0.9
        }
        hintLabel.alpha += ((handsMissing > 1 ? 1 : 0) - hintLabel.alpha) * 0.1
        wheel.zRotation = -steer * fullLockAngle
        wheel.alpha = handsMissing > 0.5 ? 0.4 : 1

        // Car
        let carD = distance + carY / size.height
        let offRoad = abs(carX - roadCenter(at: carD)) > roadWidth / 2
        offRoadTime = offRoad ? offRoadTime + Double(dt) : 0
        // Drives by itself: smoothly speeds up to cruise, and eases off on the grass.
        let targetSpeed = offRoad ? offRoadSpeed : cruiseSpeed
        carSpeed += (targetSpeed - carSpeed) * min(1, acceleration * dt * 3)
        distance += carSpeed * dt

        carX = min(max(carX + steer * size.width * 0.5 * dt, size.width * 0.05), size.width * 0.95)
        let bump: CGFloat = offRoad ? .random(in: -3...3) : 0
        car.position = CGPoint(x: carX + bump, y: carY + bump)
        car.zRotation = -steer * 0.35

        if offRoadTime > 1.5, now - lastNudge > 6 {
            lastNudge = now
            say(["Back on the road!", "Turn back to the road!", "Bumpy grass! Steer to the road!"].randomElement()!)
        }

        scrollRoad()
        spawnItems()
        moveItems()
    }

    private struct SteeringReading {
        var value: CGFloat
        var left: CGPoint, right: CGPoint // normalized camera coords, for the hands panel
        var fromHandTracker: Bool
    }

    /// Steering from the tilt of the line between the two hands: right hand lower = turn right.
    /// Prefers the dedicated hand tracker (robust up close, plate in front of the body);
    /// falls back to body wrists, then elbows.
    private func plateSteering(_ pose: PoseFrame) -> SteeringReading? {
        var pair: (CGPoint, CGPoint)?
        var fromHands = false
        if pose.hands.count >= 2, hypot(pose.hands[0].x - pose.hands[1].x, pose.hands[0].y - pose.hands[1].y) > 0.04 {
            pair = (pose.hands[0], pose.hands[1])
            fromHands = true
        } else {
            let pairs: [(CGPoint, CGPoint)] = pose.bodies.compactMap { body in
                guard let a = body[.leftWrist] ?? body[.leftElbow], let b = body[.rightWrist] ?? body[.rightElbow] else { return nil }
                return (a, b)
            }
            // Several people: use the hands farthest apart (whoever is holding the plate out).
            pair = pairs.max { hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) < hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        }
        guard let (a, b) = pair else { return nil }
        let (left, right) = a.x < b.x ? (a, b) : (b, a)

        // Measure the angle on screen so the camera's aspect ratio doesn't distort it.
        let pl = scenePoint(left, imageSize: pose.imageSize), pr = scenePoint(right, imageSize: pose.imageSize)
        let angle = atan2(pr.y - pl.y, pr.x - pl.x)
        var value: CGFloat = 0
        if abs(angle) > deadZone {
            let effective = angle > 0 ? angle - deadZone : angle + deadZone
            value = min(max(-effective / (fullLockAngle - deadZone), -1), 1)
        }
        return SteeringReading(value: value, left: left, right: right, fromHandTracker: fromHands)
    }

    private var handsPanelSize: CGSize {
        let w = size.width * 0.16
        return CGSize(width: w, height: w * 9 / 16)
    }

    /// Small camera-shaped panel showing where the hands are seen: green = hand tracker, yellow = body.
    private func showHands(_ reading: SteeringReading?) {
        guard let reading else {
            handDots.forEach { $0.isHidden = true }
            handsLine.path = nil
            return
        }
        let s = handsPanelSize
        let points = [reading.left, reading.right].map { CGPoint(x: ($0.x - 0.5) * s.width, y: ($0.y - 0.5) * s.height) }
        let color: NSColor = reading.fromHandTracker ? .systemGreen : .systemYellow
        for (dot, p) in zip(handDots, points) {
            dot.isHidden = false
            dot.position = p
            dot.fillColor = color
        }
        let path = CGMutablePath()
        path.move(to: points[0])
        path.addLine(to: points[1])
        handsLine.path = path
    }

    private func scrollRoad() {
        let span = CGFloat(segments.count) * segmentHeight / size.height
        for seg in segments {
            if screenY(seg.d) < -segmentHeight {
                seg.d += span
            }
            seg.node.position = CGPoint(x: roadCenter(at: seg.d), y: screenY(seg.d))
        }
    }

    // MARK: - Stars, puddles, scenery

    private func spawnItems() {
        let horizon = distance + 1.1
        while nextStarD < horizon {
            // Sometimes a little trail of stars that follows the road.
            let count = Bool.random() ? 1 : 3
            let offset = CGFloat.random(in: -0.32...0.32)
            for i in 0..<count {
                add(makeLabel("⭐️", size: 0.065), d: nextStarD + CGFloat(i) * 0.12, offset: offset, kind: .star)
            }
            nextStarD += .random(in: 0.5...0.9) + CGFloat(count - 1) * 0.12
        }
        while nextPuddleD < horizon {
            let puddle = SKShapeNode(ellipseOf: CGSize(width: roadWidth * 0.28, height: size.height * 0.06))
            puddle.fillColor = NSColor.systemBlue.withAlphaComponent(0.7)
            puddle.strokeColor = NSColor.white.withAlphaComponent(0.6)
            puddle.lineWidth = 3
            add(puddle, d: nextPuddleD, offset: .random(in: -0.25...0.25), kind: .puddle)
            nextPuddleD += .random(in: 3...5)
        }
        while nextDecorationD < horizon {
            let emoji = ["🌳", "🌲", "🌼", "🌷", "🏡", "🐄", "🐑", "🌻", "🌳", "🐓"].randomElement()!
            let side: CGFloat = Bool.random() ? 1 : -1
            add(makeLabel(emoji, size: .random(in: 0.06...0.1)), d: nextDecorationD,
                offset: side * .random(in: 0.7...1.5), kind: .decoration)
            nextDecorationD += .random(in: 0.12...0.25)
        }
    }

    private func add(_ node: SKNode, d: CGFloat, offset: CGFloat, kind: RoadItem.Kind) {
        node.zPosition = kind == .decoration ? 3 : (kind == .puddle ? 2 : 4)
        addChild(node)
        let item = RoadItem(node: node, d: d, offset: offset, kind: kind)
        items.append(item)
        place(item)
    }

    private func place(_ item: RoadItem) {
        item.node.position = CGPoint(x: roadCenter(at: item.d) + item.offset * roadWidth, y: screenY(item.d))
    }

    private func moveItems() {
        let reach = size.width * 0.055
        var keep: [RoadItem] = []
        for item in items {
            place(item)
            let p = item.node.position
            if p.y < -size.height * 0.1 {
                item.node.removeFromParent()
                continue
            }
            if item.kind != .decoration, hypot(p.x - car.position.x, p.y - car.position.y) < reach {
                if item.kind == .star {
                    collect(item.node)
                    continue
                } else if item.node.userData == nil {
                    item.node.userData = ["splashed": true]
                    splash(at: p)
                }
            }
            keep.append(item)
        }
        items = keep
    }

    private func collect(_ star: SKNode) {
        stars += 1
        scoreLabel.text = "⭐️ \(stars)"
        scoreLabel.run(.sequence([.scale(to: 1.25, duration: 0.08), .scale(to: 1, duration: 0.15)]))
        play("Glass")
        let pos = star.position
        star.removeFromParent()
        for i in 0..<6 {
            let spark = makeLabel("✨", size: 0.04)
            spark.position = pos
            spark.zPosition = 12
            addChild(spark)
            let angle = CGFloat(i) / 6 * 2 * .pi
            spark.run(.sequence([
                .group([.moveBy(x: cos(angle) * 60, y: sin(angle) * 60, duration: 0.4), .fadeOut(withDuration: 0.4)]),
                .removeFromParent()
            ]))
        }
        if stars % 10 == 0 {
            say(["Wow! \(stars) stars!", "Super driver!", "Beep beep! \(stars) stars!"].randomElement()!)
            confetti()
        }
    }

    private func splash(at p: CGPoint) {
        play("Submarine")
        say("Splash!")
        for _ in 0..<10 {
            let drop = makeLabel("💧", size: 0.035)
            drop.position = p
            drop.zPosition = 12
            addChild(drop)
            drop.run(.sequence([
                .group([.moveBy(x: .random(in: -120...120), y: .random(in: 20...140), duration: 0.5), .fadeOut(withDuration: 0.5)]),
                .removeFromParent()
            ]))
        }
    }

    private func play(_ name: String) {
        guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sounds.append(sound)
        if sounds.count > 4 { sounds.removeFirst() }
        sound.play()
    }
}
