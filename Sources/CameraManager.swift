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
    /// Someone is so close to the camera that their whole body no longer fits.
    var tooClose = false
    /// Hand centers from the dedicated hand tracker (only filled when hand tracking is on).
    /// Normalized, mirrored, origin bottom-left. Works up close and with the body hidden.
    var hands: [CGPoint] = []
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
    @Published private(set) var tooClose = false
    /// e.g. "1280×720 · 30 fps · tracking 14 ms" — shown in the menu to diagnose lag.
    @Published private(set) var stats = ""

    private let sessionQueue = DispatchQueue(label: "jigglejam.session")
    private let videoQueue = DispatchQueue(label: "jigglejam.video", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let poseRequest = VNDetectHumanBodyPoseRequest()
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()
    private let lock = NSLock()
    private var _handTracking = false

    /// Hand tracking costs extra time per frame, so games turn it on only when they need it.
    var handTrackingEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _handTracking }
        set { lock.lock(); _handTracking = newValue; lock.unlock() }
    }
    private var frame = PoseFrame()
    private var lastPeopleCount = 0 // videoQueue only
    private var lastTooClose = false // videoQueue only
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
        let wantHands = handTrackingEnabled
        try? handler.perform(wantHands ? [poseRequest, handRequest] : [poseRequest])
        let hands = wantHands ? (handRequest.results ?? []).compactMap(Self.handCenter(from:)) : []
        recordStats(trackingTime: CACurrentMediaTime() - started, size: size)
        let people = poseRequest.results ?? []

        let bodies = people.map(Self.body(from:))
        let next = PoseFrame(
            poppers: bodies.flatMap(Self.poppers(from:)),
            bodies: bodies,
            peopleCount: people.count,
            tooClose: bodies.contains(where: Self.isTooClose),
            hands: hands,
            imageSize: size,
            timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        )
        lock.lock(); frame = next; lock.unlock()

        if next.tooClose != lastTooClose {
            lastTooClose = next.tooClose
            let close = next.tooClose
            DispatchQueue.main.async { self.tooClose = close }
        }

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

    private static func handCenter(from observation: VNHumanHandPoseObservation) -> CGPoint? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        // The palm (wrist + knuckles) stays put while fingers flicker in and out of detection.
        let palmJoints: [VNHumanHandPoseObservation.JointName] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let palm = palmJoints.compactMap { points[$0] }.filter { $0.confidence > 0.3 }
        let confident = palm.count >= 2 ? palm : points.values.filter { $0.confidence > 0.3 }
        guard confident.count >= 2 else { return nil }
        let x = confident.reduce(0) { $0 + $1.location.x } / CGFloat(confident.count)
        let y = confident.reduce(0) { $0 + $1.location.y } / CGFloat(confident.count)
        return CGPoint(x: 1 - x, y: y)
    }

    private static func body(from observation: VNHumanBodyPoseObservation) -> Body {
        guard let points = try? observation.recognizedPoints(.all) else { return [:] }
        var body: Body = [:]
        for (joint, p) in points where p.confidence > 0.25 {
            body[joint] = CGPoint(x: 1 - p.location.x, y: p.location.y) // mirror so it feels like a mirror
        }
        return body
    }

    /// Too close when only the upper body is visible, or the shoulders/torso fill too much of the frame.
    /// Tuning: raise the numbers to allow standing closer.
    private static func isTooClose(_ body: Body) -> Bool {
        let hasShoulders = body[.leftShoulder] != nil || body[.rightShoulder] != nil
        guard hasShoulders else { return false }
        let noAnkles = body[.leftAnkle] == nil && body[.rightAnkle] == nil
        let noKnees = body[.leftKnee] == nil && body[.rightKnee] == nil
        if noAnkles && noKnees { return true }

        if let l = body[.leftShoulder], let r = body[.rightShoulder], abs(l.x - r.x) > 0.22 { return true }
        if noAnkles, let neck = body[.neck], let root = body[.root], neck.y - root.y > 0.30 { return true }
        return false
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
