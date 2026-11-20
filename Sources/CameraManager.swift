import AVFoundation
import Vision
import Combine

/// A body part that can pop things in a game.
struct Popper {
    enum Kind { case hand, foot }
    var kind: Kind
    /// Normalized image coordinates (0...1), already mirrored, origin bottom-left.
    var point: CGPoint
}

typealias Joint = VNHumanBodyPoseObservation.JointName

/// All confidently-tracked joints of one person (normalized, mirrored, origin bottom-left).
typealias Body = [Joint: CGPoint]

/// The latest body-tracking result, read by games every frame.
struct PoseFrame {
    var poppers: [Popper] = []
    var bodies: [Body] = []
    var peopleCount = 0
    var imageSize = CGSize(width: 1280, height: 720)
    /// Camera timestamp in seconds; changes only when a new camera frame was analysed.
    var timestamp: Double = 0
}

extension Notification.Name {
    static let cameraDidSwitch = Notification.Name("JiggleJam.cameraDidSwitch")
}

/// Owns the camera session and runs Vision body-pose detection on every frame.
/// Works with the built-in camera, external webcams and an iPhone via Continuity Camera.
final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var currentDeviceID: String?
    @Published private(set) var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var peopleCount = 0
    /// e.g. "1280×720 · 30 fps · tracking 14 ms" — shown in the menu to diagnose lag.
    @Published private(set) var stats = ""

    private let sessionQueue = DispatchQueue(label: "jigglejam.session")
    private let videoQueue = DispatchQueue(label: "jigglejam.video", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let poseRequest = VNDetectHumanBodyPoseRequest()
    private let lock = NSLock()
    private var frame = PoseFrame()
    private var lastPeopleCount = 0 // videoQueue only
    private var statFrames = 0, statTrackingTime = 0.0, statStart = CACurrentMediaTime() // videoQueue only
    private var configured = false
    private var observers: [NSObjectProtocol] = []

    /// Thread-safe snapshot of the most recent pose result.
    var latestFrame: PoseFrame {
        lock.lock(); defer { lock.unlock() }
        return frame
    }

    override init() {
        super.init()
        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshDevices()
            })
        }
    }

    func start() {
        guard !configured else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.authorization = AVCaptureDevice.authorizationStatus(for: .video)
                    if granted { self.configureAndRun() }
                }
            }
        default:
            authorization = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    func select(_ id: String) {
        guard let device = devices.first(where: { $0.uniqueID == id }) else { return }
        currentDeviceID = id
        sessionQueue.async {
            self.session.beginConfiguration()
            self.attach(device)
            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { NotificationCenter.default.post(name: .cameraDidSwitch, object: nil) }
        }
    }

    // MARK: - Devices

    private func discover() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// Prefer the iPhone (Continuity Camera): wider view and easier to place near the TV.
    private func preferredDevice() -> AVCaptureDevice? {
        devices.first { $0.deviceType == .continuityCamera } ?? devices.first
    }

    var hasIPhone: Bool { devices.contains { $0.deviceType == .continuityCamera } }

    func refreshDevices() {
        devices = discover()
        guard configured else { return }
        let currentStillThere = devices.contains { $0.uniqueID == currentDeviceID }
        if !currentStillThere, let next = preferredDevice() {
            select(next.uniqueID)
        }
    }

    // MARK: - Session

    private func configureAndRun() {
        authorization = .authorized
        configured = true
        devices = discover()
        let device = preferredDevice()
        currentDeviceID = device?.uniqueID
        sessionQueue.async {
            self.session.beginConfiguration()
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(self.videoOutput) { self.session.addOutput(self.videoOutput) }
            if let device { self.attach(device) }
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async { NotificationCenter.default.post(name: .cameraDidSwitch, object: nil) }
        }
    }

    /// Call on sessionQueue between begin/commitConfiguration.
    private func attach(_ device: AVCaptureDevice) {
        session.inputs.forEach { session.removeInput($0) }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        useSmallFormat(device)
        // Keep analysed frames un-mirrored; mirroring is applied in the coordinate math.
        if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }
}

// MARK: - Resolution

extension CameraManager {
    /// Body tracking needs ~720p at most; bigger frames (an iPhone defaults to 1080p+) only add lag.
    /// Must run after the input is added, since supported presets depend on the camera.
    fileprivate func useSmallFormat(_ device: AVCaptureDevice) {
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
            return
        }
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions { CMVideoFormatDescriptionGetDimensions(f.formatDescription) }
        let candidates = device.formats.filter { f in
            dims(f).width >= 640 && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        // Closest to 1280 wide.
        guard let best = candidates.min(by: { abs(Int(dims($0).width) - 1280) < abs(Int(dims($1).width) - 1280) }),
              (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = best
        device.unlockForConfiguration()
    }
}

// MARK: - Pose detection

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        let started = CACurrentMediaTime()
        try? handler.perform([poseRequest])
        recordStats(trackingTime: CACurrentMediaTime() - started, size: size)
        let people = poseRequest.results ?? []

        let bodies = people.map(Self.body(from:))
        let next = PoseFrame(
            poppers: bodies.flatMap(Self.poppers(from:)),
            bodies: bodies,
            peopleCount: people.count,
            imageSize: size,
            timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        )
        lock.lock(); frame = next; lock.unlock()

        if people.count != lastPeopleCount {
            lastPeopleCount = people.count
            let count = people.count
            DispatchQueue.main.async { self.peopleCount = count }
        }
    }

    private func recordStats(trackingTime: Double, size: CGSize) {
        statFrames += 1
        statTrackingTime += trackingTime
        let elapsed = CACurrentMediaTime() - statStart
        guard elapsed >= 1 else { return }
        let text = String(format: "%.0f×%.0f · %.0f fps · tracking %.0f ms",
                          size.width, size.height, Double(statFrames) / elapsed, statTrackingTime / Double(statFrames) * 1000)
        statFrames = 0; statTrackingTime = 0; statStart = CACurrentMediaTime()
        DispatchQueue.main.async { self.stats = text }
    }

    private static func body(from observation: VNHumanBodyPoseObservation) -> Body {
        guard let points = try? observation.recognizedPoints(.all) else { return [:] }
        var body: Body = [:]
        for (joint, p) in points where p.confidence > 0.25 {
            body[joint] = CGPoint(x: 1 - p.location.x, y: p.location.y) // mirror so it feels like a mirror
        }
        return body
    }

    private static func poppers(from body: Body) -> [Popper] {
        /// Vision tracks wrists, not palms: nudge past the wrist along the forearm to reach the hand.
        func extend(_ tip: Joint, from base: Joint, by amount: CGFloat) -> CGPoint? {
            guard let t = body[tip] else { return nil }
            guard let b = body[base] else { return t }
            return CGPoint(x: t.x + (t.x - b.x) * amount, y: t.y + (t.y - b.y) * amount)
        }

        var result: [Popper] = []
        let hands: [(Joint, Joint)] = [(.leftWrist, .leftElbow), (.rightWrist, .rightElbow)]
        for (wrist, elbow) in hands {
            if let p = extend(wrist, from: elbow, by: 0.3) { result.append(Popper(kind: .hand, point: p)) }
        }
        for ankle in [Joint.leftAnkle, .rightAnkle] {
            if let p = body[ankle] { result.append(Popper(kind: .foot, point: p)) }
        }
        return result
    }
}
