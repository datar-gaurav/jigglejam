import SwiftUI
import SpriteKit
import AVFoundation
import UniformTypeIdentifiers

@main
struct JiggleJamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 620)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"]) // open .jigglegame files in this window
        }
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: ["*"])
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var library = GameLibrary(builtIns: BuiltInGames.all)
    @State private var game: GameEntry?
    @State private var measuringLatency = false
    @State private var message: LibraryMessage?

    var body: some View {
        ZStack {
            if measuringLatency {
                LatencyTestView(camera: camera) { measuringLatency = false }
            } else if let game {
                GameView(camera: camera, game: game) { self.game = nil }
                    .id(game)
            } else {
                MenuView(camera: camera, library: library, message: $message,
                         onPlay: { game = $0 }, onMeasureLatency: { measuringLatency = true })
            }
        }
        .onAppear { camera.start() }
        .onOpenURL { url in
            // Double-clicking a .jigglegame file in Finder.
            guard url.isFileURL else { return }
            game = nil
            Task { @MainActor in
                do {
                    let entry = try await library.importGame(from: url)
                    message = LibraryMessage(title: "Added \(entry.emoji) \(entry.title)", detail: "It's in the menu now.")
                } catch {
                    message = LibraryMessage(title: "Couldn't add that game", detail: error.localizedDescription)
                }
            }
        }
    }
}

struct LibraryMessage: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

// MARK: - Game

struct GameView: View {
    @ObservedObject var camera: CameraManager
    let game: GameEntry
    let onExit: () -> Void
    @State private var scene: GameScene
    @State private var ready = false
    private let showsCamera: Bool
    @State private var showStats = false
    @AppStorage("warnTooClose") private var warnTooClose = true

    init(camera: CameraManager, game: GameEntry, onExit: @escaping () -> Void) {
        self.camera = camera
        self.game = game
        self.onExit = onExit
        _scene = State(initialValue: game.scene())
        showsCamera = game.showsCamera
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if ready {
                playing
            } else {
                SetupView(camera: camera, game: game, warnTooClose: warnTooClose) { ready = true }
            }
            Button(action: onExit) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 30))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.5))
            .padding(24)
            .keyboardShortcut(.cancelAction) // Esc goes back to the menu
            .help("Back to menu (Esc)")
        }
        .onAppear {
            let camera = camera
            scene.frameProvider = { camera.latestFrame }
            camera.handTrackingEnabled = scene.wantsHandTracking
            scene.distanceWarningEnabled = warnTooClose
        }
        .onChange(of: warnTooClose) { _, on in scene.distanceWarningEnabled = on }
        .onDisappear {
            scene.tearDown()
            camera.handTrackingEnabled = false
        }
    }

    @ViewBuilder private var playing: some View {
        ZStack(alignment: .topLeading) {
            if showsCamera {
                CameraPreview(session: camera.session).ignoresSafeArea()
            }
            SpriteView(scene: scene, preferredFramesPerSecond: 60, options: [.allowsTransparency, .ignoresSiblingOrder],
                       debugOptions: showStats ? [.showsFPS, .showsNodeCount] : [])
                .ignoresSafeArea()
            if !showsCamera {
                TrackingWindow(camera: camera, scene: scene)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(20)
            }
            if showStats {
                Text(camera.stats)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(24)
            }
            Button("") { showStats.toggle() }
                .keyboardShortcut("d", modifiers: [])
                .opacity(0)
        }
    }
}

// MARK: - Menu (for the parent)

struct MenuView: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var library: GameLibrary
    @Binding var message: LibraryMessage?
    let onPlay: (GameEntry) -> Void
    let onMeasureLatency: () -> Void
    @AppStorage("warnTooClose") private var warnTooClose = true

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session).ignoresSafeArea()
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(spacing: 28) {
                Text("Jiggle Jam")
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)

                // Scrolls when there are more games than fit, so the controls below stay on screen.
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 190), spacing: 18)], spacing: 18) {
                        ForEach(Array(library.games.enumerated()), id: \.element.id) { index, game in
                            gameCard(game, index: index)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.automatic)
                .frame(maxWidth: 1060, minHeight: 190, maxHeight: 400)
                .layoutPriority(-1) // give up height before the controls do

                HStack(spacing: 12) {
                    Button("➕ Import game…", action: importGame)
                        .help("Add a .jigglegame file")
                        .disabled(library.isBusy)
                    if library.isBusy {
                        ProgressView().controlSize(.small)
                        Text("Adding game…").font(.callout).foregroundStyle(.white)
                    } else {
                        Text("Right-click an imported game to export or remove it.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                status

                HStack(spacing: 16) {
                    Picker("Camera", selection: Binding(
                        get: { camera.switchingToID ?? camera.currentDeviceID ?? "" },
                        set: { camera.select($0) }
                    )) {
                        ForEach(camera.devices, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.uniqueID)
                        }
                    }
                    .frame(width: 340)

                    Button("Refresh") { camera.refresh() }
                    Toggle("Warn when too close", isOn: $warnTooClose)
                        .toggleStyle(.switch)
                        .foregroundStyle(.white)
                    Button("Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    Button("📏 Display delay test", action: onMeasureLatency)
                        .help("Display-to-camera loopback: compare HDMI and AirPlay")
                }

                if let notice = camera.cameraNotice {
                    Text(notice)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .multilineTextAlignment(.center)
                }

                if !camera.stats.isEmpty {
                    Text(camera.stats)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }

                if camera.authorization == .authorized && !camera.hasIPhone {
                    Text("No iPhone camera found. Lock the iPhone, put it in landscape and keep it still near the Mac, then click Refresh.")
                        .font(.callout)
                        .foregroundStyle(.yellow)
                        .multilineTextAlignment(.center)
                }

                Text("To play on the TV: Control Center → Screen Mirroring → choose your TV, then go Full Screen.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(40)
        }
        .alert(item: $message) { m in
            Alert(title: Text(m.title), message: Text(m.detail))
        }
    }

    @ViewBuilder private func gameCard(_ game: GameEntry, index: Int) -> some View {
        let card = Button { onPlay(game) } label: {
            VStack(spacing: 8) {
                Text(game.emoji).font(.system(size: 70))
                Text(game.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(10)
            .frame(width: 170, height: 170)
            .background(RoundedRectangle(cornerRadius: 30).fill(game.color.gradient))
            .overlay(alignment: .topTrailing) {
                if !game.isBuiltIn { Text("📦").font(.system(size: 22)).padding(10) }
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(game.pack?.manifest.description ?? game.title)
        .contextMenu {
            if game.isBuiltIn {
                Text("Built-in game")
            } else {
                Button("Export…") { export(game) }
                Button("Remove", role: .destructive) { remove(game) }
                if let author = game.pack?.manifest.author { Text("By \(author)") }
            }
        }

        if index < 9 {
            card.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
        } else {
            card
        }
    }

    private func importGame() {
        let panel = NSOpenPanel()
        panel.title = "Import a Jiggle Jam game"
        panel.allowedContentTypes = [UTType(filenameExtension: GamePack.fileExtension) ?? .zip, .zip, .folder]
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let entry = try await library.importGame(from: url)
                message = LibraryMessage(title: "Added \(entry.emoji) \(entry.title)", detail: "It's in the menu now.")
            } catch {
                message = LibraryMessage(title: "Couldn't add that game", detail: error.localizedDescription)
            }
        }
    }

    private func export(_ game: GameEntry) {
        let panel = NSSavePanel()
        panel.title = "Export \(game.title)"
        panel.nameFieldStringValue = "\(game.title).\(GamePack.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: GamePack.fileExtension) ?? .zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                try await library.export(game, to: url)
                message = LibraryMessage(title: "Exported \(game.title)", detail: "Share \(url.lastPathComponent); double-click it to add it to Jiggle Jam.")
            } catch {
                message = LibraryMessage(title: "Couldn't export that game", detail: error.localizedDescription)
            }
        }
    }

    private func remove(_ game: GameEntry) {
        do { try library.remove(game) } catch {
            message = LibraryMessage(title: "Couldn't remove that game", detail: error.localizedDescription)
        }
    }

    @ViewBuilder private var status: some View {
        switch camera.authorization {
        case .denied, .restricted:
            VStack(spacing: 8) {
                Text("Camera access is off.").font(.title2.bold())
                HStack {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                    Button("I've turned it on") { camera.refresh() }
                }
                Text("Turn on Jiggle Jam under Camera, then come back. If macOS asks to quit and reopen, do that.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .foregroundStyle(.white)
        default:
            Text(statusText)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
        }
    }

    private var statusText: String {
        if warnTooClose && camera.tooClose { return "✋ Too close — take a big step back" }
        switch camera.peopleCount {
        case 0: return "👀 Looking for players… stand back so the camera sees your whole body"
        case 1: return "✅ I can see you!"
        default: return "✅ I can see \(camera.peopleCount) players!"
        }
    }
}

// MARK: - Tracking window

/// Small live camera view with what the trackers see drawn on top, for games that hide the camera.
/// Big green dots: hands (hand tracker). Small yellow dots: body joints (body tracker).
struct TrackingWindow: View {
    let camera: CameraManager
    let scene: GameScene

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session)
            TrackingOverlay(camera: camera) { frame in
                "✋ \(frame.hands.count)  🧍 \(frame.bodies.count)  \(scene.debugText)"
            }
        }
        .frame(width: 400, height: 225)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.7), lineWidth: 2))
        .shadow(radius: 8)
    }
}

/// Draws what the trackers see over a `CameraPreview` of the same size.
/// Green: hands from the hand tracker (joined by a line). Yellow: body joints.
struct TrackingOverlay: View {
    let camera: CameraManager
    var dotScale: CGFloat = 1
    var label: ((PoseFrame) -> String)?

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                let frame = camera.latestFrame
                guard frame.isFresh() else { return }
                // Same aspect-fill mapping as the preview layer, with SwiftUI's top-left origin.
                let scale = max(size.width / frame.imageSize.width, size.height / frame.imageSize.height)
                let w = frame.imageSize.width * scale, h = frame.imageSize.height * scale
                func point(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: (size.width - w) / 2 + p.x * w, y: size.height - ((size.height - h) / 2 + p.y * h))
                }
                func dot(_ p: CGPoint, _ r: CGFloat, _ color: Color) {
                    let c = point(p), r = r * dotScale
                    context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color))
                }

                for body in frame.bodies {
                    for (_, p) in body { dot(p, 4, .yellow) }
                }
                if frame.hands.count >= 2 {
                    var line = Path()
                    line.move(to: point(frame.hands[0]))
                    line.addLine(to: point(frame.hands[1]))
                    context.stroke(line, with: .color(.green), lineWidth: 4 * dotScale)
                }
                for hand in frame.hands { dot(hand, 10, .green) }

                if let label {
                    context.draw(
                        Text(label(frame)).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundColor(.white),
                        at: CGPoint(x: size.width / 2, y: size.height - 14)
                    )
                }
            }
        }
    }
}
