import SpriteKit
import AppKit
import Vision

/// Runs an imported game pack: the platform supplies tracking, setup, pausing and effects, and
/// the pack's JavaScript supplies the game. The script runs on its own thread (`ScriptRunner`);
/// each frame the scene sends input, waits a few milliseconds at most, and applies whatever the
/// script drew. Coordinates given to scripts are scene points with the origin at the bottom-left.
final class ScriptedGameScene: GameScene {
    let pack: GamePack
    private var runner: ScriptRunner?
    private var pendingDT: Double = 0
    /// How long a frame waits for the script before drawing anyway (it catches up next frame).
    private let frameWait: Double = 0.006
    private let moves = Locomotion()
    private var nodes: [Int: SKNode] = [:]
    private var nodeProps: [Int: [String: Any]] = [:]
    private var nodeKinds: [Int: String] = [:]
    private var textures: [String: SKTexture] = [:]
    private var sounds: [NSSound] = []
    private var lastLog = ""
    private var showingError = false

    init(pack: GamePack, size: CGSize) {
        self.pack = pack
        super.init(size: size)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var needsFullBody: Bool { pack.manifest.needsFullBody ?? false }
    override var wantsHandTracking: Bool { pack.manifest.handTracking ?? false }
    override func hasPlayer(_ pose: PoseFrame) -> Bool { !pose.bodies.isEmpty || !pose.hands.isEmpty }
    override var debugText: String { runner?.failure.map { "⚠️ \($0)" } ?? lastLog }

    // MARK: - Lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = (pack.manifest.showsCamera ?? true)
            ? .clear
            : (NSColor(hexString: pack.manifest.background) ?? NSColor(calibratedRed: 0.1, green: 0.12, blue: 0.3, alpha: 1))
        guard runner == nil else { return }
        guard let source = try? String(contentsOf: pack.mainScriptURL, encoding: .utf8) else {
            showError("Couldn't read \(pack.manifest.main).")
            return
        }
        let runner = ScriptRunner(screenSize: size)
        self.runner = runner
        runner.start(script: source, name: pack.manifest.main)
        runner.waitUntilIdle(timeout: frameWait)
        applyScriptOutput()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        runner?.recorder.setScreenSize(size)
    }

    override func tick(dt: TimeInterval, pose: PoseFrame) {
        guard let runner, !showingError else { return }
        let jumped = moves.update(pose, now: CACurrentMediaTime())
        pendingDT += dt
        if runner.tick(dt: pendingDT, input: input(from: pose, jumped: jumped)) {
            pendingDT = 0
        }
        runner.waitUntilIdle(timeout: frameWait)
        applyScriptOutput()
    }

    override func trackingDidResume() { moves.reset() }

    override func pauseChanged(paused: Bool) {
        runner?.call(paused ? "onPause" : "onResume")
    }

    override func tearDown() {
        runner?.stop()
        runner = nil
        super.tearDown()
    }

    /// Applies what the script drew since last frame, and shows its error if it failed or hung.
    private func applyScriptOutput() {
        guard let runner else { return }
        for command in runner.recorder.drain() {
            switch command {
            case let .create(id, kind, props): createNode(id: id, kind: kind, props: props)
            case let .update(id, props): updateNode(id, props: props)
            case let .effect(id, name, props): nodeEffect(id, effect: name, props: props)
            case let .remove(id): removeNode(id)
            case let .say(text): say(text)
            case let .sound(name): playSound(name)
            case .confetti: confetti(count: 50)
            case let .log(message): log(message)
            }
        }
        if let failure = runner.failure {
            runner.stop()
            showError(failure)
        }
    }

    // MARK: - Input for scripts

    private static let jointNames: [Joint: String] = [
        .nose: "nose", .neck: "neck", .root: "root",
        .leftEye: "leftEye", .rightEye: "rightEye", .leftEar: "leftEar", .rightEar: "rightEar",
        .leftShoulder: "leftShoulder", .rightShoulder: "rightShoulder",
        .leftElbow: "leftElbow", .rightElbow: "rightElbow", .leftWrist: "leftWrist", .rightWrist: "rightWrist",
        .leftHip: "leftHip", .rightHip: "rightHip", .leftKnee: "leftKnee", .rightKnee: "rightKnee",
        .leftAnkle: "leftAnkle", .rightAnkle: "rightAnkle",
    ]

    private func input(from pose: PoseFrame, jumped: Bool) -> [String: Any] {
        func point(_ p: CGPoint) -> [String: Double] {
            let s = scenePoint(p, imageSize: pose.imageSize)
            return ["x": Double(s.x), "y": Double(s.y)]
        }
        let hands = pose.poppers.filter { $0.kind == .hand }.map { point($0.point) }
        let feet = pose.poppers.filter { $0.kind == .foot }.map { point($0.point) }
        let bodies: [[String: Any]] = pose.bodies.map { body in
            var joints: [String: Any] = [:]
            for (joint, p) in body { if let name = Self.jointNames[joint] { joints[name] = point(p) } }
            return joints
        }
        var result: [String: Any] = [
            "players": pose.bodies.count,
            "hands": hands,
            "feet": feet,
            "bodies": bodies,
            "jumped": jumped,
            "walking": Double(moves.pace),
            "tooClose": pose.tooClose,
            "wheel": NSNull(),
        ]
        if pose.hands.count >= 2 {
            let a = scenePoint(pose.hands[0], imageSize: pose.imageSize)
            let b = scenePoint(pose.hands[1], imageSize: pose.imageSize)
            let (l, r) = a.x < b.x ? (a, b) : (b, a)
            // Positive = turned right (right hand lower), in degrees.
            let degrees = -atan2(r.y - l.y, r.x - l.x) * 180 / .pi
            result["wheel"] = ["angle": Double(degrees),
                               "left": ["x": Double(l.x), "y": Double(l.y)],
                               "right": ["x": Double(r.x), "y": Double(r.y)]]
        }
        return result
    }

    // MARK: - Drawing what the script asked for

    private func createNode(id: Int, kind: String, props: [String: Any]) {
        let node: SKNode
        switch kind {
        case "emoji", "text":
            let label = kind == "text" ? RoundedLabel() : SKLabelNode(fontNamed: "AppleColorEmoji")
            label.verticalAlignmentMode = .center
            label.horizontalAlignmentMode = .center
            node = label
        case "circle", "rect":
            node = SKShapeNode()
        case "image":
            node = SKSpriteNode()
        default:
            log("Unknown sprite kind \"\(kind)\"")
            return
        }
        nodes[id] = node
        nodeKinds[id] = kind
        nodeProps[id] = [:]
        node.zPosition = 5
        addChild(node)
        updateNode(id, props: props)
    }

    private func updateNode(_ id: Int, props: [String: Any]) {
        guard let node = nodes[id], let kind = nodeKinds[id] else { return }
        var all = nodeProps[id] ?? [:]
        all.merge(props) { _, new in new }
        nodeProps[id] = all

        func num(_ key: String) -> CGFloat? { (all[key] as? NSNumber).map { CGFloat(truncating: $0) } }
        let changed = Set(props.keys)

        if changed.contains("x") || changed.contains("y") {
            node.removeAction(forKey: "moveTo") // setting a position ends any running moveTo
            node.position = CGPoint(x: num("x") ?? 0, y: num("y") ?? 0)
        }
        if changed.contains("rotation") { node.zRotation = (num("rotation") ?? 0) * .pi / 180 }
        if changed.contains("alpha") { node.alpha = num("alpha") ?? 1 }
        if changed.contains("scale") { node.setScale(num("scale") ?? 1) }
        if changed.contains("visible") { node.isHidden = !((all["visible"] as? Bool) ?? true) }
        if changed.contains("z") { node.zPosition = num("z") ?? 5 }

        let size = num("size") ?? 60
        let color = NSColor(hexString: all["color"] as? String) ?? .white
        switch (kind, node) {
        case (_, let label as SKLabelNode):
            if changed.contains("text") { label.text = all["text"] as? String }
            if changed.contains("size") || changed.contains("text") { label.fontSize = size }
            if changed.contains("color") { label.fontColor = color }
        case ("circle", let shape as SKShapeNode):
            if changed.contains("size") || shape.path == nil {
                shape.path = CGPath(ellipseIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size), transform: nil)
            }
            shape.fillColor = color
            shape.strokeColor = .clear
        case ("rect", let shape as SKShapeNode):
            if changed.contains("width") || changed.contains("height") || changed.contains("radius") || shape.path == nil {
                let w = num("width") ?? 100, h = num("height") ?? 100
                let r = min(num("radius") ?? 0, min(w, h) / 2)
                shape.path = CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
                                    cornerWidth: r, cornerHeight: r, transform: nil)
            }
            shape.fillColor = color
            shape.strokeColor = .clear
        case ("image", let sprite as SKSpriteNode):
            if changed.contains("path"), let path = all["path"] as? String { sprite.texture = texture(path) }
            let w = num("width") ?? size, h = num("height") ?? size
            sprite.size = CGSize(width: w, height: h)
        default:
            break
        }
    }

    private func nodeEffect(_ id: Int, effect: String, props: [String: Any]) {
        guard let node = nodes[id] else { return }
        switch effect {
        case "moveTo":
            let x = (props["x"] as? NSNumber).map { CGFloat(truncating: $0) } ?? node.position.x
            let y = (props["y"] as? NSNumber).map { CGFloat(truncating: $0) } ?? node.position.y
            let seconds = (props["seconds"] as? NSNumber)?.doubleValue ?? 0.3
            node.removeAction(forKey: "moveTo")
            let move = SKAction.move(to: CGPoint(x: x, y: y), duration: max(seconds, 0))
            move.timingMode = .linear // must match the script's interpolation in Sprite._pos()
            node.run(move, withKey: "moveTo")
        case "pulse":
            let base = node.xScale
            node.run(.sequence([.scale(to: base * 1.25, duration: 0.08), .scale(to: base, duration: 0.15)]))
        case "burst":
            burst(at: node.position, color: NSColor(hexString: nodeProps[id]?["color"] as? String) ?? .systemYellow)
        default:
            log("Unknown effect \"\(effect)\"")
        }
    }

    private func removeNode(_ id: Int) {
        nodes.removeValue(forKey: id)?.removeFromParent()
        nodeProps.removeValue(forKey: id)
        nodeKinds.removeValue(forKey: id)
    }

    private func playSound(_ name: String) {
        guard !Snapshot.isActive else { return }
        let sound: NSSound?
        if let url = pack.resource(name), FileManager.default.fileExists(atPath: url.path) {
            sound = NSSound(contentsOf: url, byReference: false)
        } else {
            sound = NSSound(named: name)?.copy() as? NSSound
        }
        guard let sound else { log("Sound \"\(name)\" not found"); return }
        sounds.append(sound)
        if sounds.count > 6 { sounds.removeFirst() }
        sound.play()
    }

    private func log(_ message: String) {
        lastLog = message
        print("[\(pack.manifest.id)] \(message)")
    }

    // MARK: - Helpers

    private func texture(_ path: String) -> SKTexture? {
        if let cached = textures[path] { return cached }
        guard let url = pack.resource(path), let image = NSImage(contentsOf: url) else {
            log("Image \"\(path)\" not found")
            return nil
        }
        let texture = SKTexture(image: image)
        textures[path] = texture
        return texture
    }

    private func burst(at point: CGPoint, color: NSColor) {
        for i in 0..<10 {
            let drop = SKShapeNode(circleOfRadius: size.height * 0.012)
            drop.fillColor = color
            drop.strokeColor = .clear
            drop.position = point
            drop.zPosition = 50
            addChild(drop)
            let angle = CGFloat(i) / 10 * 2 * .pi
            let dist = size.height * 0.1
            drop.run(.sequence([
                .group([.moveBy(x: cos(angle) * dist, y: sin(angle) * dist, duration: 0.4), .fadeOut(withDuration: 0.4)]),
                .removeFromParent()
            ]))
        }
    }

    private func showError(_ message: String) {
        guard !showingError else { return }
        showingError = true
        let title = makeLabel("😕 This game hit a problem", size: 0.07)
        title.position = CGPoint(x: size.width / 2, y: size.height * 0.56)
        title.zPosition = 200
        addChild(title)
        let detail = makeLabel(message, size: 0.03)
        detail.position = CGPoint(x: size.width / 2, y: size.height * 0.46)
        detail.zPosition = 200
        addChild(detail)
    }
}

extension NSColor {
    convenience init?(hexString: String?) {
        guard let rgba = parseHexColor(hexString) else { return nil }
        self.init(srgbRed: rgba.0, green: rgba.1, blue: rgba.2, alpha: rgba.3)
    }
}
