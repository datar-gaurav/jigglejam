import XCTest

/// Game pack format, import/export, and the JavaScript host that runs pack code.
final class GamePackTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("jigglejam-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    /// The repo's Packs/ folder (sample packs).
    private var repoPacks: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Packs")
    }

    /// Writes a pack folder with the given manifest fields and files.
    @discardableResult
    private func makePack(_ name: String = "pack", manifest: [String: Any] = [:],
                          files: [String: String] = ["game.js": "function onTick() {}"]) throws -> URL {
        let dir = temp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var m: [String: Any] = ["format": 1, "id": "com.test.game", "title": "Test Game", "emoji": "🎈", "main": "game.js"]
        m.merge(manifest) { _, new in new }
        try JSONSerialization.data(withJSONObject: m).write(to: dir.appendingPathComponent("manifest.json"))
        for (path, contents) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }

    // MARK: - Manifest validation

    func testLoadsAValidPack() throws {
        let pack = try GamePack.load(from: makePack(manifest: ["setup": ["checks": ["seen", "hands"]], "color": "#FF0000"]))
        XCTAssertEqual(pack.manifest.title, "Test Game")
        XCTAssertEqual(pack.manifest.setup?.checks, ["seen", "hands"])
    }

    func testRejectsBadPacks() throws {
        let cases: [(String, [String: Any], [String: String], GamePackError)] = [
            ("badid", ["id": "../evil"], ["game.js": ""], .invalidID("../evil")),
            ("nomain", [:], [:], .missingMain("game.js")),
            ("escape", ["main": "../outside.js"], ["game.js": ""], .unsafePath("../outside.js")),
            ("absolute", ["main": "/etc/hosts"], ["game.js": ""], .unsafePath("/etc/hosts")),
            ("future", ["format": 99], ["game.js": ""], .unsupportedFormat(99)),
            ("check", ["setup": ["checks": ["levitate"]]], ["game.js": ""], .badManifest("unknown setup check \"levitate\"")),
        ]
        for (name, manifest, files, expected) in cases {
            XCTAssertThrowsError(try GamePack.load(from: makePack(name, manifest: manifest, files: files)), name) { error in
                XCTAssertEqual(error as? GamePackError, expected, name)
            }
        }
        let empty = temp.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try GamePack.load(from: empty)) { XCTAssertEqual($0 as? GamePackError, .notAPack) }
    }

    func testResourcesCannotEscapeThePack() throws {
        let pack = try GamePack.load(from: makePack(files: ["game.js": "", "art/star.png": "x"]))
        XCTAssertNotNil(pack.resource("art/star.png"))
        XCTAssertNil(pack.resource("../pack/../../secret"))
        XCTAssertNil(pack.resource("/etc/passwd"))
        XCTAssertNil(pack.resource(""))
    }

    func testSamplePacksAreValid() throws {
        let folders = try FileManager.default.contentsOfDirectory(at: repoPacks, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        XCTAssertFalse(folders.isEmpty)
        for folder in folders { XCTAssertNoThrow(try GamePack.load(from: folder), folder.lastPathComponent) }
    }

    // MARK: - Import / export

    func testExportThenImportRoundTrip() throws {
        let source = try GamePack.load(from: makePack(files: ["game.js": "// hi", "sounds/boop.txt": "boop"]))
        let store = GamePackStore(root: temp.appendingPathComponent("library"))
        let archive = temp.appendingPathComponent("Test Game.jigglegame")
        try store.export(source, to: archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        let installed = try store.install(from: archive)
        XCTAssertEqual(installed.manifest, source.manifest)
        XCTAssertEqual(try String(contentsOf: installed.mainScriptURL, encoding: .utf8), "// hi")
        XCTAssertNotNil(installed.resource("sounds/boop.txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) })
        XCTAssertEqual(store.installed().map(\.manifest.id), ["com.test.game"])
    }

    func testImportAcceptsAZipWithATopLevelFolder() throws {
        let folder = try makePack("Wrapped Game")
        let archive = temp.appendingPathComponent("wrapped.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", folder.path, archive.path]
        try ditto.run(); ditto.waitUntilExit()

        let store = GamePackStore(root: temp.appendingPathComponent("library"))
        XCTAssertEqual(try store.install(from: archive).manifest.id, "com.test.game")
    }

    func testReimportingReplacesTheSameGame() throws {
        let store = GamePackStore(root: temp.appendingPathComponent("library"))
        try store.install(from: makePack("v1", manifest: ["version": "1"]))
        try store.install(from: makePack("v2", manifest: ["version": "2"]))
        XCTAssertEqual(store.installed().map(\.manifest.version), ["2"])
    }

    func testRemovingAGame() throws {
        let store = GamePackStore(root: temp.appendingPathComponent("library"))
        let pack = try store.install(from: makePack())
        try store.remove(pack)
        XCTAssertTrue(store.installed().isEmpty)
    }

    func testBrokenArchiveIsRejected() throws {
        let junk = temp.appendingPathComponent("junk.jigglegame")
        try "not a zip".write(to: junk, atomically: true, encoding: .utf8)
        let store = GamePackStore(root: temp.appendingPathComponent("library"))
        XCTAssertThrowsError(try store.install(from: junk))
        XCTAssertTrue(store.installed().isEmpty)
    }
}

// MARK: - Script host

/// Records what a script asks the renderer to do.
final class FakeRenderer: ScriptRenderer {
    var screenSize = CGSize(width: 1280, height: 720)
    var nodes: [Int: (kind: String, props: [String: Any])] = [:]
    var removed: [Int] = []
    var said: [String] = []
    var sounds: [String] = []
    var effects: [(Int, String)] = []
    var confettiCount = 0
    var logs: [String] = []
    private var next = 1

    func createNode(kind: String, props: [String: Any]) -> Int {
        defer { next += 1 }
        nodes[next] = (kind, props)
        return next
    }
    func updateNode(_ id: Int, props: [String: Any]) { nodes[id]?.props.merge(props) { _, new in new } }
    func nodeEffect(_ id: Int, effect: String, props: [String: Any]) { effects.append((id, effect)) }
    func removeNode(_ id: Int) { removed.append(id); nodes[id] = nil }
    func say(_ text: String) { said.append(text) }
    func playSound(_ name: String) { sounds.append(name) }
    func confetti() { confettiCount += 1 }
    func log(_ message: String) { logs.append(message) }

    func number(_ id: Int, _ key: String) -> Double? { (nodes[id]?.props[key] as? NSNumber)?.doubleValue }
}

extension GamePackTests {
    private func input(players: Int = 1, hands: [[String: Double]] = [], jumped: Bool = false) -> [String: Any] {
        ["players": players, "hands": hands, "feet": [], "bodies": [], "jumped": jumped, "walking": 0.0,
         "tooClose": false, "wheel": NSNull()]
    }

    func testScriptsDrawSpeakAndReadInput() {
        let renderer = FakeRenderer()
        let host = ScriptHost(renderer: renderer)
        XCTAssertTrue(host.load(script: """
            let ball;
            function onStart() { ball = game.circle({ x: game.width / 2, y: 100, size: 50, color: "#FF0000" }); }
            function onTick(dt, input) {
              ball.x += 10;
              if (input.jumped) { game.say("Boing!"); ball.pulse(); }
              if (input.hands.length && ball.touches(input.hands[0], 0)) { ball.remove(); game.confetti(); }
            }
            """, name: "test.js"))
        host.call("onStart")
        XCTAssertEqual(renderer.nodes[1]?.kind, "circle")
        XCTAssertEqual(renderer.number(1, "x"), 640)

        host.call("onTick", [1.0 / 60, input(jumped: true)])
        XCTAssertEqual(renderer.number(1, "x"), 650)
        XCTAssertEqual(renderer.said, ["Boing!"])
        XCTAssertEqual(renderer.effects.first?.1, "pulse")

        host.call("onTick", [1.0 / 60, input(hands: [["x": 660, "y": 100]])])
        XCTAssertEqual(renderer.removed, [1])
        XCTAssertEqual(renderer.confettiCount, 1)
        XCTAssertFalse(host.failed)
    }

    func testScriptErrorsStopTheScriptInsteadOfCrashing() {
        let renderer = FakeRenderer()
        let host = ScriptHost(renderer: renderer)
        host.load(script: "let n = 0; function onTick() { n += 1; if (n === 2) { undefinedThing(); } game.say(String(n)); }", name: "t.js")
        for _ in 0..<5 { host.call("onTick", [0.016, input()]) }
        XCTAssertTrue(host.failed)
        XCTAssertTrue(host.lastError?.contains("undefinedThing") == true, host.lastError ?? "")
        XCTAssertEqual(renderer.said, ["1"], "nothing runs after the error")

        let broken = ScriptHost(renderer: FakeRenderer())
        XCTAssertFalse(broken.load(script: "function onTick( {", name: "broken.js"))
    }

    func testScriptsAreSandboxed() {
        let host = ScriptHost(renderer: FakeRenderer())
        for name in ["require", "fetch", "XMLHttpRequest", "process", "__native", "setTimeout"] {
            XCTAssertEqual(host.evaluate("typeof \(name)")?.toString(), "undefined", name)
        }
        XCTAssertEqual(host.evaluate("Object.isFrozen(game)")?.toBool(), true)
    }

    /// Runs the bundled Star Catch sample end to end against the fake renderer.
    func testStarCatchSamplePlays() throws {
        let pack = try GamePack.load(from: repoPacks.appendingPathComponent("StarCatch"))
        let renderer = FakeRenderer()
        let host = ScriptHost(renderer: renderer)
        XCTAssertTrue(host.load(script: try String(contentsOf: pack.mainScriptURL, encoding: .utf8), name: "game.js"))
        host.call("onStart")
        XCTAssertFalse(renderer.said.isEmpty, "introduces itself")

        // Nobody playing: no stars.
        for _ in 0..<120 { host.call("onTick", [1.0 / 60, input(players: 0)]) }
        XCTAssertTrue(renderer.nodes.values.filter { $0.kind == "emoji" }.isEmpty)

        // Someone playing: stars fall.
        for _ in 0..<180 { host.call("onTick", [1.0 / 60, input()]) }
        let stars = renderer.nodes.filter { $0.value.kind == "emoji" }
        XCTAssertFalse(stars.isEmpty)

        // Put a hand on a star: it's caught and the score goes up.
        let (id, _) = stars.first!
        let hand = ["x": renderer.number(id, "x")!, "y": renderer.number(id, "y")!]
        host.call("onTick", [1.0 / 60, input(hands: [hand])])
        XCTAssertTrue(renderer.removed.contains(id))
        XCTAssertEqual(renderer.nodes.values.first { $0.kind == "text" }?.props["text"] as? String, "🌟 1")
        XCTAssertEqual(renderer.sounds.last, "Pop")

        // A jump makes a star shower.
        let before = renderer.nodes.values.filter { $0.kind == "emoji" }.count
        host.call("onTick", [1.0 / 60, input(jumped: true)])
        XCTAssertGreaterThanOrEqual(renderer.nodes.values.filter { $0.kind == "emoji" }.count, before + 6)
        XCTAssertFalse(host.failed, host.lastError ?? "")
    }
}
