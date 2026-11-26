import SpriteKit
import AppKit

/// Word Train: an early spelling and reading game. A train pulls in with empty carriages and a
/// picture (🐱). Letter boxes float around the picture; touch the right one and it flies into
/// its carriage, and the game says the letter's name. When the word is full it is spelled out
/// and read ("see, ay, tee… cat!") as each carriage lights up left to right, then marching in
/// place drives the train away and the next one arrives.
///
/// Levels: the first letter only ("cat starts with c"), then one missing letter anywhere, then
/// the whole word, then four-letter words. Letters are lowercase and spoken by name.
///
/// Made for little kids: nothing can be lost and there is no timer. A wrong letter just says
/// its name and wobbles; after a couple of misses the right box glows. If nobody marches, the
/// train leaves on its own after a while.
final class WordTrainScene: GameScene {
    private typealias Words = WordTrainWords

    // Layout (fractions of the scene height unless noted)
    private let trackY: CGFloat = 0.1
    private let carWidth: CGFloat = 0.19
    private let carHeight: CGFloat = 0.15
    private let carGap: CGFloat = 0.025
    private let engineWidth: CGFloat = 0.27
    private let wheelRadius: CGFloat = 0.032
    private let slotSize: CGFloat = 0.115
    private let boxSize: CGFloat = 0.13
    private let pictureY: CGFloat = 0.58
    /// Where letter boxes float, as fractions of (width, height): three each side of the picture.
    private let boxSpots: [CGPoint] = [
        CGPoint(x: 0.12, y: 0.74), CGPoint(x: 0.27, y: 0.6), CGPoint(x: 0.12, y: 0.44),
        CGPoint(x: 0.88, y: 0.74), CGPoint(x: 0.73, y: 0.6), CGPoint(x: 0.88, y: 0.44),
    ]

    // Tuning
    private let touchDwell: TimeInterval = 0.12
    private let wrongCooldown: TimeInterval = 2.2
    private let autoDepart: TimeInterval = 8
    private let nudgeEvery: TimeInterval = 13

    private enum Phase { case arriving, building, reading, waitingToGo, departing, levelUp }

    private final class LetterBox {
        let letter: Character
        let node: SKNode
        let content: SKNode
        let glow: SKShapeNode
        let spot: Int
        var dwell: TimeInterval = 0
        var latched = false
        var lastWrong: TimeInterval = -10
        init(letter: Character, node: SKNode, content: SKNode, glow: SKShapeNode, spot: Int) {
            self.letter = letter; self.node = node; self.content = content; self.glow = glow; self.spot = spot
        }
    }

    private let moves = Locomotion()
    private var rng = SystemRandomNumberGenerator()
    private var now: TimeInterval = 0

    // Game state
    private var phase: Phase = .arriving
    private var level: Words.Level = .firstLetter
    private var wordsAtLevel = 0
    private var wordsDone = 0
    private var queue: [Words.Word] = []
    private var lastWord: String?
    private var puzzle: Words.Puzzle?
    private var step = 0                 // index into puzzle.missing
    private var filled: [Bool] = []
    private var wrongTries = 0
    private var lastProgress: TimeInterval = 0
    private var lastNudge: TimeInterval = 0
    private var waitingSince: TimeInterval = 0
    private var autoDriving = false
    private var tootBoost: TimeInterval = 0
    private var smokeTimer: TimeInterval = 0
    private var saidMarchTip = false
    private var firstWord = true

    // Nodes
    private let field = SKNode()
    private let director = SKNode()      // runs timed sequences; pauses with the game
    private let train = SKNode()
    private var slots: [SKShapeNode] = []
    private var slotLabels: [RoundedLabel] = []
    private var wheels: [(node: SKNode, radius: CGFloat)] = []
    private var chimneyTop = CGPoint.zero
    private let pictureCard = SKNode()
    private var pictureLabel: RoundedLabel?
    private var rider: SKLabelNode?
    private var boxes: [LetterBox] = []
    private var handMarkers: [SKShapeNode] = []
    private lazy var wordsPill = makeScorePill("🚃 0")
    private lazy var levelPill = HUDPill("Level 1")
    private lazy var coachPill = HUDPill("", tint: .systemIndigo)
    private var sounds: [NSSound] = []

    private var W: CGFloat { size.width }
    private var H: CGFloat { size.height }
    private var handRadius: CGFloat { H * 0.05 }
    private var trainWidth: CGFloat {
        CGFloat(puzzle?.letters.count ?? 3) * (carWidth + carGap) * H + engineWidth * H
    }
    private var trainRestX: CGFloat { (W - trainWidth) / 2 }
    private var trainBaseY: CGFloat { (trackY + wheelRadius) * H }

    override var debugText: String {
        "\(phase) word \(puzzle?.word.text ?? "-") step \(step) level \(level.rawValue) pace \(String(format: "%.2f", moves.pace))"
    }

    override func trackingDidResume() {
        moves.reset()
        for b in boxes { b.dwell = 0; b.latched = false }
    }

    // MARK: - Setup

    override func didMove(to view: SKView) {
        backgroundColor = NSColor(calibratedRed: 0.55, green: 0.8, blue: 1, alpha: 1)
        addChild(field)
        addChild(director)
        addChild(train)
        pictureCard.zPosition = 8
        addChild(pictureCard)
        for pill in [levelPill, coachPill] { pill.zPosition = 40; addChild(pill) }
        addChild(wordsPill)
        coachPill.alpha = 0
        layoutStatic()
        nextWord()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard oldSize != size, field.parent != nil else { return }
        layoutStatic()
        // Rebuild what's on screen at the new size and carry on from a calm point.
        guard let puzzle else { return }
        director.removeAllActions()
        train.removeAllActions()
        buildTrain(for: puzzle)
        train.position = CGPoint(x: trainRestX, y: trainBaseY)
        showPicture(puzzle.word.picture, animated: false)
        switch phase {
        case .arriving, .building:
            let remaining = boxes.map(\.letter)
            clearBoxes(animated: false)
            spawnBoxes(remaining, animated: false)
            if phase == .arriving { startBuilding() } else { highlightNextSlot() }
        case .reading, .waitingToGo, .departing:
            clearBoxes(animated: false)
            finishWord()
        case .levelUp:
            clearBoxes(animated: false)
            nextWord()
        }
    }

    /// Sky, hills, ground and track, plus the HUD positions.
    private func layoutStatic() {
        field.removeAllChildren()
        field.addChild(makeGradientBackdrop(top: NSColor(calibratedRed: 0.4, green: 0.7, blue: 1, alpha: 1),
                                            bottom: NSColor(calibratedRed: 0.85, green: 0.95, blue: 1, alpha: 1)))
        // Soft clouds.
        for (x, y, s) in [(0.3, 0.91, 0.9), (0.72, 0.89, 0.8), (0.93, 0.8, 0.7)] as [(CGFloat, CGFloat, CGFloat)] {
            let cloud = SKNode()
            for (dx, dy, r) in [(-0.06, 0.0, 0.045), (0.0, 0.02, 0.06), (0.065, 0.0, 0.045)] as [(CGFloat, CGFloat, CGFloat)] {
                let puff = SKShapeNode(circleOfRadius: r * H * s)
                puff.fillColor = NSColor.white.withAlphaComponent(0.85)
                puff.strokeColor = .clear
                puff.position = CGPoint(x: dx * H * s, y: dy * H * s)
                cloud.addChild(puff)
            }
            cloud.position = CGPoint(x: x * W, y: y * H)
            cloud.zPosition = -90
            field.addChild(cloud)
            cloud.run(.repeatForever(.sequence([.moveBy(x: H * 0.04, y: 0, duration: 6), .moveBy(x: -H * 0.04, y: 0, duration: 6)])))
        }
        // Rolling hills behind the track.
        for (x, r, shade) in [(0.1, 0.32, 0.0), (0.45, 0.4, 0.05), (0.8, 0.34, 0.0), (1.05, 0.3, 0.05)] as [(CGFloat, CGFloat, CGFloat)] {
            let hill = SKShapeNode(circleOfRadius: r * H)
            hill.fillColor = NSColor(calibratedRed: 0.5 - shade, green: 0.78 - shade, blue: 0.38 - shade, alpha: 1)
            hill.strokeColor = .clear
            hill.position = CGPoint(x: x * W, y: (trackY - 0.1) * H)
            hill.zPosition = -80
            field.addChild(hill)
        }
        let ground = SKShapeNode(rect: CGRect(x: 0, y: 0, width: W, height: trackY * H))
        ground.fillColor = NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.27, alpha: 1)
        ground.strokeColor = .clear
        ground.zPosition = -70
        field.addChild(ground)
        // Sleepers and a rail.
        let sleeperW = H * 0.05
        for i in 0...Int(W / (sleeperW * 1.8)) {
            let sleeper = SKShapeNode(rect: CGRect(x: CGFloat(i) * sleeperW * 1.8, y: (trackY - 0.035) * H,
                                                   width: sleeperW, height: H * 0.03), cornerRadius: 3)
            sleeper.fillColor = NSColor(calibratedRed: 0.5, green: 0.33, blue: 0.2, alpha: 1)
            sleeper.strokeColor = .clear
            sleeper.zPosition = -60
            field.addChild(sleeper)
        }
        let rail = SKShapeNode(rect: CGRect(x: 0, y: (trackY - 0.008) * H, width: W, height: H * 0.014))
        rail.fillColor = NSColor(calibratedWhite: 0.45, alpha: 1)
        rail.strokeColor = .clear
        rail.zPosition = -59
        field.addChild(rail)

        placeScorePill(wordsPill)
        levelPill.height = H * 0.06
        placeLevelPill()
        coachPill.height = H * 0.07
        coachPill.position = CGPoint(x: W / 2, y: H * 0.8)
        pictureCard.position = CGPoint(x: W / 2, y: pictureY * H)
    }

    private func placeLevelPill() {
        // Left side, clear of the close button in the top-left corner.
        levelPill.position = CGPoint(x: 96 + levelPill.calculateAccumulatedFrame().width / 2, y: H - H * 0.085)
    }

    private func coach(_ text: String?) {
        coachPill.removeAllActions()
        guard let text else { coachPill.run(.fadeOut(withDuration: 0.3)); return }
        coachPill.text = text
        coachPill.run(.fadeIn(withDuration: 0.3))
    }

    // MARK: - The train

    private let carColors: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink]

    /// Carriages (one per letter) with the engine at the front, facing right. Origin: bottom-left,
    /// at wheel-center height.
    private func buildTrain(for puzzle: Words.Puzzle) {
        train.removeAllChildren()
        slots = []
        slotLabels = []
        wheels = []
        rider = nil
        train.zPosition = 12
        let letters = puzzle.letters
        let cw = carWidth * H, ch = carHeight * H, gap = carGap * H, r = wheelRadius * H
        let floor = r * 0.55

        for (i, letter) in letters.enumerated() {
            let car = SKNode()
            car.position = CGPoint(x: CGFloat(i) * (cw + gap), y: 0)
            train.addChild(car)

            let color = carColors[i % carColors.count]
            let body = SKShapeNode(rect: CGRect(x: 0, y: floor, width: cw, height: ch), cornerRadius: H * 0.02)
            body.fillColor = color
            body.strokeColor = color.shadow(withLevel: 0.35) ?? .black
            body.lineWidth = 3
            car.addChild(body)
            let roof = SKShapeNode(rect: CGRect(x: -H * 0.008, y: floor + ch - H * 0.012, width: cw + H * 0.016, height: H * 0.024),
                                   cornerRadius: H * 0.01)
            roof.fillColor = color.shadow(withLevel: 0.3) ?? .darkGray
            roof.strokeColor = .clear
            car.addChild(roof)

            let slot = SKShapeNode(rectOf: CGSize(width: slotSize * H, height: slotSize * H), cornerRadius: H * 0.02)
            slot.position = CGPoint(x: cw / 2, y: floor + ch / 2 - H * 0.004)
            slot.lineWidth = 4
            car.addChild(slot)
            let label = RoundedLabel("", size: H * 0.09)
            label.shadowed = false
            label.fontColor = NSColor(calibratedWhite: 0.15, alpha: 1)
            label.position = CGPoint(x: 0, y: H * 0.006)
            slot.addChild(label)
            slots.append(slot)
            slotLabels.append(label)
            let isFilled = !puzzle.missing.contains(i) || (filled.indices.contains(i) && filled[i])
            setSlot(i, letter: isFilled ? letter : nil)

            for wx in [0.24, 0.76] as [CGFloat] { car.addChild(makeWheel(radius: r, at: CGPoint(x: wx * cw, y: 0))) }
            // Coupler to the next car (or the engine).
            let coupler = SKShapeNode(rect: CGRect(x: cw, y: floor + H * 0.02, width: gap, height: H * 0.016))
            coupler.fillColor = NSColor(calibratedWhite: 0.25, alpha: 1)
            coupler.strokeColor = .clear
            car.addChild(coupler)
        }

        // Engine.
        let engine = SKNode()
        let ew = engineWidth * H
        engine.position = CGPoint(x: CGFloat(letters.count) * (cw + gap), y: 0)
        train.addChild(engine)
        let red = NSColor(calibratedRed: 0.86, green: 0.18, blue: 0.2, alpha: 1)
        let dark = NSColor(calibratedRed: 0.2, green: 0.18, blue: 0.24, alpha: 1)
        let cab = SKShapeNode(rect: CGRect(x: 0, y: floor, width: ew * 0.42, height: ch * 1.45), cornerRadius: H * 0.015)
        cab.fillColor = red
        cab.strokeColor = red.shadow(withLevel: 0.35) ?? .black
        cab.lineWidth = 3
        engine.addChild(cab)
        let cabRoof = SKShapeNode(rect: CGRect(x: -H * 0.012, y: floor + ch * 1.45 - H * 0.01, width: ew * 0.42 + H * 0.024, height: H * 0.03),
                                  cornerRadius: H * 0.012)
        cabRoof.fillColor = dark
        cabRoof.strokeColor = .clear
        engine.addChild(cabRoof)
        let window = SKShapeNode(rect: CGRect(x: ew * 0.08, y: floor + ch * 0.78, width: ew * 0.26, height: ch * 0.48), cornerRadius: H * 0.012)
        window.fillColor = NSColor(calibratedRed: 0.75, green: 0.9, blue: 1, alpha: 1)
        window.strokeColor = NSColor.white
        window.lineWidth = 3
        engine.addChild(window)
        let boiler = SKShapeNode(rect: CGRect(x: ew * 0.38, y: floor, width: ew * 0.56, height: ch * 0.85), cornerRadius: ch * 0.3)
        boiler.fillColor = red
        boiler.strokeColor = red.shadow(withLevel: 0.35) ?? .black
        boiler.lineWidth = 3
        engine.addChild(boiler)
        for bx in [0.55, 0.75] as [CGFloat] {
            let band = SKShapeNode(rect: CGRect(x: ew * bx, y: floor, width: H * 0.012, height: ch * 0.85))
            band.fillColor = .systemYellow
            band.strokeColor = .clear
            engine.addChild(band)
        }
        let chimney = SKShapeNode(rect: CGRect(x: ew * 0.74, y: floor + ch * 0.8, width: H * 0.04, height: ch * 0.45))
        chimney.fillColor = dark
        chimney.strokeColor = .clear
        engine.addChild(chimney)
        let chimneyCap = SKShapeNode(rect: CGRect(x: ew * 0.74 - H * 0.012, y: floor + ch * 1.2, width: H * 0.064, height: H * 0.022),
                                     cornerRadius: H * 0.008)
        chimneyCap.fillColor = dark
        chimneyCap.strokeColor = .clear
        engine.addChild(chimneyCap)
        chimneyTop = CGPoint(x: engine.position.x + ew * 0.74 + H * 0.02, y: floor + ch * 1.25)
        let lamp = SKShapeNode(circleOfRadius: H * 0.02)
        lamp.fillColor = .systemYellow
        lamp.strokeColor = NSColor.white
        lamp.lineWidth = 2
        lamp.position = CGPoint(x: ew * 0.93, y: floor + ch * 0.6)
        engine.addChild(lamp)
        let catcher = SKShapeNode(path: {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: ew * 0.9, y: floor + H * 0.03))
            p.addLine(to: CGPoint(x: ew * 1.02, y: -r * 0.6))
            p.addLine(to: CGPoint(x: ew * 0.9, y: -r * 0.6))
            p.closeSubpath()
            return p
        }())
        catcher.fillColor = dark
        catcher.strokeColor = .clear
        engine.addChild(catcher)
        engine.addChild(makeWheel(radius: r * 1.45, at: CGPoint(x: ew * 0.21, y: r * 0.45)))
        engine.addChild(makeWheel(radius: r, at: CGPoint(x: ew * 0.56, y: 0)))
        engine.addChild(makeWheel(radius: r, at: CGPoint(x: ew * 0.8, y: 0)))
    }

    private func makeWheel(radius: CGFloat, at point: CGPoint) -> SKNode {
        let wheel = SKShapeNode(circleOfRadius: radius)
        wheel.fillColor = NSColor(calibratedWhite: 0.2, alpha: 1)
        wheel.strokeColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        wheel.lineWidth = 3
        wheel.position = point
        wheel.zPosition = 1
        let spokes = CGMutablePath()
        spokes.move(to: CGPoint(x: -radius * 0.75, y: 0)); spokes.addLine(to: CGPoint(x: radius * 0.75, y: 0))
        spokes.move(to: CGPoint(x: 0, y: -radius * 0.75)); spokes.addLine(to: CGPoint(x: 0, y: radius * 0.75))
        let spoke = SKShapeNode(path: spokes)
        spoke.strokeColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        spoke.lineWidth = 3
        wheel.addChild(spoke)
        let hub = SKShapeNode(circleOfRadius: radius * 0.25)
        hub.fillColor = .systemYellow
        hub.strokeColor = .clear
        wheel.addChild(hub)
        wheels.append((wheel, radius))
        return wheel
    }

    /// Shows a letter in a carriage, or an empty slot waiting for one.
    private func setSlot(_ i: Int, letter: Character?) {
        let slot = slots[i]
        slotLabels[i].text = letter.map(String.init) ?? ""
        slot.fillColor = letter == nil ? NSColor.white.withAlphaComponent(0.45) : .white
        slot.strokeColor = letter == nil ? NSColor.white.withAlphaComponent(0.9) : NSColor(calibratedWhite: 0.85, alpha: 1)
        slot.glowWidth = 0
        slot.removeAction(forKey: "next")
        slot.setScale(1)
    }

    /// The slot the next letter goes in pulses and glows yellow.
    private func highlightNextSlot() {
        guard let puzzle, step < puzzle.missing.count else { return }
        let slot = slots[puzzle.missing[step]]
        slot.strokeColor = .systemYellow
        slot.glowWidth = 5
        slot.run(.repeatForever(.sequence([.scale(to: 1.08, duration: 0.45), .scale(to: 1, duration: 0.45)])), withKey: "next")
    }

    private func slotScenePoint(_ i: Int) -> CGPoint {
        convert(.zero, from: slots[i])
    }

    // MARK: - Picture

    private func showPicture(_ emoji: String, animated: Bool) {
        pictureCard.removeAllChildren()
        pictureCard.removeAllActions()
        pictureCard.alpha = 1
        let side = H * 0.3
        let card = SKShapeNode(rectOf: CGSize(width: side, height: side), cornerRadius: H * 0.05)
        card.fillColor = NSColor.white.withAlphaComponent(0.92)
        card.strokeColor = NSColor.systemYellow
        card.lineWidth = 6
        pictureCard.addChild(card)
        let label = RoundedLabel(emoji, size: H * 0.2)
        label.shadowed = false
        label.position = CGPoint(x: 0, y: H * 0.005)
        pictureCard.addChild(label)
        pictureLabel = label
        label.run(.repeatForever(.sequence([.rotate(toAngle: 0.05, duration: 0.9), .rotate(toAngle: -0.05, duration: 0.9)])))
        if animated {
            pictureCard.setScale(0.2)
            pictureCard.run(.sequence([.scale(to: 1.1, duration: 0.25), .scale(to: 1, duration: 0.12)]))
        } else {
            pictureCard.setScale(1)
        }
    }

    // MARK: - Letter boxes

    private func spawnBoxes(_ letters: [Character], animated: Bool) {
        let spots = Array(boxSpots.indices).shuffled(using: &rng)
        for (k, letter) in letters.enumerated() where k < spots.count {
            let spot = spots[k]
            let node = SKNode()
            node.position = CGPoint(x: boxSpots[spot].x * W, y: boxSpots[spot].y * H)
            node.zPosition = 20
            let content = SKNode()
            node.addChild(content)
            let side = boxSize * H
            let glow = SKShapeNode(rectOf: CGSize(width: side * 1.35, height: side * 1.35), cornerRadius: side * 0.3)
            glow.fillColor = NSColor.systemYellow.withAlphaComponent(0.55)
            glow.strokeColor = .clear
            glow.alpha = 0
            content.addChild(glow)
            let color = palette[(Int(letter.asciiValue ?? 0)) % palette.count]
            let body = SKShapeNode(rectOf: CGSize(width: side, height: side), cornerRadius: side * 0.22)
            body.fillColor = color
            body.strokeColor = .white
            body.lineWidth = 5
            content.addChild(body)
            let label = RoundedLabel(String(letter), size: side * 0.74)
            label.position = CGPoint(x: 0, y: side * 0.05)
            content.addChild(label)
            addChild(node)
            boxes.append(LetterBox(letter: letter, node: node, content: content, glow: glow, spot: spot))

            let bob = SKAction.repeatForever(.sequence([.moveBy(x: 0, y: H * 0.014, duration: 1.1), .moveBy(x: 0, y: -H * 0.014, duration: 1.1)]))
            bob.timingMode = .easeInEaseOut
            content.run(.sequence([.wait(forDuration: .random(in: 0...1)), bob]))
            if animated {
                node.setScale(0.1)
                node.alpha = 0
                node.run(.sequence([.wait(forDuration: 0.15 * Double(k)),
                                    .group([.fadeIn(withDuration: 0.2), .scale(to: 1, duration: 0.3)])]))
            }
        }
    }

    private func clearBoxes(animated: Bool) {
        for b in boxes {
            if animated {
                b.node.run(.sequence([.group([.scale(to: 0.1, duration: 0.25), .fadeOut(withDuration: 0.25)]), .removeFromParent()]))
            } else {
                b.node.removeFromParent()
            }
        }
        boxes = []
    }

    /// The right box(es) glow and grow, after a couple of misses or a long pause.
    private func showHint() {
        guard let needed = neededLetter else { return }
        for b in boxes where b.letter == needed {
            b.glow.removeAllActions()
            b.glow.run(.repeatForever(.sequence([.fadeAlpha(to: 1, duration: 0.35), .fadeAlpha(to: 0.4, duration: 0.35)])))
            b.node.run(.scale(to: 1.2, duration: 0.3))
        }
    }

    private func clearHint() {
        for b in boxes {
            b.glow.removeAllActions()
            b.glow.alpha = 0
            b.node.run(.scale(to: 1, duration: 0.2))
        }
    }

    private var neededLetter: Character? {
        guard let puzzle, step < puzzle.missing.count else { return nil }
        return puzzle.letters[puzzle.missing[step]]
    }

    // MARK: - Words

    private func nextWord() {
        if queue.isEmpty {
            queue = Words.queue(long: level.usesLongWords, using: &rng)
            if queue.first?.text == lastWord, queue.count > 1 { queue.swapAt(0, queue.count - 1) }
        }
        let word = queue.removeFirst()
        let puzzle = Words.makePuzzle(word, level: level, using: &rng)
        self.puzzle = puzzle
        step = 0
        wrongTries = 0
        filled = Array(repeating: false, count: puzzle.letters.count)

        buildTrain(for: puzzle)
        train.position = CGPoint(x: -trainWidth - H * 0.1, y: trainBaseY)
        phase = .arriving
        showPicture(word.picture, animated: true)
        spawnBoxes(puzzle.boxes, animated: true)
        coach(nil)
        playSound("Blow")

        let arrive = SKAction.move(to: CGPoint(x: trainRestX, y: trainBaseY), duration: 2.2)
        arrive.timingMode = .easeOut
        train.run(.sequence([arrive, .run { [weak self] in self?.startBuilding() }]), withKey: "arrive")
    }

    private func startBuilding() {
        guard let puzzle else { return }
        phase = .building
        lastProgress = now
        lastNudge = now
        highlightNextSlot()
        let word = puzzle.word.text
        let name = Words.spoken(puzzle.letters[puzzle.missing[0]])
        let ask: String
        switch level {
        case .firstLetter: ask = "\(word) starts with \(name). Find the \(name)!"
        case .oneLetter: ask = "A letter fell off. Find the \(name)!"
        case .wholeWord, .bigWords: ask = "Let's spell \(word). First, find the \(name)!"
        }
        var line = "\(word)! "
        if firstWord { line = "Word Train! Touch the letters to fill the train. " + line }
        if let last = lastWord, Words.rhymes(word, last) { line += "That rhymes with \(last)! " }
        line += ask
        firstWord = false
        say(line)
        coach("Find  \(puzzle.letters[puzzle.missing[0]])")
    }

    private func correct(_ box: LetterBox) {
        guard let puzzle else { return }
        let index = puzzle.missing[step]
        boxes.removeAll { $0 === box }
        filled[index] = true
        step += 1
        wrongTries = 0
        lastProgress = now
        clearHint()
        playSound("Tink")

        // Fly into the carriage, then show the letter there.
        let target = slotScenePoint(index)
        box.node.removeAllActions()
        box.node.zPosition = 45
        let fly = SKAction.group([.move(to: target, duration: 0.4), .scale(to: slotSize / boxSize, duration: 0.4)])
        fly.timingMode = .easeIn
        box.node.run(.sequence([fly, .run { [weak self] in
            guard let self else { return }
            self.setSlot(index, letter: puzzle.letters[index])
            self.slots[index].run(.sequence([.scale(to: 1.25, duration: 0.1), .scale(to: 1, duration: 0.15)]))
            self.sparkle(at: target, emoji: "⭐️")
            self.highlightNextSlot()
        }, .removeFromParent()]))

        let name = Words.spoken(puzzle.letters[index])
        if let next = neededLetter {
            say(["\(name)! Now find the \(Words.spoken(next)).", "Yes, \(name)! Next, \(Words.spoken(next))."].randomElement()!)
            coach("Find  \(next)")
        } else {
            say("\(name)!")
            coach(nil)
            phase = .reading
            director.run(.sequence([.wait(forDuration: 1.0), .run { [weak self] in self?.readWord() }]))
        }
    }

    private func wrong(_ box: LetterBox) {
        guard now - box.lastWrong > wrongCooldown, let puzzle, let needed = neededLetter else { return }
        box.lastWrong = now
        wrongTries += 1
        playSound("Purr")
        box.content.run(.sequence([.rotate(toAngle: 0.25, duration: 0.07), .rotate(toAngle: -0.25, duration: 0.12),
                                   .rotate(toAngle: 0.15, duration: 0.1), .rotate(toAngle: 0, duration: 0.08)]))
        let got = Words.spoken(box.letter), want = Words.spoken(needed)
        let later = puzzle.missing[step...].contains { puzzle.letters[$0] == box.letter }
        if later {
            say("That's \(got)! It comes later. First, find the \(want).")
        } else {
            say(["That's \(got). We need \(want).", "Oops, that's \(got)! Find the \(want)."].randomElement()!)
        }
        if wrongTries >= 2 { showHint() }
    }

    /// Each carriage lights up in turn as its letter is said, then the whole word is read.
    private func readWord() {
        guard let puzzle else { return }
        clearBoxes(animated: true)
        var actions: [SKAction] = []
        for (i, letter) in puzzle.letters.enumerated() {
            actions.append(.run { [weak self] in
                guard let self else { return }
                self.say(Words.spoken(letter))
                let slot = self.slots[i]
                slot.glowWidth = 8
                slot.strokeColor = .systemYellow
                slot.run(.sequence([.scale(to: 1.3, duration: 0.15), .scale(to: 1.1, duration: 0.2)]))
            })
            actions.append(.wait(forDuration: 0.85))
        }
        actions.append(.run { [weak self] in
            guard let self else { return }
            self.say("\(puzzle.word.text)!")
            for slot in self.slots {
                slot.run(.sequence([.scale(to: 1.35, duration: 0.15), .scale(to: 1, duration: 0.25)]))
            }
            self.pictureCard.run(.sequence([.scale(to: 1.2, duration: 0.15), .scale(to: 1, duration: 0.25)]))
            self.sparkle(at: self.pictureCard.position, emoji: "🎉")
            self.playSound("Glass")
        })
        actions.append(.wait(forDuration: 1.3))
        actions.append(.run { [weak self] in self?.readyToGo() })
        director.run(.sequence(actions))
    }

    /// The picture hops aboard; marching (or jumping) drives the train away.
    private func readyToGo() {
        guard let puzzle else { return }
        phase = .waitingToGo
        waitingSince = now
        autoDriving = false
        for i in slots.indices { setSlot(i, letter: puzzle.letters[i]) }

        let ride = makeLabel(puzzle.word.picture, size: 0.09)
        let seat = CGPoint(x: (carWidth * H) / 2, y: (wheelRadius * 0.55 + carHeight) * H + H * 0.04)
        let start = train.convert(pictureCard.position, from: self)
        ride.position = start
        ride.zPosition = 2
        train.addChild(ride)
        rider = ride
        let hop = SKAction.move(to: seat, duration: 0.6)
        hop.timingMode = .easeInEaseOut
        ride.run(.group([hop, .sequence([.moveBy(x: 0, y: H * 0.12, duration: 0.3), .moveBy(x: 0, y: -H * 0.12, duration: 0.3)])]))
        pictureCard.run(.group([.fadeOut(withDuration: 0.3), .scale(to: 0.5, duration: 0.3)]))

        if !saidMarchTip || wordsDone < 2 {
            saidMarchTip = true
            say("All aboard! March, march, march to drive the train!")
        } else {
            say(["All aboard! March to go!", "Toot toot! March!", "Choo choo! March to drive!"].randomElement()!)
        }
        coach("🚶 March to drive!")
    }

    private func depart(auto: Bool) {
        phase = .departing
        autoDriving = auto
        coach(auto ? nil : "🚂 Choo choo!")
        playSound("Blow")
    }

    private func finishWord() {
        guard let puzzle else { return }
        director.removeAllActions()
        train.removeAllActions()
        wordsDone += 1
        wordsAtLevel += 1
        lastWord = puzzle.word.text
        wordsPill.text = "🚃 \(wordsDone)"
        wordsPill.pulse()
        confetti(count: 30)

        if wordsAtLevel >= Words.wordsPerLevel, let next = level.next {
            levelUp(to: next)
        } else {
            nextWord()
        }
    }

    private func levelUp(to next: Words.Level) {
        phase = .levelUp
        level = next
        wordsAtLevel = 0
        queue = []
        levelPill.text = "Level \(next.rawValue)"
        placeLevelPill()
        levelPill.pulse()
        playSound("Hero")
        confetti(count: 70)
        let message: String
        switch next {
        case .firstLetter, .oneLetter: message = "Level two! Now a letter falls off anywhere. Can you find it?"
        case .wholeWord: message = "Level three! Now you build the whole word!"
        case .bigWords: message = "Wow! Level four! Big words with four letters!"
        }
        say(message)
        let banner = makeBanner("⭐️ Level \(next.rawValue)!", color: .systemPurple)
        banner.position = CGPoint(x: W / 2, y: H * 0.55)
        addChild(banner)
        banner.setScale(0.3)
        banner.run(.sequence([.scale(to: 1, duration: 0.3), .wait(forDuration: 3), .fadeOut(withDuration: 0.4), .removeFromParent()]))
        pictureCard.removeAllChildren()
        director.run(.sequence([.wait(forDuration: 4), .run { [weak self] in self?.nextWord() }]))
    }

    // MARK: - Loop

    override func tick(dt: TimeInterval, pose: PoseFrame) {
        now += dt
        updateHandMarkers(handPoints(pose))
        let jumped = moves.update(pose, now: now)
        let pace = moves.pace

        switch phase {
        case .building:
            updateTouches(dt: dt)
            nudge()
        case .waitingToGo:
            if pace > 0 || jumped {
                depart(auto: false)
            } else if now - waitingSince > autoDepart {
                depart(auto: true)
            }
        case .departing:
            if jumped { toot() }
            if pace > 0 && autoDriving { autoDriving = false; coach("🚂 Choo choo!") }
            drive(dt: dt, pace: pace)
        case .arriving, .reading, .levelUp:
            break
        }
    }

    private func updateTouches(dt: TimeInterval) {
        let touch = visibleHands
        let reach = handRadius + boxSize * H * 0.5
        for b in boxes {
            let over = touch.contains { hypot($0.x - b.node.position.x, $0.y - b.node.position.y) < reach }
            guard over else { b.dwell = 0; b.latched = false; continue }
            guard !b.latched else { continue }
            b.dwell += dt
            guard b.dwell >= touchDwell else { continue }
            b.latched = true
            if b.letter == neededLetter { correct(b); return } else { wrong(b) }
        }
    }

    private func nudge() {
        guard now - lastProgress > nudgeEvery, now - lastNudge > nudgeEvery, let needed = neededLetter else { return }
        lastNudge = now
        let name = Words.spoken(needed)
        say(["Find the \(name)! It's glowing.", "Where's the \(name)? Touch it!"].randomElement()!)
        showHint()
    }

    private func toot() {
        tootBoost = 1.0
        playSound("Blow")
        sparkle(at: convert(chimneyTop, from: train), emoji: "💨")
        if Int.random(in: 0..<3) == 0 { say("Toot toot!") }
    }

    private func drive(dt: TimeInterval, pace: CGFloat) {
        tootBoost = max(0, tootBoost - dt)
        let base: CGFloat = autoDriving ? 0.22 : 0.3
        let speed = H * (base + 1.5 * pace + (tootBoost > 0 ? 0.6 : 0))
        let dx = speed * CGFloat(dt)
        train.position.x += dx
        for w in wheels { w.node.zRotation -= dx / max(w.radius, 1) }
        // A gentle bounce on the rails, and puffs of smoke.
        train.position.y = trainBaseY + abs(sin(train.position.x / (H * 0.05))) * H * 0.004
        smokeTimer -= dt * Double(1 + pace * 2)
        if smokeTimer <= 0 {
            smokeTimer = 0.28
            puff()
        }
        if train.position.x > W + H * 0.05 { finishWord() }
    }

    private func puff() {
        let p = SKShapeNode(circleOfRadius: H * 0.025)
        p.fillColor = NSColor.white.withAlphaComponent(0.9)
        p.strokeColor = .clear
        p.position = convert(chimneyTop, from: train)
        p.zPosition = 11
        addChild(p)
        p.run(.sequence([.group([.moveBy(x: -H * 0.08, y: H * 0.14, duration: 1.2), .scale(to: 2.4, duration: 1.2),
                                 .fadeOut(withDuration: 1.2)]), .removeFromParent()]))
    }

    // MARK: - Hands

    /// Every tracked hand in scene coordinates, mapped by arm's reach so every box is in range.
    private func handPoints(_ pose: PoseFrame) -> [CGPoint] {
        pose.bodies.flatMap { ReachMapper.hands(of: $0, imageSize: pose.imageSize) }
            .map { CGPoint(x: $0.x * W, y: $0.y * H) }
    }

    private func updateHandMarkers(_ hands: [CGPoint]) {
        while handMarkers.count < hands.count {
            let m = SKShapeNode(circleOfRadius: handRadius)
            m.fillColor = NSColor.white.withAlphaComponent(0.25)
            m.strokeColor = .white
            m.lineWidth = 5
            m.zPosition = 30
            m.isHidden = true
            let glove = RoundedLabel("🖐️", size: handRadius * 1.1)
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

    // MARK: - Effects

    private func sparkle(at point: CGPoint, emoji: String) {
        let s = makeLabel(emoji, size: 0.05)
        s.position = point
        s.zPosition = 46
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
