import SwiftUI
import AVFoundation

/// Live, mirrored camera feed so the player sees themselves like in a mirror.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateNSView(_ nsView: PreviewView, context: Context) {}
}

final class PreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private var observer: NSObjectProtocol?

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspectFill // must match the mapping in games
        layer?.addSublayer(previewLayer)
        observer = NotificationCenter.default.addObserver(forName: .cameraDidSwitch, object: nil, queue: .main) { [weak self] _ in
            self?.applyMirroring()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.applyMirroring() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
        applyMirroring()
    }

    private func applyMirroring() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        if connection.automaticallyAdjustsVideoMirroring { connection.automaticallyAdjustsVideoMirroring = false }
        if !connection.isVideoMirrored { connection.isVideoMirrored = true }
    }
}
