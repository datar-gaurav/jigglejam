import SwiftUI
import AVFoundation

/// One thing the setup screen waits for, e.g. "Hands" or "Feet".
struct SetupCheck {
    let label: String
    /// Spoken if this is what's still missing after a few seconds.
    let hint: String
    let test: (PoseFrame) -> Bool
}

extension Game {
    /// Spoken and shown when setup starts.
    var setupInstruction: String {
        switch self {
        case .bubblePop: return "Show me your hands and your feet!"
        case .freezeDance: return "Stand back so I can see all of you!"
        case .rocketJump: return "Stand back, feet on the floor, ready to jump!"
        case .driving: return "Hold your plate with both hands, nice and flat!"
        case .foxTrail: return "Stand back so I can see your knees and feet!"
        }
    }

    /// Games that need the whole body get the too-close check (when that warning is on).
    var needsFullBody: Bool { self != .driving }

    func setupChecks(warnTooClose: Bool) -> [SetupCheck] {
        let seen = SetupCheck(label: "I see you", hint: "Come and stand in front of the camera!") { !$0.bodies.isEmpty }
        let hands = SetupCheck(label: "Hands", hint: "Hold your hands up high!") { f in
            f.bodies.contains { $0[.leftWrist] != nil && $0[.rightWrist] != nil }
        }
        let feet = SetupCheck(label: "Feet", hint: "Step back so I can see your feet!") { f in
            f.bodies.contains { $0[.leftAnkle] != nil && $0[.rightAnkle] != nil }
        }
        let knees = SetupCheck(label: "Knees", hint: "Step back so I can see your knees!") { f in
            f.bodies.contains { $0[.leftKnee] != nil && $0[.rightKnee] != nil }
        }
        let wholeBody = SetupCheck(label: "Head to toe", hint: "Step back so I can see you from head to toe!") { f in
            f.bodies.contains { ($0[.nose] != nil || $0[.neck] != nil) && ($0[.leftAnkle] != nil || $0[.rightAnkle] != nil) }
        }
        let notTooClose = SetupCheck(label: "Not too close", hint: "Take a big step back!") { !$0.tooClose }
        let wheelHands = SetupCheck(label: "Both hands", hint: "Hold the plate with both hands!") { $0.hands.count >= 2 }
        let wheelLevel = SetupCheck(label: "Wheel flat", hint: "Hold your wheel nice and flat!") { f in
            guard f.hands.count >= 2 else { return false }
            let dx = abs(f.hands[1].x - f.hands[0].x) * f.imageSize.width
            let dy = (f.hands[1].y - f.hands[0].y) * f.imageSize.height
            return abs(atan2(dy, dx)) < 10 * .pi / 180
        }

        var checks: [SetupCheck]
        switch self {
        case .bubblePop: checks = [seen, hands, feet]
        case .freezeDance: checks = [seen, wholeBody]
        case .rocketJump: checks = [seen, wholeBody, feet]
        case .foxTrail: checks = [seen, knees, feet]
        case .driving: checks = [wheelHands, wheelLevel]
        }
        if needsFullBody && warnTooClose { checks.append(notTooClose) }
        return checks
    }
}

/// A short, friendly setup before each game: a big mirrored view of the player with what the
/// camera sees drawn on top, one spoken instruction and a checklist. "Ready!" once everything has
/// been ✅ for a second, or after 10 seconds regardless, so setup can never block play.
struct SetupView: View {
    @ObservedObject var camera: CameraManager
    let game: Game
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
            CameraPreview(session: camera.session).ignoresSafeArea()
            TrackingOverlay(camera: camera, dotScale: 2.2).ignoresSafeArea()

            VStack {
                Spacer()
                card
            }
            .padding(36)

            if let finished {
                Text(finished)
                    .font(.system(size: 120, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 12)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: finished)
        .animation(.easeOut(duration: 0.2), value: passed)
        .onAppear {
            startedAt = uptime()
            say(game.setupInstruction)
        }
        .onReceive(Timer.publish(every: 1.0 / 15, on: .main, in: .common).autoconnect()) { _ in evaluate() }
    }

    private var card: some View {
        VStack(spacing: 18) {
            Text("\(game.emoji)  \(game.title)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Text(game.setupInstruction)
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            HStack(spacing: 14) {
                ForEach(Array(checks.enumerated()), id: \.offset) { index, check in
                    let ok = index < passed.count && passed[index]
                    Text("\(ok ? "✅" : "⬜️")  \(check.label)")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(ok ? Color.green.opacity(0.55) : Color.white.opacity(0.15)))
                }
            }
            HStack(spacing: 16) {
                ProgressView(value: min(elapsed / timeout, 1))
                    .tint(.white)
                    .frame(width: 260)
                Button("Start now") { finish("Let's go!") }
                    .keyboardShortcut(.defaultAction)
                    .help("Skip setup (Return)")
            }
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 28).fill(.black.opacity(0.55)))
    }

    private func evaluate() {
        guard finished == nil else { return }
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
