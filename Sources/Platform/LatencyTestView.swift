import SwiftUI
import AppKit

/// Display-to-camera loopback: the app flips the screen black/white, the display (Mac screen,
/// HDMI TV or AirPlay TV) shows it, the camera sees it, and the frame comes out of the tracking
/// pipeline. Good for comparing HDMI and AirPlay. It does NOT include gesture recognition,
/// steering smoothing or the game's next render, so the delay a player feels is somewhat longer;
/// measure that by filming a hand movement and the on-TV response in one slow-motion clip.
final class LatencyProbe: ObservableObject {
    struct Run: Identifiable {
        let id = UUID()
        let label: String
        let median: Double
        let samples: Int
    }

    @Published private(set) var white = false
    @Published private(set) var samples: [Double] = []
    @Published private(set) var seesFlashes = false
    @Published private(set) var runs: [Run] = []

    private let camera: CameraManager
    private var flipTimer: Timer?
    private var pollTimer: Timer?
    private var flipAt: Double = 0
    private var awaiting = false
    private var lastTimestamp: Double = 0
    private var low = 1.0, high = 0.0

    init(camera: CameraManager) { self.camera = camera }

    var median: Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    func start() {
        camera.latencyProbeEnabled = true
        flipTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.flip() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 240, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    func stop() {
        flipTimer?.invalidate()
        pollTimer?.invalidate()
        camera.latencyProbeEnabled = false
    }

    func restart() {
        samples.removeAll()
    }

    func saveRun(label: String) {
        guard let median else { return }
        runs.append(Run(label: label, median: median, samples: samples.count))
        samples.removeAll()
    }

    private func flip() {
        white.toggle()
        flipAt = uptime() // the new color reaches the screen within one display refresh of this
        awaiting = true
    }

    private func poll() {
        let frame = camera.latestFrame
        guard frame.timestamp != lastTimestamp, let b = frame.brightness else { return }
        lastTimestamp = frame.timestamp

        // Track the darkest and brightest levels seen, slowly forgetting old extremes.
        low = min(b, low + 0.002)
        high = max(b, high - 0.002)
        let contrast = high - low
        let sees = contrast > 0.12
        if sees != seesFlashes { seesFlashes = sees }
        guard sees, awaiting else { return }

        let mid = (low + high) / 2
        if (white && b > mid) || (!white && b < mid) {
            awaiting = false
            let delay = frame.receivedAt - flipAt
            if delay > 0, delay < 1.4 {
                samples.append(delay)
                if samples.count > 20 { samples.removeFirst() }
            }
        }
    }
}

struct LatencyTestView: View {
    @ObservedObject var camera: CameraManager
    let onExit: () -> Void
    @StateObject private var probe: LatencyProbe
    @State private var label = ""

    init(camera: CameraManager, onExit: @escaping () -> Void) {
        self.camera = camera
        self.onExit = onExit
        _probe = StateObject(wrappedValue: LatencyProbe(camera: camera))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            (probe.white ? Color.white : Color.black).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text("📏 Display delay test").font(.title.bold())
                Text("Display-to-camera loopback. Point the camera at the screen you play on (the TV) so it fills most of the picture. The screen flashes, and each flash is timed until the camera sees it.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(probe.seesFlashes ? "✅ Camera sees the flashes" : "⏳ Camera can't see the flashes yet")
                    .font(.headline)
                if let median = probe.median {
                    Text(String(format: "Delay: %.0f ms (median of %d)", median * 1000, probe.samples.count))
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                    if let lo = probe.samples.min(), let hi = probe.samples.max() {
                        Text(String(format: "range %.0f–%.0f ms", lo * 1000, hi * 1000)).font(.callout)
                    }
                }
                HStack {
                    TextField("Label, e.g. HDMI or AirPlay", text: $label).frame(width: 220)
                    Button("Save result") {
                        probe.saveRun(label: label.isEmpty ? defaultLabel : label)
                        label = ""
                    }
                    .disabled(probe.samples.count < 5)
                    Button("Reset") { probe.restart() }
                }
                ForEach(probe.runs) { run in
                    Text(String(format: "• %@: %.0f ms (%d flashes)", run.label, run.median * 1000, run.samples))
                }
                Text("Includes drawing, the display, camera capture and pose tracking. It leaves out gesture recognition, smoothing and the game's next frame, so the delay a player feels is a bit longer. Use it to compare HDMI and AirPlay. To measure what the player feels, film a hand movement and the TV's response in one slow-motion clip and count the frames between them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(width: 440, alignment: .leading)
            .foregroundStyle(.primary)
            // Solid (not glass) so the panel doesn't change with the flashing screen behind it.
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .environment(\.colorScheme, .dark)
            .padding(.top, 70)
            .padding(.leading, 24)

            Button(action: onExit) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 40, height: 40)
                    .glass(Circle())
            }
            .buttonStyle(PressableStyle())
            .padding(22)
            .keyboardShortcut(.cancelAction)
            .help("Back to menu (Esc)")
        }
        .onAppear { probe.start() }
        .onDisappear { probe.stop() }
    }

    private var defaultLabel: String {
        NSApp.keyWindow?.screen?.localizedName ?? "Run \(probe.runs.count + 1)"
    }
}
