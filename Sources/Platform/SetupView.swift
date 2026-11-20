import SwiftUI
import AVFoundation

/// One thing the setup screen waits for, e.g. "Hands" or "Feet".
struct SetupCheck {
    let label: String
    /// Spoken if this is what's still missing after a few seconds.
    let hint: String
    let test: (PoseFrame) -> Bool
}

/// Named setup checks. Built-in games and game packs (manifest `setup.checks`) pick from these.
/// Raw values must match `GamePack.knownSetupChecks`.
enum SetupRequirement: String, CaseIterable {
    case seen, hands, feet, knees, wholeBody, bothHands, wheelLevel

    var check: SetupCheck {
        switch self {
        case .seen:
            return SetupCheck(label: "I see you", hint: "Come and stand in front of the camera!") { !$0.bodies.isEmpty }
        case .hands:
            return SetupCheck(label: "Hands", hint: "Hold your hands up high!") { f in
                f.bodies.contains { $0[.leftWrist] != nil && $0[.rightWrist] != nil }
            }
        case .feet:
            return SetupCheck(label: "Feet", hint: "Step back so I can see your feet!") { f in
                f.bodies.contains { $0[.leftAnkle] != nil && $0[.rightAnkle] != nil }
            }
        case .knees:
            return SetupCheck(label: "Knees", hint: "Step back so I can see your knees!") { f in
                f.bodies.contains { $0[.leftKnee] != nil && $0[.rightKnee] != nil }
            }
        case .wholeBody:
            return SetupCheck(label: "Head to toe", hint: "Step back so I can see you from head to toe!") { f in
                f.bodies.contains { ($0[.nose] != nil || $0[.neck] != nil) && ($0[.leftAnkle] != nil || $0[.rightAnkle] != nil) }
            }
        case .bothHands:
            return SetupCheck(label: "Both hands", hint: "Hold the plate with both hands!") { $0.hands.count >= 2 }
        case .wheelLevel:
            return SetupCheck(label: "Wheel flat", hint: "Hold your wheel nice and flat!") { f in
                guard f.hands.count >= 2 else { return false }
                let dx = abs(f.hands[1].x - f.hands[0].x) * f.imageSize.width
                let dy = (f.hands[1].y - f.hands[0].y) * f.imageSize.height
                return abs(atan2(dy, dx)) < 10 * .pi / 180
            }
        }
    }
}

extension GameEntry {
    func setupChecks(warnTooClose: Bool) -> [SetupCheck] {
        var checks = setupRequirements.map(\.check)
        if needsFullBody && warnTooClose {
            checks.append(SetupCheck(label: "Not too close", hint: "Take a big step back!") { !$0.tooClose })
        }
        if checks.isEmpty { checks = [SetupRequirement.seen.check] }
        return checks
    }
}

/// A short, friendly setup before each game: a big mirrored view of the player with what the
/// camera sees drawn on top, one spoken instruction and a checklist. "Ready!" once everything has
/// been ✅ for a second, or after 10 seconds regardless, so setup can never block play.
struct SetupView: View {
    @ObservedObject var camera: CameraManager
    let game: GameEntry
    let warnTooClose: Bool
    let onReady: () -> Void

    private let timeout: Double = 10
    private let holdTime: Double = 1

    @State private var passed: [Bool] = []
    @State private var allPassedSince: Double?
    @State private var startedAt = uptime()
    @State private var elapsed: Double = 0
    @State private var hinted = false
    @State private var finished: String?
    @State private var speech = AVSpeechSynthesizer()

    private var checks: [SetupCheck] { game.setupChecks(warnTooClose: warnTooClose) }

    var body: some View {
        ZStack {
            CameraBackground(session: camera.session).ignoresSafeArea()
            TrackingOverlay(camera: camera, dotScale: 2.2).ignoresSafeArea()
            // Scrims keep text readable over any room.
            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                panel
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)

            if let finished {
                readyBurst(finished)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: finished)
        .animation(.spring(response: 0.35, dampingFraction: 0.65), value: passed)
        .onAppear {
            startedAt = uptime()
            say(game.setupInstruction)
        }
        .onReceive(Timer.publish(every: 1.0 / 15, on: .main, in: .common).autoconnect()) { _ in evaluate() }
    }

    // Leaves room on the left for the game screen's close button.
    private var topBar: some View {
        HStack(spacing: 14) {
            Spacer().frame(width: 60)
            Spacer()
            HStack(spacing: 10) {
                Text(game.emoji).font(.system(size: 28))
                Text(game.title).font(.system(size: 24, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Capsule().fill(game.color.gradient).shadow(color: game.color.opacity(0.5), radius: 16, y: 6))
            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
            Spacer()
            countdown
        }
    }

    private var countdown: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0, 1 - elapsed / timeout))
                    .stroke(game.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1.0 / 15), value: elapsed)
                Text("\(max(0, Int((timeout - elapsed).rounded(.up))))")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 44, height: 44)
            Button { finish("Let's go! 🎉") } label: {
                HStack(spacing: 6) {
                    Text("Start now")
                    Image(systemName: "return")
                }
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glass(Capsule())
            }
            .buttonStyle(PressableStyle())
            .keyboardShortcut(.defaultAction)
            .help("Skip setup (Return)")
        }
        .foregroundStyle(.white)
    }

    private var panel: some View {
        VStack(spacing: 22) {
            Text(game.setupInstruction)
                .font(.system(size: 46, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            HStack(spacing: 14) {
                ForEach(Array(checks.enumerated()), id: \.offset) { index, check in
                    checkChip(check.label, ok: index < passed.count && passed[index])
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 30)
        .frame(maxWidth: 1100)
        .glass(RoundedRectangle(cornerRadius: 36, style: .continuous))
    }

    private func checkChip(_ label: String, ok: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(ok ? Color.green : .white.opacity(0.55))
                .contentTransition(.symbolEffect(.replace))
            Text(label)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(ok ? 1 : 0.8))
        }
        .padding(.leading, 14)
        .padding(.trailing, 20)
        .padding(.vertical, 12)
        .background(Capsule().fill(ok ? Color.green.opacity(0.26) : .white.opacity(0.08)))
        .overlay(Capsule().strokeBorder(ok ? Color.green.opacity(0.75) : .white.opacity(0.16), lineWidth: 1.5))
        .scaleEffect(ok ? 1.04 : 1)
    }

    private func readyBurst(_ text: String) -> some View {
        ZStack {
            Circle()
                .fill(game.color)
                .frame(width: 520, height: 520)
                .blur(radius: 120)
                .opacity(0.55)
            Text(text)
                .font(.system(size: 120, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: game.color, radius: 30)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
        .allowsHitTesting(false)
    }

    private func evaluate() {
        guard finished == nil else { return }
        if Snapshot.isActive {
            // Snapshot: show a mid-setup state (first checks done) without a camera.
            passed = checks.indices.map { $0 < checks.count / 2 + 1 }
            elapsed = timeout * 0.35
            return
        }
        let now = uptime()
        elapsed = now - startedAt
        let frame = camera.latestFrame
        let fresh = frame.isFresh(at: now)
        let results = checks.map { fresh && $0.test(frame) }
        if results != passed { passed = results }

        if !results.isEmpty, results.allSatisfy({ $0 }) {
            let since = allPassedSince ?? now
            allPassedSince = since
            if now - since >= holdTime { finish("Ready! 🎉") }
        } else {
            allPassedSince = nil
            // Halfway through, say the one thing that's still missing.
            if !hinted, elapsed > timeout / 2, let missing = checks.indices.first(where: { !results[$0] }) {
                hinted = true
                say(checks[missing].hint)
            }
        }
        if elapsed >= timeout { finish("Let's go! 🎉") }
    }

    private func finish(_ text: String) {
        guard finished == nil else { return }
        finished = text
        say(text.hasPrefix("Ready") ? "Ready!" : "Let's go!")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { onReady() }
    }

    private func say(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.45
        utterance.pitchMultiplier = 1.25
        speech.stopSpeaking(at: .word)
        speech.speak(utterance)
    }
}
