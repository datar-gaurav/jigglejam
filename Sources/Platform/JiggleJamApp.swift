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
        .onAppear {
            if Snapshot.isActive {
                DispatchQueue.main.async { Snapshot.renderAll(camera: camera, library: library) }
            } else {
                camera.start()
            }
        }
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
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 40, height: 40)
                    .glass(Circle())
            }
            .buttonStyle(PressableStyle())
            .padding(22)
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
                CameraBackground(session: camera.session).ignoresSafeArea()
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

// MARK: - Menu

struct MenuView: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var library: GameLibrary
    @Binding var message: LibraryMessage?
    let onPlay: (GameEntry) -> Void
    let onMeasureLatency: () -> Void
    @AppStorage("warnTooClose") private var warnTooClose = true
    @State private var showTVHelp = false
    @StateObject private var soundCheck = SoundCheck()

    private var cameraBlocked: Bool { camera.authorization == .denied || camera.authorization == .restricted }

    var body: some View {
        ZStack {
            MenuBackground(camera: camera)

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 48)
                    .padding(.top, 34)

                if cameraBlocked {
                    Spacer()
                    permissionCard
                    Spacer()
                } else {
                    GeometryReader { space in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 230), spacing: 24)], spacing: 24) {
                            ForEach(Array(library.games.enumerated()), id: \.element.id) { index, game in
                                GameCard(game: game, number: index + 1,
                                         onPlay: { onPlay(game) },
                                         onExport: { export(game) },
                                         onRemove: { remove(game) })
                            }
                            AddGameCard(busy: library.isBusy, action: importGame)
                        }
                        .frame(maxWidth: 1240)
                        .padding(.horizontal, 48)
                        .padding(.vertical, 30)
                        // Centered when everything fits; scrolls when it doesn't.
                        .frame(maxWidth: .infinity, minHeight: space.size.height)
                    }
                    .scrollIndicators(.never)
                    }
                }

                notices
                    .padding(.bottom, 14)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: soundCheck.playingOn)
                controlBar
                    .padding(.bottom, 28)
            }
        }
        .environment(\.colorScheme, .dark)
        .alert(item: $message) { m in
            Alert(title: Text(m.title), message: Text(m.detail))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Jiggle Jam")
                    .font(.system(size: 54, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.brandGradient)
                    .shadow(color: Theme.pink.opacity(0.35), radius: 18)
                Text("Move your body to play")
                    .font(.system(size: 19, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            if !cameraBlocked { StatusPill(kind: status.kind, text: status.text) }
        }
    }

    private var status: (kind: StatusPill.Kind, text: String) {
        if camera.currentDeviceID == nil && camera.devices.isEmpty { return (.warning, "No camera") }
        if warnTooClose && camera.tooClose { return (.warning, "Too close, step back") }
        switch camera.peopleCount {
        case 0: return (.waiting, "Looking for players")
        case 1: return (.good, "1 player ready")
        default: return (.good, "\(camera.peopleCount) players ready")
        }
    }

    // MARK: Camera permission

    private var permissionCard: some View {
        VStack(spacing: 18) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.orange)
            Text("Jiggle Jam needs the camera")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Turn on Jiggle Jam under Privacy & Security → Camera, then come back.\nIf macOS asks to quit and reopen, do that.")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.pink)
                Button("I've turned it on") { camera.refresh() }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .foregroundStyle(.white)
        .padding(40)
        .frame(maxWidth: 560)
        .glass(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    // MARK: Notices and control bar

    @ViewBuilder private var notices: some View {
        VStack(spacing: 8) {
            if let device = soundCheck.playingOn {
                NoticeBanner(symbol: "speaker.wave.2.fill",
                             text: "Sound is playing on \(device). Can't hear it? Check that device's volume, or pick another output in Control Center → Sound.",
                             tint: .green)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let notice = camera.cameraNotice {
                NoticeBanner(symbol: "exclamationmark.triangle.fill", text: notice, tint: Theme.yellow)
            }
            if camera.authorization == .authorized && !camera.hasIPhone {
                NoticeBanner(symbol: "iphone",
                             text: "To use your iPhone as the camera: lock it, stand it up sideways near the Mac, then press ↻.",
                             tint: Theme.blue)
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "video.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.leading, 6)
            if camera.devices.isEmpty {
                Text("No camera found")
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 210, alignment: .leading)
            } else {
                Picker("Camera", selection: Binding(
                    get: { camera.switchingToID ?? camera.currentDeviceID ?? "" },
                    set: { camera.select($0) }
                )) {
                    ForEach(camera.devices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 210)
            }
            BarIconButton(symbol: "arrow.clockwise", help: "Look for cameras again") { camera.refresh() }

            barDivider

            Toggle(isOn: $warnTooClose) {
                Text("Too-close warning").font(.system(size: 13, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Pause games when a player is so close that their feet leave the picture")

            barDivider

            BarIconButton(symbol: "tv", help: "Play on the TV") { showTVHelp.toggle() }
                .popover(isPresented: $showTVHelp, arrowEdge: .top) { tvHelp }
            BarIconButton(symbol: "speaker.wave.2.fill", help: "Sound test: says hello and shows where the sound is playing") {
                soundCheck.run()
            }
            BarIconButton(symbol: "gauge.with.needle", help: "Display delay test (HDMI vs AirPlay)", action: onMeasureLatency)
            BarIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Full screen") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glass(Capsule())
    }

    private var barDivider: some View {
        Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 22)
    }

    private var tvHelp: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Play on the TV").font(.title3.bold())
            ForEach(Array([
                ("rectangle.on.rectangle", "Open Control Center → Screen Mirroring"),
                ("tv", "Choose your TV"),
                ("arrow.up.left.and.arrow.down.right", "Click Full Screen"),
            ].enumerated()), id: \.offset) { index, step in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.pink.opacity(0.85)))
                        .foregroundStyle(.white)
                    Image(systemName: step.0).frame(width: 20)
                    Text(step.1)
                }
            }
            Divider()
            Label("For the least delay, connect the Mac with an HDMI cable.", systemImage: "cable.connector")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !camera.stats.isEmpty {
                Text(camera.stats)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    // MARK: Library actions

    private func importGame() {
        let panel = NSOpenPanel()
        panel.title = "Add a Jiggle Jam game"
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
