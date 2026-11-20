import Foundation

/// One thing a script asked for, recorded on the script thread and applied on the main thread.
enum RenderCommand {
    case create(id: Int, kind: String, props: [String: Any])
    case update(id: Int, props: [String: Any])
    case effect(id: Int, name: String, props: [String: Any])
    case remove(id: Int)
    case say(String)
    case sound(String)
    case confetti
    case log(String)
}

/// A `ScriptRenderer` that just records commands (thread-safe). Node ids are handed out here, so
/// scripts get them immediately even though the nodes are created later on the main thread.
final class RecordingRenderer: ScriptRenderer {
    private let lock = NSLock()
    private var commands: [RenderCommand] = []
    private var nextID = 1
    private var size: CGSize

    init(screenSize: CGSize) { size = screenSize }

    var screenSize: CGSize {
        lock.lock(); defer { lock.unlock() }
        return size
    }

    func setScreenSize(_ newSize: CGSize) {
        lock.lock(); size = newSize; lock.unlock()
    }

    /// Takes everything recorded so far.
    func drain() -> [RenderCommand] {
        lock.lock(); defer { lock.unlock() }
        let taken = commands
        commands.removeAll(keepingCapacity: true)
        return taken
    }

    private func record(_ command: RenderCommand) {
        lock.lock(); commands.append(command); lock.unlock()
    }

    func createNode(kind: String, props: [String: Any]) -> Int {
        lock.lock()
        let id = nextID
        nextID += 1
        commands.append(.create(id: id, kind: kind, props: props))
        lock.unlock()
        return id
    }
    func updateNode(_ id: Int, props: [String: Any]) { record(.update(id: id, props: props)) }
    func nodeEffect(_ id: Int, effect: String, props: [String: Any]) { record(.effect(id: id, name: effect, props: props)) }
    func removeNode(_ id: Int) { record(.remove(id: id)) }
    func say(_ text: String) { record(.say(text)) }
    func playSound(_ name: String) { record(.sound(name)) }
    func confetti() { record(.confetti) }
    func log(_ message: String) { record(.log(message)) }
}

/// Runs a pack's script on its own thread so a slow or stuck script can never freeze the app:
/// the main thread only ever waits a few milliseconds for a frame. Every call gets a time budget,
/// after which JavaScriptCore terminates the script (when supported); a watchdog also marks the
/// game as hung if a call doesn't return in time, so the platform can show a message and let the
/// player leave with Esc.
final class ScriptRunner {
    /// Longest a single `onTick` / `onPause` / `onResume` may run.
    var callBudget: Double = 0.25
    /// Longest loading the script plus `onStart` may run.
    var startBudget: Double = 2.0
    /// A call still running this much past its budget counts as hung (e.g. termination unsupported).
    var hangGrace: Double = 0.75

    let recorder: RecordingRenderer
    private let queue = DispatchQueue(label: "jigglejam.pack-script", qos: .userInteractive)
    private let lock = NSLock()
    private var host: ScriptHost?           // used only on `queue`
    private var busySince: Double?
    private var busyBudget: Double = 0
    private var error: String?
    private var stopped = false
    private let idle = DispatchGroup()

    init(screenSize: CGSize) {
        recorder = RecordingRenderer(screenSize: screenSize)
    }

    /// The script's error, or a "stopped responding" message once a call has overrun.
    var failure: String? {
        lock.lock(); defer { lock.unlock() }
        if let error { return error }
        if let since = busySince, uptime() - since > busyBudget + hangGrace {
            return "This game stopped responding (it may have an endless loop)."
        }
        return nil
    }

    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return busySince != nil
    }

    /// Loads the script and calls `onStart`, on the script thread.
    func start(script: String, name: String) {
        submit(budget: startBudget) { [recorder] host in
            let host = host ?? ScriptHost(renderer: recorder)
            host.setTimeLimit(self.startBudget)
            host.load(script: script, name: name)
            host.call("onStart")
            host.setTimeLimit(self.callBudget)
            return host
        }
    }

    /// Sends one frame. Returns false (and does nothing) if the previous call hasn't finished,
    /// so the caller can carry `dt` over to the next frame.
    @discardableResult
    func tick(dt: Double, input: [String: Any]) -> Bool {
        guard !isBusy else { return false }
        submit(budget: callBudget) { host in
            host?.tick(dt: dt, input: input)
            return host
        }
        return true
    }

    func call(_ function: String) {
        submit(budget: callBudget) { host in
            host?.call(function)
            return host
        }
    }

    /// Waits up to `timeout` for the script thread to finish its current call.
    @discardableResult
    func waitUntilIdle(timeout: Double) -> Bool {
        idle.wait(timeout: .now() + timeout) == .success
    }

    /// Stops sending work. A call already running finishes (or is terminated) on its own.
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private func submit(budget: Double, _ work: @escaping (ScriptHost?) -> ScriptHost?) {
        lock.lock()
        guard !stopped, error == nil, busySince == nil else { lock.unlock(); return }
        busySince = uptime()
        busyBudget = budget
        lock.unlock()

        idle.enter()
        queue.async { [weak self] in
            guard let self else { return }
            let host = work(self.host)
            self.host = host
            self.lock.lock()
            if let message = host?.lastError, self.error == nil {
                self.error = message.contains("execution terminated")
                    ? "This game took too long and was stopped (it may have an endless loop)."
                    : message
            }
            self.busySince = nil
            self.lock.unlock()
            self.idle.leave()
        }
    }
}
