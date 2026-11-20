import Foundation
import JavaScriptCore

/// `manifest.json` at the root of a game pack. See docs/GAME_PACKS.md.
struct GameManifest: Codable, Equatable {
    struct Setup: Codable, Equatable {
        var instruction: String?
        /// Names from `GamePack.knownSetupChecks`, e.g. ["seen", "hands"].
        var checks: [String]?
    }

    var format: Int
    var id: String
    var title: String
    var emoji: String
    var main: String
    var color: String?
    var author: String?
    var version: String?
    var description: String?
    /// Show the live camera behind the game (true) or let the game draw its own world (false).
    var showsCamera: Bool?
    /// Background color ("#RRGGBB") when the camera isn't shown.
    var background: String?
    /// Needs feet in view: gets the "too close" warning and full-body setup checks.
    var needsFullBody: Bool?
    /// Turns on the dedicated hand tracker (for steering-style games).
    var handTracking: Bool?
    var setup: Setup?
}

enum GamePackError: LocalizedError, Equatable {
    case notAPack
    case badManifest(String)
    case unsupportedFormat(Int)
    case invalidID(String)
    case missingMain(String)
    case unsafePath(String)
    case tooLarge
    case archiveFailed(String)
    case builtInCannotBeExported
    case scriptError(String)
    case tooManyFiles

    var errorDescription: String? {
        switch self {
        case .notAPack: return "That isn't a Jiggle Jam game: there's no manifest.json inside."
        case .badManifest(let why): return "The game's manifest.json couldn't be read: \(why)"
        case .unsupportedFormat(let v): return "This game needs a newer Jiggle Jam (pack format \(v))."
        case .invalidID(let id): return "The game id \"\(id)\" isn't valid. Use letters, numbers, dots and dashes."
        case .missingMain(let file): return "The game's code file \"\(file)\" is missing."
        case .unsafePath(let p): return "The game refers to a file outside itself (\(p))."
        case .tooLarge: return "That game is too big (the limit is 50 MB)."
        case .archiveFailed(let why): return "The game file couldn't be unpacked or packed: \(why)"
        case .builtInCannotBeExported: return "Built-in games are part of the app and can't be exported."
        case .scriptError(let why): return "The game's code has a mistake, so it wasn't added: \(why)"
        case .tooManyFiles: return "That game has too many files (the limit is \(GamePack.maxFiles))."
        }
    }
}

/// A validated game pack on disk: a folder with manifest.json, the main script and any assets.
struct GamePack: Equatable {
    static let currentFormat = 1
    static let fileExtension = "jigglegame"
    static let maxBytes = 50 * 1024 * 1024
    static let maxFiles = 2_000
    /// Setup checks a manifest may ask for (matches `SetupRequirement` in the app).
    static let knownSetupChecks: Set<String> = ["seen", "hands", "feet", "knees", "wholeBody", "bothHands", "wheelLevel"]

    let manifest: GameManifest
    let directory: URL

    var mainScriptURL: URL { directory.appendingPathComponent(manifest.main) }

    /// Loads and validates the pack in `directory`.
    static func load(from directory: URL) throws -> GamePack {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw GamePackError.notAPack }
        let manifest: GameManifest
        do {
            manifest = try JSONDecoder().decode(GameManifest.self, from: Data(contentsOf: manifestURL))
        } catch let DecodingError.keyNotFound(key, _) {
            throw GamePackError.badManifest("\"\(key.stringValue)\" is missing")
        } catch {
            throw GamePackError.badManifest(error.localizedDescription)
        }

        guard manifest.format <= currentFormat, manifest.format >= 1 else { throw GamePackError.unsupportedFormat(manifest.format) }
        guard manifest.id.range(of: #"^[A-Za-z0-9][A-Za-z0-9.\-]{0,99}$"#, options: .regularExpression) != nil else {
            throw GamePackError.invalidID(manifest.id)
        }
        guard !manifest.title.trimmingCharacters(in: .whitespaces).isEmpty else { throw GamePackError.badManifest("\"title\" is empty") }
        if let unknown = manifest.setup?.checks?.first(where: { !knownSetupChecks.contains($0) }) {
            throw GamePackError.badManifest("unknown setup check \"\(unknown)\"")
        }

        let pack = GamePack(manifest: manifest, directory: directory)
        guard let main = pack.resource(manifest.main) else { throw GamePackError.unsafePath(manifest.main) }
        guard FileManager.default.fileExists(atPath: main.path) else { throw GamePackError.missingMain(manifest.main) }
        guard Self.size(of: directory) <= maxBytes else { throw GamePackError.tooLarge }
        return pack
    }

    /// A file inside the pack, or nil if `path` would escape the pack folder.
    func resource(_ path: String) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let url = directory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        return url.path.hasPrefix(root + "/") ? url : nil
    }

    /// Parses the main script without running it. Returns an error message, or nil if it's valid.
    func scriptSyntaxError() -> String? {
        guard let source = try? String(contentsOf: mainScriptURL, encoding: .utf8) else {
            return "\(manifest.main) isn't readable UTF-8 text"
        }
        return Self.syntaxError(in: source, name: manifest.main)
    }

    static func syntaxError(in source: String, name: String) -> String? {
        let context = JSGlobalContextCreate(nil)
        defer { JSGlobalContextRelease(context) }
        let script = JSStringCreateWithCFString(source as CFString)
        let url = JSStringCreateWithCFString(name as CFString)
        defer { JSStringRelease(script); JSStringRelease(url) }
        var exception: JSValueRef?
        guard !JSCheckScriptSyntax(context, script, url, 1, &exception) else { return nil }
        guard let exception, let jsContext = JSContext(jsGlobalContextRef: context),
              let value = JSValue(jsValueRef: exception, in: jsContext) else { return "syntax error" }
        let line = value.objectForKeyedSubscript("line")?.toInt32() ?? 0
        return "line \(line): \(value.toString() ?? "syntax error")"
    }

    private static func size(of directory: URL) -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let items = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total = 0
        for case let url as URL in items {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
        }
        return total
    }
}

/// `.jigglegame` files are zip archives of a pack folder's contents.
enum GamePackArchive {
    /// Extracts with hard limits: the archive's declared contents are checked first, and the
    /// extraction is stopped as soon as the real extracted size or file count goes over.
    /// `checkDeclaredSize: false` skips the up-front check (tests use it to exercise the monitor,
    /// which is what protects against archives that lie about their size).
    static func unpack(_ archive: URL, into directory: URL,
                       maxBytes: Int = GamePack.maxBytes, maxFiles: Int = GamePack.maxFiles,
                       checkDeclaredSize: Bool = true) throws {
        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard archiveSize <= maxBytes else { throw GamePackError.tooLarge }
        if checkDeclaredSize, let declared = declaredContents(of: archive) {
            guard declared.files <= maxFiles else { throw GamePackError.tooManyFiles }
            guard declared.bytes <= maxBytes else { throw GamePackError.tooLarge }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() } catch { throw GamePackError.archiveFailed(error.localizedDescription) }

        var exceeded: GamePackError?
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.05)
            let usage = DirectoryUsage.measure(directory)
            if usage.bytes > maxBytes { exceeded = .tooLarge } else if usage.files > maxFiles { exceeded = .tooManyFiles }
            if exceeded != nil { process.terminate(); break }
        }
        process.waitUntilExit()
        if let exceeded { throw exceeded }
        let usage = DirectoryUsage.measure(directory)
        if usage.bytes > maxBytes { throw GamePackError.tooLarge }
        if usage.files > maxFiles { throw GamePackError.tooManyFiles }
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GamePackError.archiveFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// File count and total uncompressed size the zip says it contains (from `zipinfo -t`).
    static func declaredContents(of archive: URL) -> (files: Int, bytes: Int)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-t", archive.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // e.g. "2 files, 2262 bytes uncompressed, 1240 bytes compressed:  45.2%"
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard text.contains("uncompressed"), numbers.count >= 2 else { return nil }
        return (numbers[0], numbers[1])
    }

    static func pack(_ directory: URL, to archive: URL) throws {
        try? FileManager.default.removeItem(at: archive)
        try run(["-c", "-k", "--norsrc", directory.path, archive.path])
    }

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() } catch { throw GamePackError.archiveFailed(error.localizedDescription) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GamePackError.archiveFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// Bytes and file count of a folder tree (symlinks are counted, not followed).
enum DirectoryUsage {
    static func measure(_ directory: URL) -> (bytes: Int, files: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let items = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return (0, 0) }
        var bytes = 0, files = 0
        for case let url as URL in items {
            files += 1
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { bytes += values?.fileSize ?? 0 }
        }
        return (bytes, files)
    }
}

/// Installed packs live unpacked in one folder per game id.
final class GamePackStore {
    let root: URL
    let maxBytes: Int
    let maxFiles: Int

    init(root: URL = GamePackStore.defaultRoot, maxBytes: Int = GamePack.maxBytes, maxFiles: Int = GamePack.maxFiles) {
        self.root = root
        self.maxBytes = maxBytes
        self.maxFiles = maxFiles
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("JiggleJam/Games", isDirectory: true)
    }

    /// All valid installed packs, sorted by title. Broken folders are skipped.
    func installed() -> [GamePack] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                    options: .skipsHiddenFiles)) ?? []
        return folders.compactMap { try? GamePack.load(from: $0) }
            .sorted { $0.manifest.title.localizedCaseInsensitiveCompare($1.manifest.title) == .orderedAscending }
    }

    /// Installs a `.jigglegame` file (or an unpacked pack folder). A pack with the same id is
    /// replaced, but only once the new one is fully unpacked and validated (manifest, paths,
    /// limits and script syntax); the swap is atomic, so a failed update keeps the old version.
    /// Slow for big packs: call off the main thread.
    @discardableResult
    func install(from source: URL) throws -> GamePack {
        // Stage inside the library folder (hidden) so the final swap is a same-volume rename.
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        let unpacked = staging.appendingPathComponent("pack")
        if isDirectory.boolValue {
            // Measure before copying anything.
            let usage = DirectoryUsage.measure(source)
            guard usage.bytes <= maxBytes else { throw GamePackError.tooLarge }
            guard usage.files <= maxFiles else { throw GamePackError.tooManyFiles }
            try FileManager.default.copyItem(at: source, to: unpacked)
        } else {
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try GamePackArchive.unpack(source, into: unpacked, maxBytes: maxBytes, maxFiles: maxFiles)
        }

        // Accept the manifest at the top level, or inside a single top-level folder.
        var packRoot = unpacked
        if !FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("manifest.json").path) {
            let entries = ((try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
            if entries.count == 1 { packRoot = entries[0] }
        }
        let validated = try GamePack.load(from: packRoot)
        if let error = validated.scriptSyntaxError() { throw GamePackError.scriptError(error) }

        let destination = root.appendingPathComponent(validated.manifest.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: packRoot)
        } else {
            try FileManager.default.moveItem(at: packRoot, to: destination)
        }
        return try GamePack.load(from: destination)
    }

    func export(_ pack: GamePack, to archive: URL) throws {
        try GamePackArchive.pack(pack.directory, to: archive)
    }

    func remove(_ pack: GamePack) throws {
        try FileManager.default.removeItem(at: pack.directory)
    }
}
