import SwiftUI
import AVFoundation

/// The live camera, or a neutral stand-in when rendering snapshots (no real camera imagery is
/// ever written into a snapshot).
struct CameraBackground: View {
    let session: AVCaptureSession

    var body: some View {
        if Snapshot.isActive {
            ZStack {
                LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.32), Color(red: 0.18, green: 0.16, blue: 0.15)],
                               startPoint: .top, endPoint: .bottom)
                Text("🧒").font(.system(size: 260)).opacity(0.35).offset(y: 60)
            }
        } else {
            CameraPreview(session: session)
        }
    }
}

/// Debug-only: `JiggleJam -snapshot <folder>` renders the app's screens to PNGs and quits.
/// Used to review the UI without screen recording, and for README screenshots.
enum Snapshot {
    static var outputFolder: URL? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        #else
        return nil
        #endif
    }

    static var isActive: Bool { outputFolder != nil }

    @MainActor
    static func renderAll(camera: CameraManager, library: GameLibrary) {
        guard let folder = outputFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let size = CGSize(width: 1440, height: 900)

        // Render through a real (offscreen) window so native controls draw properly.
        func write<V: View>(_ name: String, _ view: V, settle: Double = 0.6) {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(settle))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
            window.orderOut(nil)
        }

        write("menu", MenuView(camera: camera, library: library, message: .constant(nil),
                               onPlay: { _ in }, onMeasureLatency: {}))
        if let game = library.games.first {
            write("setup", SetupView(camera: camera, game: game, warnTooClose: true, onReady: {}))
        }
        if let pack = library.games.first(where: { !$0.isBuiltIn }) {
            write("setup-pack", SetupView(camera: camera, game: pack, warnTooClose: true, onReady: {}))
        }
        NSApp.terminate(nil)
    }
}
