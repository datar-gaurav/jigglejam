import SwiftUI
import SpriteKit
import AVFoundation

@main
struct JiggleJamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 960, minHeight: 540)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

enum Game: String, CaseIterable, Identifiable {
    case bubblePop, freezeDance
    var id: String { rawValue }

    var title: String {
        switch self {
        case .bubblePop: return "Bubble Pop"
        case .freezeDance: return "Freeze Dance"
        }
    }

    var emoji: String {
        switch self {
        case .bubblePop: return "🫧"
        case .freezeDance: return "🥶"
        }
    }

    var color: Color {
        switch self {
        case .bubblePop: return .pink
        case .freezeDance: return .blue
        }
    }

    func makeScene() -> GameScene {
        let scene: GameScene
        switch self {
        case .bubblePop: scene = BubbleScene(size: CGSize(width: 1280, height: 720))
        case .freezeDance: scene = FreezeDanceScene(size: CGSize(width: 1280, height: 720))
        }
        scene.scaleMode = .resizeFill
        return scene
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var game: Game?

    var body: some View {
        ZStack {
            if let game {
                GameView(camera: camera, game: game) { self.game = nil }
                    .id(game)
            } else {
                MenuView(camera: camera) { game = $0 }
            }
        }
        .onAppear { camera.start() }
    }
}

// MARK: - Game

struct GameView: View {
    @ObservedObject var camera: CameraManager
    let onExit: () -> Void
    @State private var scene: GameScene

    init(camera: CameraManager, game: Game, onExit: @escaping () -> Void) {
        self.camera = camera
        self.onExit = onExit
        _scene = State(initialValue: game.makeScene())
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CameraPreview(session: camera.session).ignoresSafeArea()
            SpriteView(scene: scene, options: [.allowsTransparency]).ignoresSafeArea()
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
        }
        .onDisappear { scene.tearDown() }
    }
}

// MARK: - Menu (for the parent)

struct MenuView: View {
    @ObservedObject var camera: CameraManager
    let onPlay: (Game) -> Void

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session).ignoresSafeArea()
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(spacing: 28) {
                Text("Jiggle Jam")
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)

                HStack(spacing: 28) {
                    ForEach(Array(Game.allCases.enumerated()), id: \.element) { index, game in
                        Button { onPlay(game) } label: {
                            VStack(spacing: 10) {
                                Text(game.emoji).font(.system(size: 96))
                                Text(game.title).font(.system(size: 34, weight: .bold, design: .rounded))
                            }
                            .frame(width: 280, height: 220)
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
                        get: { camera.currentDeviceID ?? "" },
                        set: { camera.select($0) }
                    )) {
                        ForEach(camera.devices, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.uniqueID)
                        }
                    }
                    .frame(width: 340)

                    Button("Refresh") { camera.refreshDevices() }
                    Button("Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
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
        switch camera.peopleCount {
        case 0: return "👀 Looking for players… stand back so the camera sees your whole body"
        case 1: return "✅ I can see you!"
        default: return "✅ I can see \(camera.peopleCount) players!"
        }
    }
}
