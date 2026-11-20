import SpriteKit
import AppKit

/// Fox Trail: a side-scrolling walk. March in place to walk the fox, jump to jump.
/// Made for a 4-year-old: no enemies, no pits, no dying. Crates just block the way until you
/// jump over them (or onto them), fruit is the reward, and every level ends in a party at home.
final class FoxTrailScene: GameScene {
    // Tuning (world units are screen heights)
    private let maxWalkSpeed: CGFloat = 0.38
    private let airForwardSpeed: CGFloat = 0.42   // always drift forward in a jump, so jumping clears crates
    private let gravity: CGFloat = 3.2
    private let jumpVelocity: CGFloat = 1.55      // ≈ 0.37 screen heights high
    private let groundLevel: CGFloat = 0.2        // ground top, as a fraction of screen height
    private let foxHalfWidth: CGFloat = 0.04
    private let foxHeight: CGFloat = 0.12

    private struct Crate { let x, w, h: CGFloat }
    private final class Fruit {
        let x, y: CGFloat
        let node: SKNode
        init(x: CGFloat, y: CGFloat, node: SKNode) { self.x = x; self.y = y; self.node = node }
    }
    private struct Parallax { let node: SKNode; let x: CGFloat; let factor: CGFloat }

    private let jumper = JumpDetector()
    private let walker = WalkDetector()

    private var now: TimeInterval = 0
    private var level = 1
    private var foxX: CGFloat = 0
    private var foxY: CGFloat = 0          // feet height above the ground
    private var velocityY: CGFloat = 0
    private var walkSpeed: CGFloat = 0
    private var walkPhase: CGFloat = 0
    private var blockedTime: TimeInterval = 0
    private var idleTime: TimeInterval = 0
    private var lastNudge: TimeInterval = 0
    private var celebratingUntil: TimeInterval = 0
    private var fruitCount = 0

    private var crates: [Crate] = []
    private var fruits: [Fruit] = []
    private var scenery: [Parallax] = []
    private var goalX: CGFloat = 0

    private let world = SKNode()       // moves with the fox
    private let backdrop = SKNode()    // parallax layers
    private lazy var fox = makeLabel("🦊", size: 0.13)
    private lazy var fruitLabel = makeLabel("🍎 0", size: 0.08)
    private lazy var levelLabel = makeLabel("Level 1", size: 0.045)
    private lazy var jumpHint = makeLabel("⬆️", size: 0.09)
    private var sounds: [NSSound] = []

    private var H: CGFloat { size.height }
    private var foxScreenX: CGFloat { size.width * 0.3 }
    private var onGround: Bool { foxY <= support(at: foxX) + 0.0001 && velocityY <= 0 }

    override var debugText: String { String(format: "walk %.2f%@", walker.pace, jumper.airborne ? " ⬆️" : "") }

    // MARK: - Setup

    override func didMove(to view: SKView) {
        backgroundColor = NSColor(calibratedRed: 0.55, green: 0.8, blue: 1, alpha: 1)
        backdrop.zPosition = 0
        world.zPosition = 2
        fox.zPosition = 6
        jumpHint.alpha = 0
        jumpHint.zPosition = 7
        addChild(backdrop)
        addChild(world)
        world.addChild(fox)
        world.addChild(jumpHint)
        addChild(fruitLabel)
        addChild(levelLabel)
        buildLevel()
        say("Fox Trail! March your legs to walk, and jump over the boxes!")
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard oldSize != size, world.parent != nil else { return }
        buildLevel(keepPosition: true)
    }

    private func buildLevel(keepPosition: Bool = false) {
        world.children.filter { $0 !== fox && $0 !== jumpHint }.forEach { $0.removeFromParent() }
        backdrop.removeAllChildren()
        scenery.removeAll()
        if !keepPosition {
            foxX = 0; foxY = 0; velocityY = 0; walkSpeed = 0
            fruits.removeAll()
            crates = makeCrates()
        }
        fruitLabel.fontSize = H * 0.08
        fruitLabel.position = CGPoint(x: size.width / 2, y: H * 0.9)
        levelLabel.fontSize = H * 0.045
        levelLabel.position = CGPoint(x: size.width * 0.08, y: H * 0.93)
        levelLabel.text = "Level \(level)"
        fox.fontSize = H * 0.13

        let length = goalX + 4

        // Ground: grass strip on top of dirt.
        let dirt = SKShapeNode(rect: CGRect(x: -5 * H, y: 0, width: (length + 10) * H, height: groundLevel * H))
        dirt.fillColor = NSColor(calibratedRed: 0.6, green: 0.42, blue: 0.25, alpha: 1)
        dirt.strokeColor = .clear
        world.addChild(dirt)
        let grass = SKShapeNode(rect: CGRect(x: -5 * H, y: (groundLevel - 0.03) * H, width: (length + 10) * H, height: 0.03 * H))
        grass.fillColor = NSColor(calibratedRed: 0.3, green: 0.75, blue: 0.3, alpha: 1)
        grass.strokeColor = .clear
        world.addChild(grass)

        for crate in crates { world.addChild(makeCrateNode(crate)) }

        if !keepPosition {
            for (x, y) in fruitSpots() {
                let node = makeLabel(["🍎", "🍓", "🍌", "🍊", "🍇", "🍉"].randomElement()!, size: 0.07)
                world.addChild(node)
                fruits.append(Fruit(x: x, y: y, node: node))
            }
        } else {
            fruits.forEach { world.addChild($0.node) }
        }
        for fruit in fruits {
            fruit.node.position = CGPoint(x: fruit.x * H, y: (groundLevel + fruit.y) * H)
            fruit.node.run(.repeatForever(.sequence([.moveBy(x: 0, y: 6, duration: 0.5), .moveBy(x: 0, y: -6, duration: 0.5)])))
        }

        let home = makeLabel("🏡", size: 0.22)
        home.position = CGPoint(x: (goalX + 0.3) * H, y: (groundLevel + 0.1) * H)
        world.addChild(home)
        for i in 0..<3 {
            let balloon = makeLabel("🎈", size: 0.07)
            balloon.position = CGPoint(x: (goalX + 0.1 + CGFloat(i) * 0.15) * H, y: (groundLevel + 0.3 + CGFloat(i % 2) * 0.05) * H)
            world.addChild(balloon)
        }

        // Parallax: far clouds and hills drift slower than the ground.
        var x: CGFloat = -2
        while x < length * 0.6 + 4 {
            addScenery("☁️", x: x, y: .random(in: 0.65...0.82), size: .random(in: 0.08...0.13), factor: 0.2)
            x += .random(in: 1.2...2.2)
        }
        x = -2
        while x < length * 0.8 + 4 {
            let hill = SKShapeNode(ellipseOf: CGSize(width: .random(in: 0.8...1.4) * H, height: .random(in: 0.35...0.55) * H))
            hill.fillColor = NSColor(calibratedRed: 0.45, green: 0.78, blue: 0.45, alpha: 1)
            hill.strokeColor = .clear
            backdrop.addChild(hill)
            scenery.append(Parallax(node: hill, x: x, factor: 0.5))
            hill.position.y = groundLevel * H
            x += .random(in: 0.7...1.3)
        }
        x = -1
        while x < length + 2 {
            addScenery(["🌳", "🌲", "🌷", "🌼", "🍄"].randomElement()!, x: x, y: groundLevel + 0.03, size: .random(in: 0.06...0.1), factor: 1, inWorld: true)
            x += .random(in: 0.5...1.1)
        }
    }

    private func addScenery(_ emoji: String, x: CGFloat, y: CGFloat, size rel: CGFloat, factor: CGFloat, inWorld: Bool = false) {
        let node = makeLabel(emoji, size: rel)
        node.verticalAlignmentMode = .bottom
        if inWorld {
            node.zPosition = 1
            node.position = CGPoint(x: x * H, y: y * H)
            world.addChild(node)
        } else {
            node.zPosition = 0
            node.position.y = y * H
            backdrop.addChild(node)
            scenery.append(Parallax(node: node, x: x, factor: factor))
        }
    }

    private func makeCrates() -> [Crate] {
        let count = min(5 + level * 2, 12)
        var result: [Crate] = []
        var x: CGFloat = 1.6
        for _ in 0..<count {
            let tall = level >= 2 && Int.random(in: 0..<3) == 0
            let h: CGFloat = tall ? 0.2 : .random(in: 0.1...0.14)
            let w: CGFloat = tall ? 0.12 : .random(in: 0.12...0.16)
            result.append(Crate(x: x, w: w, h: h))
            x += .random(in: 1.0...1.7)
        }
        goalX = x + 0.6
        return result
    }

    /// Some fruit sits on the path (walk into it), some floats above crates (jump for it).
    private func fruitSpots() -> [(CGFloat, CGFloat)] {
        var spots: [(CGFloat, CGFloat)] = []
        for (i, crate) in crates.enumerated() {
            spots.append((crate.x + crate.w / 2, crate.h + 0.17))
            let next = i + 1 < crates.count ? crates[i + 1].x : goalX
            let gapStart = crate.x + crate.w + 0.25
            if next - gapStart > 0.4 {
                spots.append((gapStart + (next - gapStart) * 0.4, 0.06))
            }
        }
        spots.append((0.8, 0.06))
        return spots
    }

    private func makeCrateNode(_ crate: Crate) -> SKNode {
        let node = SKNode()
        node.position = CGPoint(x: crate.x * H, y: groundLevel * H)
        let box = SKShapeNode(rect: CGRect(x: 0, y: 0, width: crate.w * H, height: crate.h * H), cornerRadius: 4)
        box.fillColor = NSColor(calibratedRed: 0.78, green: 0.55, blue: 0.3, alpha: 1)
        box.strokeColor = NSColor(calibratedRed: 0.45, green: 0.28, blue: 0.12, alpha: 1)
        box.lineWidth = 4
        node.addChild(box)
        let planks = CGMutablePath()
        planks.move(to: CGPoint(x: 0, y: 0))
        planks.addLine(to: CGPoint(x: crate.w * H, y: crate.h * H))
        planks.move(to: CGPoint(x: crate.w * H, y: 0))
        planks.addLine(to: CGPoint(x: 0, y: crate.h * H))
        let cross = SKShapeNode(path: planks)
        cross.strokeColor = box.strokeColor
        cross.lineWidth = 3
        node.addChild(cross)
        node.zPosition = 3
        return node
    }

    // MARK: - Loop

    override func tick(dt: TimeInterval, pose: PoseFrame) {
        now += dt
        let dt = CGFloat(dt)

        let jumped = jumper.update(pose, now: now)
        if jumper.newFrame {
            walker.update(player: jumper.player, torso: jumper.torso, frameDT: jumper.frameDT, airborne: jumper.airborne)
        }

        let celebrating = now < celebratingUntil
        if !celebrating {
            if jumped && onGround {
                velocityY = jumpVelocity
                play("Bottle")
            }
            move(dt: dt)
            collectFruit()
            if foxX >= goalX { finishLevel() }
            nudges(dt: Double(dt), pose: pose)
        }
        render(dt: dt)
    }

    /// Ground or crate top under the fox.
    private func support(at x: CGFloat) -> CGFloat {
        var top: CGFloat = 0
        for crate in crates where x + foxHalfWidth > crate.x && x - foxHalfWidth < crate.x + crate.w && foxY >= crate.h - 0.01 {
            top = max(top, crate.h)
        }
        return top
    }

    private func move(dt: CGFloat) {
        let target = walker.pace * maxWalkSpeed
        walkSpeed += (target - walkSpeed) * (1 - exp(-dt / 0.2))
        let forward = onGround ? walkSpeed : max(walkSpeed, airForwardSpeed)

        // Horizontal, stopping at the front of a crate that's taller than the fox's feet.
        var newX = foxX + forward * dt
        var blocked = false
        for crate in crates where foxY < crate.h - 0.005 && foxX + foxHalfWidth <= crate.x + 0.001 && newX + foxHalfWidth > crate.x {
            newX = crate.x - foxHalfWidth
            blocked = true
        }
        foxX = newX
        blockedTime = blocked ? blockedTime + Double(dt) : 0
        if walkSpeed > 0.05 || !onGround { walkPhase += dt * (6 + walker.pace * 8) }

        // Vertical
        velocityY -= gravity * dt
        let floor = support(at: foxX)
        var newY = foxY + velocityY * dt
        if newY <= floor {
            newY = floor
            velocityY = 0
        }
        foxY = newY
    }

    private func collectFruit() {
        let cx = foxX, cy = foxY + foxHeight / 2
        fruits.removeAll { fruit in
            guard hypot(fruit.x - cx, fruit.y - cy) < 0.1 else { return false }
            fruitCount += 1
            fruitLabel.text = "🍎 \(fruitCount)"
            fruitLabel.run(.sequence([.scale(to: 1.25, duration: 0.08), .scale(to: 1, duration: 0.15)]))
            play("Glass")
            fruit.node.removeAllActions()
            fruit.node.run(.sequence([.group([.scale(to: 1.8, duration: 0.2), .fadeOut(withDuration: 0.2)]), .removeFromParent()]))
            if fruitCount % 10 == 0 { say(["Yummy! \(fruitCount) fruits!", "So much fruit!", "Fox is getting full!"].randomElement()!) }
            return true
        }
    }

    private func nudges(dt: TimeInterval, pose: PoseFrame) {
        idleTime = walker.pace == 0 && onGround ? idleTime + dt : 0
        let showJump = blockedTime > 0.6
        jumpHint.alpha += ((showJump ? 1 : 0) - jumpHint.alpha) * 0.15
        guard now - lastNudge > 6, pose.peopleCount > 0 else { return }
        if blockedTime > 1.2 {
            lastNudge = now
            say(["Jump over the box!", "Big jump!", "Jump, jump!"].randomElement()!)
        } else if idleTime > 5 {
            lastNudge = now
            say(["March your legs to walk!", "Stomp stomp! Let's walk!", "Walk like a soldier!"].randomElement()!)
        }
    }

    private func finishLevel() {
        celebratingUntil = now + 4.5
        say("Hooray! Fox made it home!")
        confetti(count: 70)
        play("Hero")
        let banner = makeLabel("🎉 Level \(level) done!", size: 0.12)
        banner.position = CGPoint(x: size.width / 2, y: H * 0.6)
        banner.zPosition = 30
        addChild(banner)
        banner.setScale(0.3)
        banner.run(.sequence([
            .scale(to: 1, duration: 0.3), .wait(forDuration: 3.6), .fadeOut(withDuration: 0.4),
            .run { [weak self] in self?.nextLevel() },
            .removeFromParent()
        ]))
    }

    private func nextLevel() {
        level += 1
        buildLevel()
        say("Level \(level)! Let's go!")
    }

    // MARK: - Drawing

    private func render(dt: CGFloat) {
        world.position.x = foxScreenX - foxX * H
        for item in scenery {
            item.node.position.x = foxScreenX + (item.x - foxX * item.factor) * H
        }
        let bob = onGround && walkSpeed > 0.05 ? abs(sin(walkPhase)) * 0.015 : 0
        fox.position = CGPoint(x: foxX * H, y: (groundLevel + foxY + foxHeight / 2 + bob) * H)
        fox.zRotation = onGround ? sin(walkPhase) * 0.08 * min(walkSpeed / maxWalkSpeed, 1) : -0.15
        if let crate = crates.first(where: { $0.x > foxX }) {
            jumpHint.position = CGPoint(x: (crate.x + crate.w / 2) * H,
                                        y: (groundLevel + crate.h + 0.12) * H + abs(sin(CGFloat(now) * 5)) * 14)
        }
    }

    private func play(_ name: String) {
        guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sounds.append(sound)
        if sounds.count > 4 { sounds.removeFirst() }
        sound.play()
    }
}
