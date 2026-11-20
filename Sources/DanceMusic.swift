import AVFoundation

/// A tiny built-in chiptune band (melody, bass, kick, hi-hat), so no music files are needed.
/// `play()` / `stop()` fade in and out quickly; stopping is the "FREEZE!" cue.
final class DanceMusic {
    private final class State {
        var playing = false
        var gain: Float = 0
        var time: Double = 0
        var song = 0
        var noise: UInt32 = 22222
    }

    private let engine = AVAudioEngine()
    private let state = State()
    private var source: AVAudioSourceNode?

    // MIDI notes per eighth note (0 = rest). Bright, bouncy, C-major pentatonic.
    private static let melodies: [[Int]] = [
        [72, 0, 76, 79, 76, 0, 72, 74,  76, 0, 79, 81, 79, 76, 74, 0],
        [79, 79, 76, 0, 79, 79, 76, 0,  74, 76, 79, 76, 74, 72, 74, 0],
        [72, 74, 76, 72, 79, 0, 76, 0,  81, 79, 76, 74, 72, 0, 72, 0],
    ]
    private static let bass: [Int] = [48, 48, 55, 55, 57, 57, 53, 55] // per quarter note, 2 bars
    private static let bpm = 126.0

    init() {
        let rate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        let sampleRate = rate > 0 ? rate : 44_100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let state = self.state
        let dt = 1.0 / sampleRate

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let target: Float = state.playing ? 1 : 0
                state.gain += (target - state.gain) * 0.004
                var sample: Float = 0
                if state.gain > 0.0005 {
                    sample = DanceMusic.render(state) * state.gain
                    state.time += dt
                }
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.6
        try? engine.start()
    }

    func play(newSong: Bool = false) {
        if newSong { state.song = Int.random(in: 0..<Self.melodies.count) }
        if !engine.isRunning { try? engine.start() }
        state.playing = true
    }

    func stop() { state.playing = false }

    func shutdown() {
        state.playing = false
        engine.stop()
    }

    private static func freq(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

    private static func render(_ s: State) -> Float {
        let eighth = 60 / bpm / 2
        let step = Int(s.time / eighth)
        let inStep = s.time - Double(step) * eighth
        let twoPi = 2 * Double.pi
        var out = 0.0

        // Melody: soft square wave with a plucky decay.
        let melody = melodies[s.song]
        let note = melody[step % melody.count]
        if note > 0 {
            let phase = (s.time * freq(note)).truncatingRemainder(dividingBy: 1)
            out += (phase < 0.5 ? 1 : -1) * 0.09 * exp(-inStep * 7)
        }

        // Bass: triangle wave on every quarter note.
        let quarter = step / 2
        let inQuarter = s.time - Double(quarter) * eighth * 2
        let bassNote = bass[quarter % bass.count]
        let bp = (s.time * freq(bassNote)).truncatingRemainder(dividingBy: 1)
        out += (4 * abs(bp - 0.5) - 1) * 0.16 * exp(-inQuarter * 3)

        // Kick on every beat: a falling sine "boom".
        out += sin(twoPi * (55 * inQuarter + 120 * (1 - exp(-inQuarter * 30)) / 30)) * 0.35 * exp(-inQuarter * 14)

        // Hi-hat on the off-beats: a short burst of noise.
        if step % 2 == 1 {
            s.noise = s.noise &* 1_664_525 &+ 1_013_904_223
            let n = Double(s.noise) / Double(UInt32.max) * 2 - 1
            out += n * 0.06 * exp(-inStep * 60)
        }
        return Float(out)
    }
}
