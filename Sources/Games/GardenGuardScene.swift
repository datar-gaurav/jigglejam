import SpriteKit
import AppKit

/// Garden Guard: a lane-defense game. Silly zombies shuffle down five garden lanes toward the
/// veggies at the bottom. Catch falling seeds and eggs, touch an empty dirt patch to plant, and
/// your plants throw food up the lane: sunflowers toss berries, hens (planted from eggs) throw
/// eggs, which fill a tummy twice as much. A full zombie is happy and floats away with a heart.
/// Touching a zombie feeds it too, and a jump makes every plant throw a blast.
///
/// Made for little kids: nothing can be lost. A zombie that reaches the veggies takes a nibble,
/// gets full and wanders off; the veggie grows back. Every wave ends in a party.
final class GardenGuardScene: GameScene {
    // Layout (fractions of the scene). Lanes run top to bottom; rows count up from the veggies.
    private let lanes = 5
    private let rows = 3
    private let laneLeft: CGFloat = 0.1        // of width
    private let laneRight: CGFloat = 0.9
    private let rowCenters: [CGFloat] = [0.29, 0.45, 0.61]   // of height, bottom row first
    private let rowHeight: CGFloat = 0.16
    private let veggieY: CGFloat = 0.1
    private let stopY: CGFloat = 0.2            // zombies stop here to nibble
    private let lawnTop: CGFloat = 0.8          // the hedge zombies come out of

    // Tuning
    private let plantDwell: TimeInterval = 0.35   // hand held over a patch this long plants it
    private let throwSpeed: CGFloat = 1.1         // screen heights per second
    private let touchFeedCooldown: TimeInterval = 0.45
    private let munchTime: TimeInterval = 2.2

    private enum ZombieKind {
        case walker, runner, slowpoke, big
        var emoji: String {
            switch self { case .walker, .big: "🧟"; case .runner: "🧟‍♀️"; case .slowpoke: "🧟‍♂️" }
        }
        /// How many berries it takes to fill this zombie up.
        var hunger: Int {
            switch self { case .walker: 3; case .runner: 2; case .slowpoke: 5; case .big: 8 }
        }
        /// Seconds to walk down the whole garden.
        var crossing: CGFloat {
            switch self { case .walker: 30; case .runner: 21; case .slowpoke: 38; case .big: 46 }
        }
        var scale: CGFloat { self == .big ? 1.4 : 1 }
    }

    private final class Zombie {
        let kind: ZombieKind
        let lane: Int
        let node: SKNode
        let body: SKLabelNode
        let pips: SKNode
        var hunger: Int
        var speedScale: CGFloat
        var lastTouchFeed: TimeInterval = -10
        var munchingSince: TimeInterval?
        var leaving = false
        init(kind: ZombieKind, lane: Int, node: SKNode, body: SKLabelNode, pips: SKNode, speedScale: CGFloat) {
            self.kind = kind; self.lane = lane; self.node = node; self.body = body; self.pips = pips
            hunger = kind.hunger; self.speedScale = speedScale
        }
    }

    /// What a dirt patch grows: a sunflower from a seed, a hen from an egg.
    private enum PlantKind {
        case sunflower, hen
        var emoji: String { self == .sunflower ? "🌻" : "🐔" }
        var ammo: String { self == .sunflower ? "🫐" : "🥚" }
        /// How much one throw feeds.
        var power: Int { self == .sunflower ? 1 : 2 }
        var interval: TimeInterval { self == .sunflower ? 1.6 : 2.1 }
    }

    private final class Plant {
        let lane, row: Int
        let kind: PlantKind
        let node: SKLabelNode
        var cooldown: TimeInterval
        var ready = false
        init(lane: Int, row: Int, kind: PlantKind, node: SKLabelNode, cooldown: TimeInterval) {
            self.lane = lane; self.row = row; self.kind = kind; self.node = node; self.cooldown = cooldown
        }
    }

    private final class Shot {
        let lane: Int
        let power: Int
        let node: SKNode
        init(lane: Int, power: Int, node: SKNode) { self.lane = lane; self.power = power; self.node = node }
    }

    private final class Pickup {
        let node: SKNode
        let baseX: CGFloat
        let isEgg: Bool
        var phase: CGFloat
        init(node: SKNode, baseX: CGFloat, isEgg: Bool, phase: CGFloat) {
            self.node = node; self.baseX = baseX; self.isEgg = isEgg; self.phase = phase
        }
    }

    private let jumper = JumpDetector()
    private var now: TimeInterval = 0

    // Game state
    private var wave = 1
    private var seeds = 2
    private var eggs = 0
    private var pickupsDropped = 0
    private var fed = 0
    private var zombiesToSpawn = 0
    private var spawnTimer: TimeInterval = 6
    private var pickupTimer: TimeInterval = 2.5
    private var waveBreakUntil: TimeInterval = 0
    private var lastNudge: TimeInterval = 0
    private var lastMunchSpeech: TimeInterval = -20
    private var lastSeedAsk: TimeInterval = -20
    private var saidJumpTip = false
    private var saidSeedTip = false
    private var saidEggTip = false

    private var zombies: [Zombie] = []
    private var plants: [[Plant?]] = []          // [row][lane]
    private var shots: [Shot] = []
    private var pickups: [Pickup] = []
    private var dwell: [[TimeInterval]] = []

    // Nodes
    private let field = SKNode()
    private var patches: [[SKShapeNode]] = []
    private var veggies: [SKLabelNode] = []
    private var handMarkers: [SKShapeNode] = []
    private lazy var fedPill = makeScorePill("❤️ 0")
    private lazy var seedPill = HUDPill("🌰 2", tint: NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.13, alpha: 1))
    private lazy var wavePill = HUDPill("Wave 1")
    private lazy var coachPill = HUDPill("", tint: .systemGreen)
    private var sounds: [NSSound] = []

    private var W: CGFloat { size.width }
    private var H: CGFloat { size.height }
    private var handRadius: CGFloat { H * 0.05 }
    private var laneWidth: CGFloat { (laneRight - laneLeft) * W / CGFloat(lanes) }
    private var plantedCount: Int { plants.joined().compactMap { $0 }.count }

    override var debugText: String { "seeds \(seeds)  eggs \(eggs)  zombies \(zombies.count)  wave \(wave)" }

    override func trackingDidResume() {
        jumper.reset()
        for r in dwell.indices { for l in dwell[r].indices { dwell[r][l] = 0 } }
    }

    // MARK: - Setup

    override func didMove(to view: SKView) {
        backgroundColor = NSColor(calibratedRed: 0.45, green: 0.72, blue: 0.3, alpha: 1)
        plants = Array(repeating: Array(repeating: nil, count: lanes), count: rows)
        dwell = Array(repeating: Array(repeating: 0, count: lanes), count: rows)
        addChild(field)
        for pill in [seedPill, wavePill, coachPill] { pill.zPosition = 40; addChild(pill) }
        addChild(fedPill)
        buildField()
        startWave()
        coach("👋 Touch a dirt patch to plant!")
        say("Garden Guard! Silly zombies are coming for the veggies. Touch a dirt patch to plant a berry flower!")
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

        // Lawn with one stripe per lane, a hedge along the top and a soil bed for the veggies.
        let lawn = SKShapeNode(rect: CGRect(x: 0, y: 0, width: W, height: lawnTop * H))
        lawn.fillColor = NSColor(calibratedRed: 0.36, green: 0.66, blue: 0.27, alpha: 1)
        lawn.strokeColor = .clear
        lawn.zPosition = -50
        field.addChild(lawn)
        for l in 0..<lanes {
            let stripe = SKShapeNode(rect: CGRect(x: laneLeft * W + CGFloat(l) * laneWidth, y: 0, width: laneWidth, height: lawnTop * H))
            stripe.fillColor = l % 2 == 0 ? NSColor(calibratedRed: 0.47, green: 0.77, blue: 0.33, alpha: 1)
                                          : NSColor(calibratedRed: 0.41, green: 0.71, blue: 0.29, alpha: 1)
            stripe.strokeColor = .clear
            stripe.zPosition = -49
            field.addChild(stripe)
        }
        let bed = SKShapeNode(rect: CGRect(x: 0, y: 0, width: W, height: (veggieY + 0.07) * H))
        bed.fillColor = NSColor(calibratedRed: 0.55, green: 0.37, blue: 0.2, alpha: 1)
        bed.strokeColor = .clear
        bed.zPosition = -45
        field.addChild(bed)
        for i in 0...Int(W / (H * 0.07)) {
            let bush = SKShapeNode(circleOfRadius: H * .random(in: 0.045...0.06))
            bush.fillColor = NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.22, alpha: 1)
            bush.strokeColor = .clear
            bush.position = CGPoint(x: CGFloat(i) * H * 0.07, y: lawnTop * H)
            bush.zPosition = 22 // zombies step out from behind the hedge
            field.addChild(bush)
        }

        // Dirt patches.
        patches = (0..<rows).map { r in
            (0..<lanes).map { l in
                let patch = SKShapeNode(ellipseOf: CGSize(width: laneWidth * 0.72, height: rowHeight * H * 0.62))
                patch.fillColor = NSColor(calibratedRed: 0.55, green: 0.37, blue: 0.2, alpha: 1)
                patch.strokeColor = NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.13, alpha: 1)
                patch.lineWidth = 4
                patch.position = cellCenter(lane: l, row: r, lift: -0.22)
                patch.zPosition = -30
                field.addChild(patch)
                return patch
            }
        }

        // Veggies to protect, one at the bottom of each lane.
        let veggieEmoji = ["🥕", "🥬", "🍅", "🌽", "🥦"]
        veggies = (0..<lanes).map { l in
            let v = makeLabel(veggieEmoji[l % veggieEmoji.count], size: 0.11)
            v.position = CGPoint(x: laneX(l), y: veggieY * H)
            v.zPosition = 5
            field.addChild(v)
            return v
        }

        // Keep the plants where they are, at the new size.
        for p in plants.joined().compactMap({ $0 }) {
            p.node.fontSize = H * (p.ready ? 0.1 : 0.08)
            field.addChild(p.node)
            p.node.position = cellCenter(lane: p.lane, row: p.row)
        }
        refreshPatches()

        placeScorePill(fedPill)
        seedPill.height = H * 0.085
        placeSeedPill()
        wavePill.height = H * 0.06
        placeWavePill()
        coachPill.height = H * 0.07
        coachPill.position = CGPoint(x: W / 2, y: H * 0.76)
    }

    private func laneX(_ lane: Int) -> CGFloat { laneLeft * W + (CGFloat(lane) + 0.5) * laneWidth }

    private func cellCenter(lane: Int, row: Int, lift: CGFloat = 0) -> CGPoint {
        CGPoint(x: laneX(lane), y: (rowCenters[row] + rowHeight * lift) * H)
    }

    /// Lower on screen = nearer = drawn in front.
    private func depth(_ y: CGFloat) -> CGFloat { 20 - y / H * 6 }

    private func placeSeedPill() {
        seedPill.position = CGPoint(x: W - H * 0.04 - seedPill.calculateAccumulatedFrame().width / 2, y: H - H * 0.095)
    }

    private func placeWavePill() {
        // Left side, clear of the close button in the top-left corner.
        wavePill.position = CGPoint(x: 96 + wavePill.calculateAccumulatedFrame().width / 2, y: H - H * 0.085)
    }

    private func refreshPatches() {
        for r in 0..<rows { for l in 0..<lanes {
            patches[r][l].glowWidth = 0
            patches[r][l].alpha = plants[r][l] == nil ? 1 : 0.55
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
        updateHandMarkers(handPoints(pose))

        if jumper.update(pose, now: now) { blast() }
        if jumper.easedJustNow { say("Little jumps work too!") }

        spawnPickups(dt: dt)
        movePickups(dt: CGFloat(dt))
        updatePlanting(dt: dt)
        spawnZombies(dt: dt)
        updatePlants(dt: dt)
        moveShots(dt: CGFloat(dt))
        moveZombies(dt: CGFloat(dt))
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

    // MARK: - Seeds and eggs

    private func spawnPickups(dt: TimeInterval) {
        guard now >= waveBreakUntil else { return }
        pickupTimer -= dt
        guard pickupTimer <= 0, pickups.count < 3 else { return }
        // Pickups come faster while the garden is empty, so there's always something to plant.
        let planted = plantedCount
        pickupTimer = planted < 3 ? .random(in: 3...4.5) : .random(in: 5...7)

        // Once a flower is up, every third pickup is an egg (and the first one comes right away).
        pickupsDropped += 1
        let isEgg = planted > 0 && ((eggs == 0 && !saidEggTip) || pickupsDropped % 3 == 0)
        let x = W * .random(in: 0.12...0.88)
        dropPickup(isEgg: isEgg, at: CGPoint(x: x, y: H + H * 0.06), phase: .random(in: 0...(2 * .pi)))
    }

    /// A glowing seed or egg that floats down for the child to catch.
    private func dropPickup(isEgg: Bool, at point: CGPoint, phase: CGFloat) {
        let node = SKNode()
        let glow = SKShapeNode(circleOfRadius: H * 0.055)
        glow.fillColor = (isEgg ? NSColor.white : NSColor.systemYellow).withAlphaComponent(0.45)
        glow.strokeColor = NSColor.white.withAlphaComponent(0.8)
        glow.lineWidth = 3
        node.addChild(glow)
        glow.run(.repeatForever(.sequence([.scale(to: 1.15, duration: 0.5), .scale(to: 1, duration: 0.5)])))
        node.addChild(makeLabel(isEgg ? "🥚" : "🌰", size: 0.06))
        node.position = point
        node.zPosition = 26
        addChild(node)
        pickups.append(Pickup(node: node, baseX: point.x, isEgg: isEgg, phase: phase))
    }

    private func movePickups(dt: CGFloat) {
        let touch = visibleHands
        for p in pickups {
            p.phase += dt * 1.6
            let y = p.node.position.y - H * dt / 9 // about 9 s to fall
            p.node.position = CGPoint(x: p.baseX + sin(p.phase) * H * 0.04, y: y)
            if touch.contains(where: { hypot($0.x - p.node.position.x, $0.y - p.node.position.y) < handRadius + H * 0.06 }) {
                catchPickup(p)
            } else if y < -H * 0.06 {
                p.node.removeFromParent()
                pickups.removeAll { $0 === p }
            }
        }
    }

    private func catchPickup(_ p: Pickup) {
        pickups.removeAll { $0 === p }
        if p.isEgg { eggs += 1 } else { seeds += 1 }
        updateSeedPill()
        playSound("Tink")
        sparkle(at: p.node.position, emoji: "✨")
        p.node.run(.sequence([.group([.move(to: seedPill.position, duration: 0.4), .scale(to: 0.4, duration: 0.4)]),
                              .removeFromParent()]))
        if coachPill.text.hasPrefix("🌰 Catch a falling") { coach(nil) }
        if p.isEgg && !saidEggTip {
            saidEggTip = true
            coach("🥚 Plant the egg to hatch a hen!")
            say("An egg! Plant it, and a hen will throw eggs at the zombies!")
        } else if !p.isEgg && !saidSeedTip {
            saidSeedTip = true
            say("You caught a seed! Now plant it in the dirt!")
        }
    }

    private func updateSeedPill() {
        seedPill.text = eggs > 0 ? "🌰 \(seeds)  🥚 \(eggs)" : "🌰 \(seeds)"
        placeSeedPill()
        seedPill.pulse()
    }

    // MARK: - Planting

    private func updatePlanting(dt: TimeInterval) {
        let touch = visibleHands
        let canPlant = seeds + eggs > 0
        for r in 0..<rows { for l in 0..<lanes {
            let center = cellCenter(lane: l, row: r)
            let over = plants[r][l] == nil && touch.contains {
                abs($0.x - center.x) < laneWidth * 0.5 && abs($0.y - center.y) < rowHeight * H * 0.5
            }
            patches[r][l].glowWidth = over && canPlant ? 6 : 0
            patches[r][l].strokeColor = over ? (canPlant ? .systemYellow : NSColor.white.withAlphaComponent(0.6))
                                             : NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.13, alpha: 1)
            dwell[r][l] = over ? dwell[r][l] + dt : 0
            if dwell[r][l] >= plantDwell {
                dwell[r][l] = 0
                if seeds + eggs > 0 { plant(lane: l, row: r) } else { askForSeeds() }
            }
        } }
    }

    /// Plants an egg (a hen) when there is one, otherwise a seed (a sunflower).
    private func plant(lane: Int, row: Int) {
        let kind: PlantKind = eggs > 0 ? .hen : .sunflower
        if kind == .hen { eggs -= 1 } else { seeds -= 1 }
        updateSeedPill()
        let node = makeLabel(kind == .hen ? "🥚" : "🌱", size: 0.08)
        node.position = cellCenter(lane: lane, row: row)
        node.zPosition = depth(node.position.y)
        field.addChild(node)
        let plant = Plant(lane: lane, row: row, kind: kind, node: node, cooldown: 0.6)
        plants[row][lane] = plant
        refreshPatches()
        playSound("Pop")
        sparkle(at: node.position, emoji: "🌟")

        node.setScale(0.2)
        node.run(.sequence([
            .scale(to: 1, duration: 0.25),
            .wait(forDuration: 0.5),
            .run { [weak self, weak node] in
                guard let self, let node else { return }
                node.text = kind.emoji
                node.fontSize = self.H * 0.1
                plant.ready = true
                if kind == .hen { self.sparkle(at: node.position, emoji: "🐣") }
            },
            .scale(to: 1.25, duration: 0.12), .scale(to: 1, duration: 0.15)
        ]))
        node.run(.repeatForever(.sequence([.rotate(toAngle: 0.06, duration: 0.8), .rotate(toAngle: -0.06, duration: 0.8)])))

        if kind == .hen {
            if coachPill.text.hasPrefix("🥚") { coach(nil) }
            say(["A hen! Bawk bawk! Egg time!", "Cluck cluck! Your hen throws eggs!"].randomElement()!)
        } else if plantedCount == 1 {
            coach("🌰 Catch seeds to plant more")
            say("Hooray! Your flower throws berries at hungry zombies!")
        } else if plantedCount == 3 && !saidJumpTip {
            saidJumpTip = true
            coach("🦘 Jump for a food blast!")
            say("Now jump! Jumping makes every plant throw!")
        } else {
            say(["Planted!", "Grow, flower, grow!", "Another flower!"].randomElement()!)
        }
    }

    private func askForSeeds() {
        guard now - lastSeedAsk > 6 else { return }
        lastSeedAsk = now
        say("You need a seed! Catch a falling seed first.")
        coach("🌰 Catch a falling seed!")
    }

    // MARK: - Throwing

    private func updatePlants(dt: TimeInterval) {
        for p in plants.joined().compactMap({ $0 }) where p.ready {
            p.cooldown -= dt
            guard p.cooldown <= 0 else { continue }
            let y = p.node.position.y
            let target = zombies.contains {
                $0.lane == p.lane && !$0.leaving && $0.node.position.y > y && $0.node.position.y < lawnTop * H
            }
            guard target else { continue }
            p.cooldown = p.kind.interval
            throwFood(from: p)
        }
    }

    private func throwFood(from plant: Plant, delay: TimeInterval = 0) {
        let food = makeLabel(plant.kind.ammo, size: 0.05)
        food.position = CGPoint(x: plant.node.position.x, y: plant.node.position.y + H * 0.05)
        food.zPosition = 24
        let shot = Shot(lane: plant.lane, power: plant.kind.power, node: food)
        addChild(food)
        food.run(.repeatForever(.rotate(byAngle: .pi * 2, duration: 0.6)))
        if delay > 0 {
            food.alpha = 0
            food.run(.sequence([.wait(forDuration: delay), .run { [weak self] in
                food.alpha = 1
                self?.shots.append(shot)
            }]))
        } else {
            shots.append(shot)
        }
        guard plant.node.action(forKey: "throw") == nil else { return }
        plant.node.run(.sequence([.scaleX(to: 0.9, y: 1.15, duration: 0.08), .scale(to: 1, duration: 0.12)]), withKey: "throw")
    }

    private func moveShots(dt: CGFloat) {
        for s in shots {
            s.node.position.y += throwSpeed * H * dt
            let hit = zombies.first {
                $0.lane == s.lane && !$0.leaving && abs($0.node.position.y - s.node.position.y) < H * 0.06 * $0.kind.scale
            }
            if let hit {
                if s.power > 1 { sparkle(at: s.node.position, emoji: "🍳") }
                feed(hit, at: s.node.position, amount: s.power)
                remove(s)
            } else if s.node.position.y > H + H * 0.1 {
                remove(s)
            }
        }
    }

    private func remove(_ s: Shot) {
        s.node.removeFromParent()
        shots.removeAll { $0 === s }
    }

    /// Jump: every plant throws a quick triple, even with no zombie in its lane.
    private func blast() {
        let ready = plants.joined().compactMap { $0 }.filter(\.ready)
        playSound("Bottle")
        guard !ready.isEmpty else { return }
        for p in ready {
            for k in 0..<3 { throwFood(from: p, delay: Double(k) * 0.15) }
            p.cooldown = p.kind.interval
        }
        let banner = makeBanner("💥 Food blast!", color: .systemPurple, height: 0.1)
        banner.position = CGPoint(x: W / 2, y: H * 0.68)
        addChild(banner)
        banner.setScale(0.4)
        banner.run(.sequence([.scale(to: 1, duration: 0.2), .wait(forDuration: 0.8), .fadeOut(withDuration: 0.3), .removeFromParent()]))
        if coachPill.text.hasPrefix("🦘") { coach(nil) }
    }

    // MARK: - Zombies

    private func startWave() {
        zombiesToSpawn = 5 + wave * 2
        spawnTimer = wave == 1 ? 6 : 2.5
    }

    private func spawnZombies(dt: TimeInterval) {
        guard zombiesToSpawn > 0, now >= waveBreakUntil else { return }
        spawnTimer -= dt
        guard spawnTimer <= 0 else { return }
        spawnTimer = max(2.2, 5.5 - Double(wave) * 0.6) * .random(in: 0.8...1.2)
        zombiesToSpawn -= 1

        // Early on, send zombies to lanes that have a plant, so the first fights are wins.
        let defended = (0..<lanes).filter { l in (0..<rows).contains { plants[$0][l] != nil } }
        let lane = (wave == 1 && !defended.isEmpty && Bool.random()) ? defended.randomElement()! : Int.random(in: 0..<lanes)
        let kind: ZombieKind
        if wave >= 3 && zombiesToSpawn == 0 {
            kind = .big // a big hungry zombie ends each later wave
        } else if wave == 1 {
            kind = .walker
        } else {
            kind = [.walker, .walker, .runner, .slowpoke].randomElement()!
        }

        let node = SKNode()
        node.position = CGPoint(x: laneX(lane), y: (lawnTop + 0.02) * H)
        node.zPosition = depth(node.position.y)
        let body = makeLabel(kind.emoji, size: 0.12 * kind.scale)
        node.addChild(body)
        let pips = SKNode()
        pips.position = CGPoint(x: 0, y: H * 0.085 * kind.scale)
        node.addChild(pips)
        addChild(node)
        let zombie = Zombie(kind: kind, lane: lane, node: node, body: body, pips: pips,
                            speedScale: 1 + CGFloat(wave - 1) * 0.07)
        zombies.append(zombie)
        drawPips(zombie)
        node.alpha = 0
        node.run(.fadeIn(withDuration: 0.5))
        body.run(.repeatForever(.sequence([.rotate(toAngle: 0.1, duration: 0.35), .rotate(toAngle: -0.1, duration: 0.35)])),
                 withKey: "shuffle")

        if fed == 0 && zombies.count == 1 && wave == 1 {
            say("Here comes a silly zombie! It's hungry. Feed it berries!")
        } else if kind == .big {
            say("Whoa, a big zombie! It's super hungry!")
        }
    }

    /// Little empty hearts above a zombie: one per berry it still wants.
    private func drawPips(_ zombie: Zombie) {
        zombie.pips.removeAllChildren()
        let spacing = H * (zombie.hunger > 4 ? 0.022 : 0.028)
        for i in 0..<zombie.hunger {
            let pip = RoundedLabel("🤍", size: H * 0.024)
            pip.shadowed = false
            pip.position = CGPoint(x: (CGFloat(i) - CGFloat(zombie.hunger - 1) / 2) * spacing, y: 0)
            zombie.pips.addChild(pip)
        }
    }

    private func moveZombies(dt: CGFloat) {
        let touch = visibleHands
        let stop = stopY * H
        for z in zombies where !z.leaving {
            // Touching a zombie feeds it, too.
            if now - z.lastTouchFeed > touchFeedCooldown,
               touch.contains(where: { hypot($0.x - z.node.position.x, $0.y - z.node.position.y) < handRadius + H * 0.05 * z.kind.scale }) {
                z.lastTouchFeed = now
                feed(z, at: z.node.position)
                if z.leaving { continue }
            }

            if let since = z.munchingSince {
                if now - since > munchTime { finishMunching(z) }
                continue
            }
            let speed = ((lawnTop + 0.02) * H - stop) / z.kind.crossing * z.speedScale
            z.node.position.y -= speed * dt
            z.node.zPosition = depth(z.node.position.y)
            if z.node.position.y <= stop { startMunching(z) }
        }
    }

    private func feed(_ zombie: Zombie, at point: CGPoint, amount: Int = 1) {
        guard !zombie.leaving else { return }
        zombie.hunger -= amount
        playSound("Pop")
        sparkle(at: point, emoji: "😋")
        zombie.body.run(.sequence([.scaleX(to: 1.2, y: 0.85, duration: 0.07), .scale(to: 1, duration: 0.12)]))
        // A fed zombie is pushed back a little, so feeding feels like it matters.
        if zombie.munchingSince == nil { zombie.node.run(.moveBy(x: 0, y: H * 0.025, duration: 0.15)) }
        if zombie.hunger <= 0 {
            happyZombie(zombie)
        } else {
            drawPips(zombie)
        }
    }

    /// Full and happy: the zombie floats away with a heart, often leaving an egg or a seed behind.
    private func happyZombie(_ zombie: Zombie) {
        zombie.leaving = true
        zombie.munchingSince = nil
        zombies.removeAll { $0 === zombie }
        fed += 1
        fedPill.text = "❤️ \(fed)"
        fedPill.pulse()
        zombie.pips.removeAllChildren()
        zombie.body.removeAction(forKey: "shuffle")
        zombie.body.zRotation = 0
        let heart = makeLabel("❤️", size: 0.06)
        heart.position = CGPoint(x: 0, y: H * 0.09 * zombie.kind.scale)
        zombie.node.addChild(heart)
        heart.run(.repeatForever(.sequence([.scale(to: 1.2, duration: 0.2), .scale(to: 1, duration: 0.2)])))
        zombie.node.run(.sequence([
            .group([.moveBy(x: H * 0.1, y: H * 0.35, duration: 1.4), .fadeOut(withDuration: 1.4)]),
            .removeFromParent()
        ]))

        let drop = Int.random(in: 0..<6)
        if zombie.kind == .big || drop < 2 {
            dropPickup(isEgg: true, at: pickupSpot(near: zombie.node.position), phase: 0)
        } else if drop < 4 {
            dropPickup(isEgg: false, at: pickupSpot(near: zombie.node.position), phase: 0)
        }
        if fed == 1 {
            say("Yum! That zombie is full and happy!")
        } else if fed % 5 == 0 {
            say(["\(fed) happy zombies!", "Yummy! \(fed) zombies fed!", "Great gardening!"].randomElement()!)
        } else if zombie.kind == .big {
            say("The big zombie is full! Bye bye!")
        }
    }

    private func pickupSpot(near point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, W * 0.12), W * 0.88), y: min(point.y + H * 0.12, lawnTop * H))
    }

    private func startMunching(_ zombie: Zombie) {
        zombie.munchingSince = now
        zombie.node.position.y = stopY * H
        let veggie = veggies[zombie.lane]
        veggie.run(.repeat(.sequence([.rotate(toAngle: 0.12, duration: 0.1), .rotate(toAngle: -0.12, duration: 0.1)]), count: 10),
                   withKey: "wobble")
        let nom = makeLabel("nom nom!", size: 0.04)
        nom.position = CGPoint(x: laneX(zombie.lane) + laneWidth * 0.32, y: (stopY + 0.04) * H)
        nom.zPosition = 30
        addChild(nom)
        nom.run(.sequence([.wait(forDuration: munchTime), .fadeOut(withDuration: 0.3), .removeFromParent()]))
        if now - lastMunchSpeech > 10 {
            lastMunchSpeech = now
            say(["Uh oh, a zombie is munching the veggies! Feed it!", "Nom nom! Quick, give that zombie a berry!"].randomElement()!)
        }
    }

    /// The zombie took a nibble, got full and wanders off. The veggie shrinks a little, then regrows.
    private func finishMunching(_ zombie: Zombie) {
        zombie.leaving = true
        zombie.munchingSince = nil
        zombie.pips.removeAllChildren()
        zombies.removeAll { $0 === zombie }
        let side: CGFloat = zombie.node.position.x < W / 2 ? -1 : 1
        zombie.node.run(.sequence([.group([.moveBy(x: side * W * 0.4, y: 0, duration: 1.8), .fadeOut(withDuration: 1.8)]),
                                   .removeFromParent()]))
        let veggie = veggies[zombie.lane]
        veggie.removeAction(forKey: "wobble")
        veggie.zRotation = 0
        veggie.run(.sequence([.scale(to: 0.75, duration: 0.2), .wait(forDuration: 2), .scale(to: 1, duration: 0.6)]))
    }

    // MARK: - Waves

    private func checkWaveDone() {
        guard zombiesToSpawn == 0, zombies.isEmpty, now >= waveBreakUntil else { return }
        waveBreakUntil = now + 5
        playSound("Glass")
        confetti(count: 60)
        say("Hooray! You saved the garden! Here come more zombies!")
        let banner = makeBanner("🌻 Garden saved!", color: .systemGreen)
        banner.position = CGPoint(x: W / 2, y: H * 0.5)
        addChild(banner)
        banner.setScale(0.3)
        banner.run(.sequence([.scale(to: 1, duration: 0.3), .wait(forDuration: 3.5), .fadeOut(withDuration: 0.4), .removeFromParent()]))
        seeds += 1
        eggs += 1
        updateSeedPill()
        wave += 1
        wavePill.text = "Wave \(wave)"
        placeWavePill()
        startWave()
    }

    private func nudge(pose: PoseFrame) {
        guard pose.peopleCount > 0, now - lastNudge > 12, now >= waveBreakUntil else { return }
        let planted = plantedCount
        if seeds + eggs > 0 && planted < rows * lanes {
            lastNudge = now
            say(["Touch a dirt patch to plant!", "Plant something in the dirt!"].randomElement()!)
        } else if !zombies.isEmpty && now - jumper.lastJump > 15 && planted > 0 {
            lastNudge = now
            say(["Jump for a food blast!", "Big jump! Feed the zombies!"].randomElement()!)
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
