import SwiftUI
import Combine

/// Everything the platform needs to show, set up and launch a game, whether it's a built-in
/// Swift game or an imported game pack.
struct GameEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let emoji: String
    let color: Color
    /// Show the live camera behind the game, or let the game draw its own world.
    let showsCamera: Bool
    /// Needs feet in view: gets the too-close check in setup.
    let needsFullBody: Bool
    let setupInstruction: String
    let setupRequirements: [SetupRequirement]
    /// The pack this game came from; nil for built-in games.
    let pack: GamePack?
    let makeScene: () -> GameScene

    var isBuiltIn: Bool { pack == nil }

    static func == (a: GameEntry, b: GameEntry) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Builds the scene at a default size; it resizes to the window.
    func scene() -> GameScene {
        let scene = makeScene()
        scene.scaleMode = .resizeFill
        return scene
    }
}

extension GameEntry {
    /// An entry for an imported pack; its code runs in a `ScriptedGameScene`.
    init(pack: GamePack) {
        let m = pack.manifest
        self.init(
            id: "pack:" + m.id,
            title: m.title,
            emoji: m.emoji,
            color: Color(hex: m.color) ?? .teal,
            showsCamera: m.showsCamera ?? true,
            needsFullBody: m.needsFullBody ?? false,
            setupInstruction: m.setup?.instruction ?? "Stand where the camera can see you!",
            setupRequirements: (m.setup?.checks ?? ["seen"]).compactMap(SetupRequirement.init(rawValue:)),
            pack: pack,
            makeScene: { ScriptedGameScene(pack: pack, size: CGSize(width: 1280, height: 720)) }
        )
    }
}

/// Built-in games plus installed packs, with import / export / remove.
final class GameLibrary: ObservableObject {
    @Published private(set) var games: [GameEntry] = []
    /// True while a game is being unpacked and checked (done off the main thread).
    @Published private(set) var isBusy = false

    private let store: GamePackStore
    private let builtIns: [GameEntry]

    init(builtIns: [GameEntry], store: GamePackStore = GamePackStore()) {
        assert(Set(SetupRequirement.allCases.map(\.rawValue)) == GamePack.knownSetupChecks,
               "SetupRequirement and GamePack.knownSetupChecks must list the same checks")
        self.builtIns = builtIns
        self.store = store
        installBundledSamplesOnce()
        reload()
    }

    func reload() {
        games = builtIns + store.installed().map(GameEntry.init(pack:))
    }

    /// Installs a `.jigglegame` file and returns its entry. Unpacking and checking run in the
    /// background so a big or slow file never freezes the menu.
    @MainActor @discardableResult
    func importGame(from url: URL) async throws -> GameEntry {
        isBusy = true
        defer { isBusy = false }
        let store = self.store
        let pack = try await Task.detached(priority: .userInitiated) { try store.install(from: url) }.value
        reload()
        return GameEntry(pack: pack)
    }

    @MainActor
    func export(_ entry: GameEntry, to url: URL) async throws {
        guard let pack = entry.pack else { throw GamePackError.builtInCannotBeExported }
        isBusy = true
        defer { isBusy = false }
        let store = self.store
        try await Task.detached(priority: .userInitiated) { try store.export(pack, to: url) }.value
    }

    func remove(_ entry: GameEntry) throws {
        guard let pack = entry.pack else { return }
        try store.remove(pack)
        reload()
    }

    /// Sample packs shipped inside the app (the Packs folder) are installed on first launch,
    /// and again when a newer app ships an updated version. Removed samples stay removed.
    private func installBundledSamplesOnce() {
        guard let bundled = Bundle.main.url(forResource: "Packs", withExtension: nil),
              let folders = try? FileManager.default.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil)
        else { return }
        let defaults = UserDefaults.standard
        for folder in folders {
            guard let pack = try? GamePack.load(from: folder) else { continue }
            let key = "installedSample.\(pack.manifest.id)"
            let version = pack.manifest.version ?? "1"
            guard defaults.string(forKey: key) != version else { continue }
            if (try? store.install(from: folder)) != nil { defaults.set(version, forKey: key) }
        }
    }
}

extension Color {
    /// "#RRGGBB", "#RGB" or "#RRGGBBAA".
    init?(hex: String?) {
        guard let rgba = parseHexColor(hex) else { return nil }
        self.init(.sRGB, red: rgba.0, green: rgba.1, blue: rgba.2, opacity: rgba.3)
    }
}

func parseHexColor(_ hex: String?) -> (Double, Double, Double, Double)? {
    guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
    s.removeFirst()
    if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
    if s.count == 6 { s += "FF" }
    guard s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
    return (Double((value >> 24) & 0xFF) / 255, Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
}
