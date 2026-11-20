import SwiftUI
import SpriteKit
import AVFoundation

@main
struct GameCubeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 960, minHeight: 540)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var playing = false

    var body: some View {
        ZStack {
            if playing {
                GameView(camera: camera) { playing = false }
            } else {
                MenuView(camera: camera) { playing = true }
            }
        }
        .onAppear { camera.start() }
    }
}

// MARK: - Game

struct GameView: View {
    @ObservedObject var camera: CameraManager
    let onExit: () -> Void

    @State private var scene: BubbleScene = {
        let scene = BubbleScene(size: CGSize(width: 1280, height: 720))
        scene.scaleMode = .resizeFill
        return scene
    }()

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
    }
}

// MARK: - Menu (for the parent)

struct MenuView: View {
    @ObservedObject var camera: CameraManager
    let onPlay: () -> Void

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session).ignoresSafeArea()
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(spacing: 28) {
                Text("GameCube")
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)

                Button(action: onPlay) {
                    VStack(spacing: 10) {
                        Text("🫧").font(.system(size: 96))
                        Text("Bubble Pop").font(.system(size: 36, weight: .bold, design: .rounded))
                    }
                    .padding(.horizontal, 48)
                    .padding(.vertical, 32)
                    .background(RoundedRectangle(cornerRadius: 32).fill(Color.pink.gradient))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

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

                    Button("Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
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
