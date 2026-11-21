import SpriteKit
import AppKit

/// Garden Guard: a lane-defense game. Hungry bugs crawl across three garden rows toward the
/// veggies. Catch falling seeds, touch an empty dirt patch to plant a berry flower, and the
/// flowers toss berries at bugs in their row. A fed bug is happy and floats away with a heart.
/// Touching a bug feeds it too, and a jump makes every flower throw a berry blast.
///
/// Made for little kids: nothing can be lost. A bug that reaches the veggies takes a nibble,
/// gets full and wanders off; the veggie grows back. Every wave ends in a party.
final class GardenGuardScene: GameScene {
    // Layout (fractions of the scene)
    private let rows = 3
    private let columns = 5
    private let rowCenters: [CGFloat] = [0.27, 0.49, 0.71]   // of height, bottom row first
    private let rowHeight: CGFloat = 0.22
    private let gridLeft: CGFloat = 0.17                      // of width
    private let gridRight: CGFloat = 0.76
    private let veggieX: CGFloat = 0.075

    // Tuning
    private let plantDwell: TimeInterval = 0.35   // hand held over a patch this long plants it
    private let shotInterval: TimeInterval = 1.7
    private let berrySpeed: CGFloat = 0.75        // screen widths per second
    private let touchFeedCooldown: TimeInterval = 0.45
    private let munchTime: TimeInterval = 2.2

    private enum Species: CaseIterable {
        case caterpillar, snail, ladybug, beetle
        var emoji: String {
            switch self { case .caterpillar: "🐛"; case .snail: "🐌"; case .ladybug: "🐞"; case .beetle: "🪲" }
        }
        var hunger: Int {
            switch self { case .caterpillar: 3; case .snail: 2; case .ladybug: 2; case .beetle: 4 }
        }
        /// Seconds to crawl across the garden.
        var crossing: CGFloat {
            switch self { case .caterpillar: 26; case .snail: 34; case .ladybug: 20; case .beetle: 30 }
        }
    }

    private final class Bug {
        let species: Species
        let row: Int
        let node: SKNode
        let body: SKLabelNode
        let pips: SKNode
        var hunger: Int
        var speedScale: CGFloat
        var lastTouchFeed: TimeInterval = -10
        var munchingSince: TimeInterval?
        var leaving = false
        init(species: Species, row: Int, node: SKNode, body: SKLabelNode, pips: SKNode, speedScale: CGFloat) {
            self.species = species; self.row = row; self.node = node; self.body = body; self.pips = pips
            hunger = species.hunger; self.speedScale = speedScale
        }
    }

    private final class Flower {
        let row, column: Int
        let node: SKLabelNode
        var cooldown: TimeInterval
        var ready = false
        init(row: Int, column: Int, node: SKLabelNode, cooldown: TimeInterval) {
            self.row = row; self.column = column; self.node = node; self.cooldown = cooldown
        }
    }

    private final class Berry {
        let row: Int
        let node: SKNode
        init(row: Int, node: SKNode) { self.row = row; self.node = node }
    }

    private final class Seed {
        let node: SKNode
        let baseX: CGFloat
        var phase: CGFloat
        init(node: SKNode, baseX: CGFloat, phase: CGFloat) { self.node = node; self.baseX = baseX; self.phase = phase }
    }

    private let jumper = JumpDetector()
    private var now: TimeInterval = 0

    // Game state
    private var wave = 1
    private var seeds = 2
    private var fed = 0
    private var bugsToSpawn = 0
    private var spawnTimer: TimeInterval = 6
    private var seedTimer: TimeInterval = 2.5
    private var waveBreakUntil: TimeInterval = 0
    private var lastNudge: TimeInterval = 0
    private var lastMunchSpeech: TimeInterval = -20
    private var saidJumpTip = false
    private var saidSeedTip = false

    private var bugs: [Bug] = []
    private var flowers: [[Flower?]] = []
    private var berries: [Berry] = []
    private var fallingSeeds: [Seed] = []
    private var dwell: [[TimeInterval]] = []

    // Nodes
    private let field = SKNode()
    private var patches: [[SKShapeNode]] = []
    private var veggies: [SKLabelNode] = []
    private var handMarkers: [SKShapeNode] = []
    private lazy var fedPill = makeScorePill("❤️ 0")
    private lazy var seedPill = HUDPill("🌱 2", tint: NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.13, alpha: 1))
    private lazy var wavePill = HUDPill("Wave 1")
    private lazy var coachPill = HUDPill("", tint: .systemGreen)
    private var sounds: [NSSound] = []

    private var W: CGFloat { size.width }
    private var H: CGFloat { size.height }
    private var handRadius: CGFloat { H * 0.05 }
    private var cellWidth: CGFloat { (gridRight - gridLeft) * W / CGFloat(columns) }
    private var bugStopX: CGFloat { (veggieX + 0.06) * W }

    override var debugText: String { "seeds \(seeds)  bugs \(bugs.count)  wave \(wave)" }

    override func trackingDidResume() {
        jumper.reset()
        for r in dwell.indices { for c in dwell[r].indices { dwell[r][c] = 0 } }
    }

    // MARK: - Setup

    override func didMove(to view: SKView) {
        backgroundColor = NSColor(calibratedRed: 0.45, green: 0.72, blue: 0.3, alpha: 1)
        flowers = Array(repeating: Array(repeating: nil, count: columns), count: rows)
        dwell = Array(repeating: Array(repeating: 0, count: columns), count: rows)
        addChild(field)
        for pill in [seedPill, wavePill, coachPill] { pill.zPosition = 40; addChild(pill) }
        addChild(fedPill)
        buildField()
        startWave()
        coach("👋 Touch a dirt patch to plant!")
        say("Garden Guard! Hungry bugs are coming. Touch a dirt patch to plant a berry flower!")
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard oldSize != size, field.parent != nil else { return }
        buildField()
    }

    /// Draws the garden and lays out everything that depends on the scene size.
    private func buildField() {
        field.removeAllChildren()
        field.addChild(makeGradientBackdrop(top: NSColor(calibratedRed: 0.42, green: 0.74, blue: 1, alpha: 1),
                                            bottom: NSColor(calibratedRed: 0.82, green: 0.94, blue: 1, alpha: 1)))

        // Lawn: alternating stripes per row, under a hedge at the top.
        let lawnTop = (rowCenters.last! + rowHeight / 2) * H
        let lawn = SKShapeNode(rect: CGRect(x: 0, y: 0, width: W, height: lawnTop + H * 0.02))
        lawn.fillColor = NSColor(calibratedRed: 0.36, green: 0.66, blue: 0.27, alpha: 1)
        lawn.strokeColor = .clear
        lawn.zPosition = -50
        field.addChild(lawn)
        for r in 0..<rows {
            let stripe = SKShapeNode(rect: CGRect(x: 0, y: (rowCenters[r] - rowHeight / 2) * H, width: W, height: rowHeight * H))
            stripe.fillColor = r % 2 == 0 ? NSColor(calibratedRed: 0.47, green: 0.77, blue: 0.33, alpha: 1)
                                          : NSColor(calibratedRed: 0.41, green: 0.71, blue: 0.29, alpha: 1)
            stripe.strokeColor = .clear
            stripe.zPosition = -49
            field.addChild(stripe)
        }
        for i in 0...Int(W / (H * 0.07)) {
            let bush = SKShapeNode(circleOfRadius: H * .random(in: 0.045...0.06))
            bush.fillColor = NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.22, alpha: 1)
            bush.strokeColor = .clear
            bush.position = CGPoint(x: CGFloat(i) * H * 0.07, y: lawnTop + H * 0.02)
            bush.zPosition = -48
            field.addChild(bush)
        }
        // Dirt patches.
        patches = (0..<rows).map { r in
            (0..<columns).map { c in
                let patch = SKShapeNode(ellipseOf: CGSize(width: cellWidth * 0.78, height: rowHeight * H * 0.5))
                patch.fillColor = NSColor(calibratedRed: 0.55, green: 0.37, blue: 0.2, alpha: 1)
                patch.strokeColor = NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.13, alpha: 1)
                patch.lineWidth = 4
                patch.position = cellCenter(row: r, column: c, lift: -0.18)
                patch.zPosition = -30
                field.addChild(patch)
                return patch
            }
        }

        // Veggies to protect.
        let veggieEmoji = ["🥕", "🥬", "🍅"]
        veggies = (0..<rows).map { r in
            let v = makeLabel(veggieEmoji[r], size: 0.12)
            v.position = CGPoint(x: veggieX * W, y: rowCenters[r] * H)
            v.zPosition = 5
            field.addChild(v)
            return v
        }

        // Keep plants, bugs, berries and seeds where they are, at the new size.
        for row in flowers { for f in row.compactMap({ $0 }) {
            f.node.fontSize = H * (f.ready ? 0.11 : 0.08)
            field.addChild(f.node)
            f.node.position = cellCenter(row: f.row, column: f.column)
        } }
        refreshPatches()

        placeScorePill(fedPill)
        seedPill.height = H * 0.085
        seedPill.position = CGPoint(x: W - H * 0.04 - seedPill.calculateAccumulatedFrame().width / 2, y: H - H * 0.095)
        wavePill.height = H * 0.06
        wavePill.position = CGPoint(x: 96 + wavePill.calculateAccumulatedFrame().width / 2, y: H - H * 0.085)
        coachPill.height = H * 0.07
        coachPill.position = CGPoint(x: W / 2, y: H * 0.06)
    }

    private func cellCenter(row: Int, column: Int, lift: CGFloat = 0) -> CGPoint {
        CGPoint(x: gridLeft * W + (CGFloat(column) + 0.5) * cellWidth, y: (rowCenters[row] + rowHeight * lift) * H)
    }

    private func refreshPatches() {
        for r in 0..<rows { for c in 0..<columns {
            patches[r][c].glowWidth = 0
            patches[r][c].alpha = flowers[r][c] == nil ? 1 : 0.55
        } }
    }

    private func coach(_ text: String?) {
        coachPill.removeAllActions()
        guard let text else { coachPill.run(.fadeOut(withDuration: 0.3)); return }
        coachPill.text = text
        coachPill.run(.fadeIn(withDuration: 0.3))
    }

    // MARK: - Loop

    override func tick(dt: TimeInterval, pose: PoseFrame) {
        now += dt
        let hands = handPoints(pose)
        updateHandMarkers(hands)

        if jumper.update(pose, now: now) { berryBlast() }
        if jumper.easedJustNow { say("Little jumps work too!") }

        spawnSeeds(dt: dt)
        moveSeeds(dt: CGFloat(dt), hands: hands)
        updatePlanting(dt: dt, hands: hands)
        spawnBugs(dt: dt)
        updateFlowers(dt: dt)
        moveBerries(dt: CGFloat(dt))
        moveBugs(dt: CGFloat(dt), hands: hands)
        checkWaveDone()
        nudge(pose: pose)
    }

    // MARK: - Hands

    /// Every tracked hand in scene coordinates, mapped by arm's reach so the whole garden is in range.
    private func handPoints(_ pose: PoseFrame) -> [CGPoint] {
        pose.bodies.flatMap { ReachMapper.hands(of: $0, imageSize: pose.imageSize) }
            .map { CGPoint(x: $0.x * W, y: $0.y * H) }
    }

    private func updateHandMarkers(_ hands: [CGPoint]) {
        while handMarkers.count < hands.count {
            let m = SKShapeNode(circleOfRadius: handRadius)
            m.fillColor = NSColor.white.withAlphaComponent(0.2)
            m.strokeColor = .white
            m.lineWidth = 5
            m.zPosition = 30
            m.isHidden = true
            let glove = RoundedLabel("🧤", size: handRadius * 1.1)
            glove.shadowed = false
            m.addChild(glove)
            addChild(m)
            handMarkers.append(m)
        }
        for (i, m) in handMarkers.enumerated() {
            guard i < hands.count else { m.isHidden = true; continue }
            if m.isHidden {
                m.position = hands[i]
                m.isHidden = false
            } else {
                m.position = CGPoint(x: m.position.x + (hands[i].x - m.position.x) * 0.7,
                                     y: m.position.y + (hands[i].y - m.position.y) * 0.7)
            }
        }
    }

    /// Smoothed marker positions: what the child sees is what touches.
    private var visibleHands: [CGPoint] { handMarkers.filter { !$0.isHidden }.map(\.position) }

    // MARK: - Seeds

    private func spawnSeeds(dt: TimeInterval) {
        guard now >= waveBreakUntil else { return }
        seedTimer -= dt
        guard seedTimer <= 0, fallingSeeds.count < 3 else { return }
        // Seeds come faster while the garden is empty, so there's always something to plant.
        let planted = flowers.joined().compactMap { $0 }.count
        seedTimer = planted < 3 ? .random(in: 3...4.5) : .random(in: 5...7.5)

        let node = SKNode()
        let glow = SKShapeNode(circleOfRadius: H * 0.055)
        glow.fillColor = NSColor.systemYellow.withAlphaComponent(0.45)
        glow.strokeColor = NSColor.white.withAlphaComponent(0.8)
        glow.lineWidth = 3
        node.addChild(glow)
        glow.run(.repeatForever(.sequence([.scale(to: 1.15, duration: 0.5), .scale(to: 1, duration: 0.5)])))
        let icon = makeLabel("🌰", size: 0.06)
        node.addChild(icon)
        let x = W * .random(in: 0.22...0.85)
        node.position = CGPoint(x: x, y: H + H * 0.06)
        node.zPosition = 25
        addChild(node)
        fallingSeeds.append(Seed(node: node, baseX: x, phase: .random(in: 0...(2 * .pi))))
    }

    private func moveSeeds(dt: CGFloat, hands: [CGPoint]) {
        let touch = visibleHands
        for seed in fallingSeeds {
            seed.phase += dt * 1.6
            let y = seed.node.position.y - H * dt / 9 // about 9 s to fall
            seed.node.position = CGPoint(x: seed.baseX + sin(seed.phase) * H * 0.04, y: y)
            if touch.contains(where: { hypot($0.x - seed.node.position.x, $0.y - seed.node.position.y) < handRadius + H * 0.06 }) {
                catchSeed(seed)
            } else if y < -H * 0.06 {
                seed.node.removeFromParent()
                fallingSeeds.removeAll { $0 === seed }
            }
        }
    }

    private func catchSeed(_ seed: Seed) {
        fallingSeeds.removeAll { $0 === seed }
        seeds += 1
        updateSeedPill()
        playSound("Tink")
        sparkle(at: seed.node.position, emoji: "✨")
        seed.node.run(.sequence([.group([.move(to: seedPill.position, duration: 0.4), .scale(to: 0.4, duration: 0.4)]),
                                 .removeFromParent()]))
        if !saidSeedTip {
            saidSeedTip = true
            say("You caught a seed! Now plant it in the dirt!")
        }
    }

    private func updateSeedPill() {
        seedPill.text = "🌱 \(seeds)"
        seedPill.position.x = W - H * 0.04 - seedPill.calculateAccumulatedFrame().width / 2
        seedPill.pulse()
    }

    // MARK: - Planting

    private func updatePlanting(dt: TimeInterval, hands: [CGPoint]) {
        let touch = visibleHands
        for r in 0..<rows { for c in 0..<columns {
            let center = cellCenter(row: r, column: c)
            let over = flowers[r][c] == nil && touch.contains {
                abs($0.x - center.x) < cellWidth * 0.5 && abs($0.y - center.y) < rowHeight * H * 0.5
            }
            patches[r][c].glowWidth = over && seeds > 0 ? 6 : 0
            patches[r][c].strokeColor = over ? (seeds > 0 ? .systemYellow : NSColor.white.withAlphaComponent(0.6))
                                             : NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.13, alpha: 1)
            dwell[r][c] = over ? dwell[r][c] + dt : 0
            if dwell[r][c] >= plantDwell {
                dwell[r][c] = 0
                if seeds > 0 { plant(row: r, column: c) } else { askForSeeds() }
            }
        } }
    }

    private func plant(row: Int, column: Int) {
        seeds -= 1
        updateSeedPill()
        let node = makeLabel("🌱", size: 0.08)
        node.position = cellCenter(row: row, column: column)
        node.zPosition = 8 + CGFloat(rows - row)
        field.addChild(node)
        let flower = Flower(row: row, column: column, node: node, cooldown: 0.6)
        flowers[row][column] = flower
        refreshPatches()
        playSound("Pop")
        sparkle(at: node.position, emoji: "🌟")

        node.setScale(0.2)
        node.run(.sequence([
            .scale(to: 1, duration: 0.25),
            .wait(forDuration: 0.5),
            .run { [weak self, weak node] in
                guard let self, let node else { return }
                node.text = "🌻"
                node.fontSize = self.H * 0.11
                flower.ready = true
            },
            .scale(to: 1.25, duration: 0.12), .scale(to: 1, duration: 0.15)
        ]))
        node.run(.repeatForever(.sequence([.rotate(toAngle: 0.06, duration: 0.8), .rotate(toAngle: -0.06, duration: 0.8)])))

        let total = flowers.joined().compactMap { $0 }.count
        if total == 1 {
            coach("🌰 Catch seeds to plant more")
            say("Hooray! Your flower throws berries at hungry bugs!")
        } else if total == 3 && !saidJumpTip {
            saidJumpTip = true
            coach("🦘 Jump for a berry blast!")
            say("Now jump! Jumping makes a berry blast!")
        } else {
            say(["Planted!", "Grow, flower, grow!", "Another flower!"].randomElement()!)
        }
    }

    private var lastSeedAsk: TimeInterval = -20
    private func askForSeeds() {
        guard now - lastSeedAsk > 6 else { return }
        lastSeedAsk = now
        say("You need a seed! Catch a falling seed first.")
        coach("🌰 Catch a falling seed!")
    }

    // MARK: - Flowers & berries

    private func updateFlowers(dt: TimeInterval) {
        for row in flowers { for f in row.compactMap({ $0 }) where f.ready {
            f.cooldown -= dt
            guard f.cooldown <= 0 else { continue }
            let x = f.node.position.x
            let target = bugs.contains { $0.row == f.row && !$0.leaving && $0.node.position.x > x && $0.node.position.x < W * 0.98 }
            guard target else { continue }
            f.cooldown = shotInterval
            throwBerry(from: f)
        } }
    }

    private func throwBerry(from flower: Flower, delay: TimeInterval = 0) {
        let berry = makeLabel("🫐", size: 0.05)
        berry.position = CGPoint(x: flower.node.position.x + cellWidth * 0.25, y: flower.node.position.y + H * 0.02)
        berry.zPosition = 20
        berry.alpha = delay > 0 ? 0 : 1
        let b = Berry(row: flower.row, node: berry)
        if delay > 0 {
            berry.run(.sequence([.wait(forDuration: delay), .run { [weak self] in
                berry.alpha = 1
                self?.berries.append(b)
            }]))
            addChild(berry)
        } else {
            addChild(berry)
            berries.append(b)
        }
        berry.run(.repeatForever(.rotate(byAngle: -.pi * 2, duration: 0.6)))
        flower.node.run(.sequence([.scaleX(to: 1.15, y: 0.9, duration: 0.08), .scale(to: 1, duration: 0.12)]))
    }

    private func moveBerries(dt: CGFloat) {
        for b in berries {
            b.node.position.x += berrySpeed * W * dt
            let hit = bugs.first {
                $0.row == b.row && !$0.leaving && abs($0.node.position.x - b.node.position.x) < H * 0.06
            }
            if let hit {
                feed(hit, at: b.node.position)
                remove(b)
            } else if b.node.position.x > W + H * 0.1 {
                remove(b)
            }
        }
    }

    private func remove(_ b: Berry) {
        b.node.removeFromParent()
        berries.removeAll { $0 === b }
    }

    /// Jump: every flower throws a quick triple of berries, even with no bug in its row.
    private func berryBlast() {
        let all = flowers.joined().compactMap { $0 }.filter(\.ready)
        playSound("Bottle")
        guard !all.isEmpty else { return }
        for f in all {
            for k in 0..<3 { throwBerry(from: f, delay: Double(k) * 0.15) }
            f.cooldown = shotInterval
        }
        let banner = makeBanner("💥 Berry blast!", color: .systemPurple, height: 0.1)
        banner.position = CGPoint(x: W / 2, y: H * 0.84)
        addChild(banner)
        banner.setScale(0.4)
        banner.run(.sequence([.scale(to: 1, duration: 0.2), .wait(forDuration: 0.8), .fadeOut(withDuration: 0.3), .removeFromParent()]))
        if coachPill.text.hasPrefix("🦘") { coach(nil) }
    }

    // MARK: - Bugs

    private func startWave() {
        bugsToSpawn = 4 + wave * 2
        spawnTimer = wave == 1 ? 7 : 2.5
    }

    private func spawnBugs(dt: TimeInterval) {
        guard bugsToSpawn > 0, now >= waveBreakUntil else { return }
        spawnTimer -= dt
        guard spawnTimer <= 0 else { return }
        spawnTimer = max(2.6, 6.5 - Double(wave) * 0.6) * .random(in: 0.8...1.2)
        bugsToSpawn -= 1

        // Early on, send bugs to rows that have a flower, so the first fights are wins.
        let defended = (0..<rows).filter { r in flowers[r].contains { $0 != nil } }
        let row = (wave == 1 && !defended.isEmpty && Bool.random()) ? defended.randomElement()! : Int.random(in: 0..<rows)
        let options: [Species] = wave == 1 ? [.caterpillar, .snail] : wave == 2 ? [.caterpillar, .snail, .ladybug] : Species.allCases
        let species = options.randomElement()!

        let node = SKNode()
        node.position = CGPoint(x: W + H * 0.08, y: rowCenters[row] * H)
        node.zPosition = 12 + CGFloat(rows - row)
        let body = makeLabel(species.emoji, size: 0.1)
        body.xScale = -1 // the emoji face right; bugs crawl left
        node.addChild(body)
        let pips = SKNode()
        pips.position = CGPoint(x: 0, y: H * 0.075)
        node.addChild(pips)
        addChild(node)
        let bug = Bug(species: species, row: row, node: node, body: body, pips: pips,
                      speedScale: 1 + CGFloat(wave - 1) * 0.08)
        bugs.append(bug)
        drawPips(bug)
        body.run(.repeatForever(.sequence([.moveBy(x: 0, y: H * 0.008, duration: 0.25), .moveBy(x: 0, y: -H * 0.008, duration: 0.25)])),
                 withKey: "crawl")
    }

    /// Little empty hearts above a bug: one per berry it still wants.
    private func drawPips(_ bug: Bug) {
        bug.pips.removeAllChildren()
        let spacing = H * 0.028
        for i in 0..<bug.hunger {
            let pip = RoundedLabel("🤍", size: H * 0.024)
            pip.shadowed = false
            pip.position = CGPoint(x: (CGFloat(i) - CGFloat(bug.hunger - 1) / 2) * spacing, y: 0)
            bug.pips.addChild(pip)
        }
    }

    private func moveBugs(dt: CGFloat, hands: [CGPoint]) {
        let touch = visibleHands
        for bug in bugs where !bug.leaving {
            // Touching a bug feeds it, too.
            if now - bug.lastTouchFeed > touchFeedCooldown,
               touch.contains(where: { hypot($0.x - bug.node.position.x, $0.y - bug.node.position.y) < handRadius + H * 0.05 }) {
                bug.lastTouchFeed = now
                feed(bug, at: bug.node.position)
                if bug.leaving { continue }
            }

            if let since = bug.munchingSince {
                if now - since > munchTime { finishMunching(bug) }
                continue
            }
            let speed = (W - bugStopX) / bug.species.crossing * bug.speedScale
            bug.node.position.x -= speed * dt
            if bug.node.position.x <= bugStopX { startMunching(bug) }
        }
    }

    private func feed(_ bug: Bug, at point: CGPoint) {
        guard !bug.leaving else { return }
        bug.hunger -= 1
        playSound("Pop")
        sparkle(at: point, emoji: "😋")
        bug.body.run(.sequence([.scaleX(to: -1.25, y: 0.8, duration: 0.07), .scaleX(to: -1, y: 1, duration: 0.12)]))
        // A fed bug is pushed back a little, so feeding feels like it matters.
        if bug.munchingSince == nil { bug.node.run(.moveBy(x: H * 0.03, y: 0, duration: 0.15)) }
        if bug.hunger <= 0 {
            happyBug(bug)
        } else {
            drawPips(bug)
        }
    }

    /// Full and happy: the bug floats away with a heart. Sometimes it leaves a seed behind.
    private func happyBug(_ bug: Bug) {
        bug.leaving = true
        bug.munchingSince = nil
        fed += 1
        fedPill.text = "❤️ \(fed)"
        fedPill.pulse()
        bug.pips.removeAllChildren()
        bug.body.removeAction(forKey: "crawl")
        let heart = makeLabel("❤️", size: 0.06)
        heart.position = CGPoint(x: 0, y: H * 0.08)
        bug.node.addChild(heart)
        heart.run(.repeatForever(.sequence([.scale(to: 1.2, duration: 0.2), .scale(to: 1, duration: 0.2)])))
        bug.node.run(.sequence([
            .group([.moveBy(x: H * 0.15, y: H * 0.45, duration: 1.4), .fadeOut(withDuration: 1.4)]),
            .removeFromParent()
        ]))
        bugs.removeAll { $0 === bug }
        if Int.random(in: 0..<3) == 0 { dropSeed(at: bug.node.position) }
        if fed % 5 == 0 {
            say(["\(fed) happy bugs!", "Yummy! \(fed) bugs fed!", "Great gardening!"].randomElement()!)
        } else if fed == 1 {
            say("Yum! That bug is full and happy!")
        }
    }

    /// A bonus seed that pops out of a happy bug and floats down where the child can grab it.
    private func dropSeed(at point: CGPoint) {
        let node = SKNode()
        let glow = SKShapeNode(circleOfRadius: H * 0.055)
        glow.fillColor = NSColor.systemYellow.withAlphaComponent(0.45)
        glow.strokeColor = NSColor.white.withAlphaComponent(0.8)
        glow.lineWidth = 3
        node.addChild(glow)
        node.addChild(makeLabel("🌰", size: 0.06))
        let x = min(max(point.x, W * 0.22), W * 0.85)
        node.position = CGPoint(x: x, y: min(point.y + H * 0.15, H * 0.85))
        node.zPosition = 25
        addChild(node)
        fallingSeeds.append(Seed(node: node, baseX: x, phase: 0))
    }

    private func startMunching(_ bug: Bug) {
        bug.munchingSince = now
        bug.node.position.x = bugStopX
        let veggie = veggies[bug.row]
        veggie.run(.repeat(.sequence([.rotate(toAngle: 0.12, duration: 0.1), .rotate(toAngle: -0.12, duration: 0.1)]), count: 10),
                   withKey: "wobble")
        let nom = makeLabel("nom nom!", size: 0.04)
        nom.position = CGPoint(x: bugStopX, y: rowCenters[bug.row] * H + H * 0.09)
        nom.zPosition = 30
        addChild(nom)
        nom.run(.sequence([.wait(forDuration: munchTime), .fadeOut(withDuration: 0.3), .removeFromParent()]))
        if now - lastMunchSpeech > 10 {
            lastMunchSpeech = now
            say(["Uh oh, a bug is munching the veggies! Feed it!", "Nom nom! Quick, give that bug a berry!"].randomElement()!)
        }
    }

    /// The bug took a nibble, got full and wanders off. The veggie shrinks a little, then regrows.
    private func finishMunching(_ bug: Bug) {
        bug.leaving = true
        bug.munchingSince = nil
        bug.pips.removeAllChildren()
        bugs.removeAll { $0 === bug }
        bug.node.run(.sequence([.group([.moveBy(x: H * 0.4, y: -H * 0.05, duration: 1.6), .fadeOut(withDuration: 1.6)]),
                                .removeFromParent()]))
        let veggie = veggies[bug.row]
        veggie.removeAction(forKey: "wobble")
        veggie.zRotation = 0
        veggie.run(.sequence([.scale(to: 0.75, duration: 0.2), .wait(forDuration: 2), .scale(to: 1, duration: 0.6)]))
    }

    // MARK: - Waves

    private func checkWaveDone() {
        guard bugsToSpawn == 0, bugs.isEmpty, now >= waveBreakUntil else { return }
        waveBreakUntil = now + 5
        playSound("Glass")
        confetti(count: 60)
        say("Hooray! You saved the garden! Here come more bugs!")
        let banner = makeBanner("🌻 Garden saved!", color: .systemGreen)
        banner.position = CGPoint(x: W / 2, y: H * 0.55)
        addChild(banner)
        banner.setScale(0.3)
        banner.run(.sequence([.scale(to: 1, duration: 0.3), .wait(forDuration: 3.5), .fadeOut(withDuration: 0.4), .removeFromParent()]))
        seeds += 2
        updateSeedPill()
        wave += 1
        wavePill.text = "Wave \(wave)"
        wavePill.position.x = 96 + wavePill.calculateAccumulatedFrame().width / 2
        startWave()
    }

    private func nudge(pose: PoseFrame) {
        guard pose.peopleCount > 0, now - lastNudge > 12, now >= waveBreakUntil else { return }
        let planted = flowers.joined().compactMap { $0 }.count
        if seeds > 0 && planted < rows * columns {
            lastNudge = now
            say(["Touch a dirt patch to plant!", "Plant a flower in the dirt!"].randomElement()!)
        } else if !bugs.isEmpty && now - jumper.lastJump > 15 && planted > 0 {
            lastNudge = now
            say(["Jump for a berry blast!", "Big jump! Berry blast!"].randomElement()!)
        }
    }

    // MARK: - Effects

    private func sparkle(at point: CGPoint, emoji: String) {
        let s = makeLabel(emoji, size: 0.05)
        s.position = point
        s.zPosition = 35
        addChild(s)
        s.run(.sequence([.group([.moveBy(x: 0, y: H * 0.08, duration: 0.6), .fadeOut(withDuration: 0.6)]), .removeFromParent()]))
    }

    private func playSound(_ name: String) {
        guard !Snapshot.isActive else { return }
        guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sounds.append(sound)
        if sounds.count > 6 { sounds.removeFirst() }
        sound.play()
    }
}
