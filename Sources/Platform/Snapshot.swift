import SwiftUI
import AVFoundation
import SpriteKit
import Metal

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
        // Games: each runs for a moment with a simulated player, composited over the camera placeholder.
        let backdrop = render(CameraBackground(session: camera.session))
        for game in library.games {
            writeScene("game-\(game.id.replacingOccurrences(of: ":", with: "-"))", game, backdrop: backdrop,
                       seconds: 2.5, pose: Self.simulatedPlayer)
        }
        if let bubbles = library.games.first(where: { $0.id == "bubblePop" }) {
            writeScene("overlay-too-close", bubbles, backdrop: backdrop, seconds: 1.4) {
                var frame = Self.simulatedPlayer()
                frame.tooClose = true
                return frame
            }
            writeScene("overlay-looking", bubbles, backdrop: backdrop, seconds: 2.2) { PoseFrame() }
        }
        NSApp.terminate(nil)
    }

    @MainActor
    private static func render<V: View>(_ view: V) -> NSImage? {
        let size = CGSize(width: 1440, height: 900)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Runs a game offscreen with SKRenderer (an SKView in a hidden window doesn't tick), stepping
    /// the game loop at 60 updates per simulated second, then renders the last frame.
    @MainActor
    private static func writeScene(_ name: String, _ game: GameEntry, backdrop: NSImage?, seconds: Double,
                                   pose: @escaping () -> PoseFrame) {
        guard let folder = outputFolder, let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }
        let width = 1440, height = 900
        let size = CGSize(width: width, height: height)

        let scene = game.scene()
        scene.frameProvider = pose
        scene.scaleMode = .fill // .resizeFill follows a view, and SKRenderer has none (size would be 0)
        scene.size = size
        scene.didMove(to: SKView(frame: CGRect(origin: .zero, size: size)))
        let renderer = SKRenderer(device: device)
        renderer.scene = scene
        defer { scene.tearDown() }

        var time = 0.0
        for _ in 0..<Int(seconds * 60) {
            time += 1.0 / 60
            renderer.update(atTime: time)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        renderer.render(withViewport: CGRect(origin: .zero, size: size), commandBuffer: buffer, renderPassDescriptor: pass)
        buffer.commit()
        buffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let sceneImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }

        let output = NSImage(size: size)
        output.lockFocus()
        if game.showsCamera {
            backdrop?.draw(in: CGRect(origin: .zero, size: size))
        } else {
            // SKRenderer doesn't paint the scene's background color; do it here.
            scene.backgroundColor.setFill()
            CGRect(origin: .zero, size: size).fill()
        }
        NSGraphicsContext.current?.cgContext.draw(sceneImage, in: CGRect(origin: .zero, size: size))
        output.unlockFocus()
        guard let tiff = output.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: folder.appendingPathComponent("\(name).png"))
    }

    private static var simulatedFrame = 0

    /// A child standing mid-frame, waving, with feet in view: enough for every game to run.
    static func simulatedPlayer() -> PoseFrame {
        simulatedFrame += 1
        let t = Double(simulatedFrame) / 60
        let wave = CGFloat(sin(t * 3)) * 0.05
        let points: [Joint: CGPoint] = [
            .nose: CGPoint(x: 0.5, y: 0.78), .neck: CGPoint(x: 0.5, y: 0.7), .root: CGPoint(x: 0.5, y: 0.45),
            .leftShoulder: CGPoint(x: 0.44, y: 0.69), .rightShoulder: CGPoint(x: 0.56, y: 0.69),
            .leftElbow: CGPoint(x: 0.36, y: 0.74 + wave), .rightElbow: CGPoint(x: 0.64, y: 0.74 - wave),
            .leftWrist: CGPoint(x: 0.31, y: 0.84 + wave), .rightWrist: CGPoint(x: 0.69, y: 0.84 - wave),
            .leftHip: CGPoint(x: 0.47, y: 0.45), .rightHip: CGPoint(x: 0.53, y: 0.45),
            .leftKnee: CGPoint(x: 0.47, y: 0.3), .rightKnee: CGPoint(x: 0.53, y: 0.3),
            .leftAnkle: CGPoint(x: 0.47, y: 0.14), .rightAnkle: CGPoint(x: 0.53, y: 0.14),
        ]
        return PoseFrame(poppers: CameraManager.poppers(from: points), bodies: [points], peopleCount: 1,
                         imageSize: CGSize(width: 1280, height: 720), timestamp: t, receivedAt: uptime())
    }
}
