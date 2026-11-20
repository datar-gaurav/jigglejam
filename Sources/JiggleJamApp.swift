import SwiftUI
import SpriteKit
import AVFoundation

@main
struct JiggleJamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

enum Game: String, CaseIterable, Identifiable {
    case bubblePop, freezeDance, rocketJump, driving, foxTrail
    var id: String { rawValue }

    var title: String {
        switch self {
        case .bubblePop: return "Bubble Pop"
        case .freezeDance: return "Freeze Dance"
        case .rocketJump: return "Rocket Jump"
        case .driving: return "Vroom Vroom"
        case .foxTrail: return "Fox Trail"
        }
    }

    var emoji: String {
        switch self {
        case .bubblePop: return "🫧"
        case .freezeDance: return "🥶"
        case .rocketJump: return "🚀"
        case .driving: return "🚗"
        case .foxTrail: return "🦊"
        }
    }

    var color: Color {
        switch self {
        case .bubblePop: return .pink
        case .freezeDance: return .blue
        case .rocketJump: return .orange
        case .driving: return .green
        case .foxTrail: return .purple
        }
    }

    /// These games draw their own world; the camera still runs for tracking, shown in a small window.
    var showsCamera: Bool { self != .driving && self != .foxTrail }

    func makeScene() -> GameScene {
        let scene: GameScene
        switch self {
        case .bubblePop: scene = BubbleScene(size: CGSize(width: 1280, height: 720))
        case .freezeDance: scene = FreezeDanceScene(size: CGSize(width: 1280, height: 720))
        case .rocketJump: scene = RocketJumpScene(size: CGSize(width: 1280, height: 720))
        case .driving: scene = DrivingScene(size: CGSize(width: 1280, height: 720))
        case .foxTrail: scene = FoxTrailScene(size: CGSize(width: 1280, height: 720))
        }
        scene.scaleMode = .resizeFill
        return scene
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var game: Game?
    @State private var measuringLatency = false

    var body: some View {
        ZStack {
            if measuringLatency {
                LatencyTestView(camera: camera) { measuringLatency = false }
            } else if let game {
                GameView(camera: camera, game: game) { self.game = nil }
                    .id(game)
            } else {
                MenuView(camera: camera, onPlay: { game = $0 }, onMeasureLatency: { measuringLatency = true })
            }
        }
        .onAppear { camera.start() }
    }
}

// MARK: - Game

struct GameView: View {
    @ObservedObject var camera: CameraManager
    let game: Game
    let onExit: () -> Void
    @State private var scene: GameScene
    @State private var ready = false
    private let showsCamera: Bool
    @State private var showStats = false
    @AppStorage("warnTooClose") private var warnTooClose = true

    init(camera: CameraManager, game: Game, onExit: @escaping () -> Void) {
        self.camera = camera
        self.game = game
        self.onExit = onExit
        _scene = State(initialValue: game.makeScene())
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
    let onPlay: (Game) -> Void
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

                HStack(spacing: 20) {
                    ForEach(Array(Game.allCases.enumerated()), id: \.element) { index, game in
                        Button { onPlay(game) } label: {
                            VStack(spacing: 10) {
                                Text(game.emoji).font(.system(size: 80))
                                Text(game.title).font(.system(size: 28, weight: .bold, design: .rounded))
                            }
                            .frame(width: 190, height: 190)
                            .background(RoundedRectangle(cornerRadius: 32).fill(game.color.gradient))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                        .help("Press \(index + 1)")
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

                    Button("Refresh") { camera.refreshDevices() }
                    Toggle("Warn when too close", isOn: $warnTooClose)
                        .toggleStyle(.switch)
                        .foregroundStyle(.white)
                    Button("Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    Button("📏 Measure TV delay", action: onMeasureLatency)
                        .help("Times how long it takes for a change on screen to reach the player and back")
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
    }

    @ViewBuilder private var status: some View {
        switch camera.authorization {
        case .denied, .restricted:
            VStack(spacing: 8) {
                Text("Camera access is off.").font(.title2.bold())
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
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
