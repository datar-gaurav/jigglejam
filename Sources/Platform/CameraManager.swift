import AVFoundation
import AppKit
import Vision
import Combine

extension Notification.Name {
    static let cameraDidSwitch = Notification.Name("JiggleJam.cameraDidSwitch")
}

/// Owns the camera session and runs Vision body-pose detection on every frame.
/// Works with the built-in camera, external webcams and an iPhone via Continuity Camera.
final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var currentDeviceID: String?
    /// Camera the user just picked, while it's being attached; the picker shows this meanwhile.
    @Published private(set) var switchingToID: String?
    /// A problem worth telling the parent about (failed switch, iPhone disconnected…).
    @Published private(set) var cameraNotice: String?
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
    private var _latencyProbe = false

    /// The TV latency test turns this on to measure picture brightness on every frame.
    var latencyProbeEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _latencyProbe }
        set { lock.lock(); _latencyProbe = newValue; lock.unlock() }
    }

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
    private var fellBackFromIPhone = false
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
        // Coming back from System Settings: camera access may have just been granted.
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.recheckAuthorization()
        })
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

    /// Switches camera. The selection only changes once the new camera is attached; if that fails,
    /// the previous camera is restored and `cameraNotice` explains what happened.
    func select(_ id: String, automatic: Bool = false) {
        guard let device = devices.first(where: { $0.uniqueID == id }) else { return }
        switchingToID = id
        sessionQueue.async {
            self.session.beginConfiguration()
            let attached = self.attach(device)
            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async {
                self.switchingToID = nil
                if attached {
                    self.currentDeviceID = id
                    if device.deviceType == .continuityCamera { self.fellBackFromIPhone = false }
                    if !automatic { self.cameraNotice = nil }
                } else {
                    self.cameraNotice = "Couldn't switch to \(device.localizedName), so the previous camera is still on."
                }
                NotificationCenter.default.post(name: .cameraDidSwitch, object: nil)
            }
        }
    }

    /// Picks up a permission change made in System Settings and starts the camera if access
    /// was just granted. Called when the app becomes active and from the menu's Refresh button.
    func recheckAuthorization() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status != authorization { authorization = status }
        guard !configured else { return }
        if status == .authorized || status == .notDetermined { start() }
    }

    /// The menu's Refresh button: recheck permission, then look for cameras again.
    func refresh() {
        recheckAuthorization()
        refreshDevices()
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
        let previous = devices.first { $0.uniqueID == currentDeviceID }
        devices = discover()
        guard configured else { return }

        let currentStillThere = devices.contains { $0.uniqueID == currentDeviceID }
        if !currentStillThere {
            let lostIPhone = previous?.deviceType == .continuityCamera
            if let next = preferredDevice() {
                if lostIPhone {
                    fellBackFromIPhone = true
                    cameraNotice = "📱 iPhone camera disconnected, so the \(next.localizedName) is on for now. It will switch back when the iPhone returns."
                }
                select(next.uniqueID, automatic: true)
            } else {
                currentDeviceID = nil
                cameraNotice = lostIPhone
                    ? "📱 iPhone camera disconnected. Bring it close to the Mac, lock it, and click Refresh."
                    : "No camera found. Connect one and click Refresh."
            }
        } else if fellBackFromIPhone, let phone = devices.first(where: { $0.deviceType == .continuityCamera }) {
            cameraNotice = nil
            select(phone.uniqueID, automatic: true)
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
            let attached = device.map { self.attach($0) } ?? false
            if !attached {
                DispatchQueue.main.async {
                    self.currentDeviceID = nil
                    self.cameraNotice = device == nil ? "No camera found. Connect one and click Refresh."
                                                      : "Couldn't start the \(device!.localizedName). Pick another camera."
                }
            }
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async { NotificationCenter.default.post(name: .cameraDidSwitch, object: nil) }
        }
    }

    /// Call on sessionQueue between begin/commitConfiguration. Returns false (and puts the
    /// previous input back) if the new camera can't be used.
    @discardableResult
    private func attach(_ device: AVCaptureDevice) -> Bool {
        guard let input = try? AVCaptureDeviceInput(device: device) else { return false }
        let previous = session.inputs
        previous.forEach { session.removeInput($0) }
        guard session.canAddInput(input) else {
            previous.forEach { if session.canAddInput($0) { session.addInput($0) } }
            return false
        }
        session.addInput(input)
        useSmallFormat(device)
        // Keep analysed frames un-mirrored; mirroring is applied in the coordinate math.
        if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        return true
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
        let brightness = latencyProbeEnabled ? Self.brightness(of: buffer) : nil

        let bodies = people.map(Self.body(from:))
        let next = PoseFrame(
            poppers: bodies.flatMap(Self.poppers(from:)),
            bodies: bodies,
            peopleCount: people.count,
            tooClose: bodies.contains(where: Self.isTooClose),
            hands: hands,
            imageSize: size,
            timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds,
            receivedAt: uptime(),
            brightness: brightness
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

    /// Average brightness of the middle 60% of a BGRA frame, sampled on a coarse grid.
    private static func brightness(of buffer: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var total = 0.0, count = 0.0
        for gy in 0..<18 {
            let y = Int(Double(h) * (0.2 + 0.6 * Double(gy) / 17))
            for gx in 0..<32 {
                let x = Int(Double(w) * (0.2 + 0.6 * Double(gx) / 31))
                let p = base + min(y, h - 1) * rowBytes + min(x, w - 1) * 4
                total += 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
                count += 1
            }
        }
        return total / count / 255
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

    static func poppers(from body: Body) -> [Popper] {
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
