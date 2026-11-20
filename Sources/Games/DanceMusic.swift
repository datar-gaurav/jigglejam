import AVFoundation

/// A tiny built-in chiptune band (melody, bass, kick, hi-hat), so no music files are needed.
/// Each song is rendered once into a looping buffer up front, and playback goes through
/// `AVAudioPlayerNode`, so the game never shares mutable state with the audio render thread.
/// `stop()` pauses mid-song (the "FREEZE!" cue) and `play()` carries on from there.
final class DanceMusic {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var songs: [AVAudioPCMBuffer] = []
    private var currentSong = -1

    // MIDI notes per eighth note (0 = rest). Bright, bouncy, C-major pentatonic.
    private static let melodies: [[Int]] = [
        [72, 0, 76, 79, 76, 0, 72, 74,  76, 0, 79, 81, 79, 76, 74, 0],
        [79, 79, 76, 0, 79, 79, 76, 0,  74, 76, 79, 76, 74, 72, 74, 0],
        [72, 74, 76, 72, 79, 0, 76, 0,  81, 79, 76, 74, 72, 0, 72, 0],
    ]
    private static let bass: [Int] = [48, 48, 55, 55, 57, 57, 53, 55] // per quarter note, 2 bars
    private static let bpm = 126.0

    init() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = rate > 0 ? rate : 44_100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        songs = Self.melodies.compactMap { Self.render(melody: $0, format: format) }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = Snapshot.isActive ? 0 : 0.6
        try? engine.start()
    }

    func play(newSong: Bool = false) {
        guard !songs.isEmpty else { return }
        if !engine.isRunning { try? engine.start() }
        if newSong || currentSong < 0 {
            let next = currentSong < 0 ? 0 : Int.random(in: 0..<songs.count)
            if next != currentSong || currentSong < 0 {
                currentSong = next
                player.stop() // clears the old schedule
                player.scheduleBuffer(songs[next], at: nil, options: .loops)
            }
        }
        player.play()
    }

    func stop() { player.pause() }

    func shutdown() {
        player.stop()
        engine.stop()
    }

    // MARK: - Offline synthesis

    private static func freq(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

    /// One seamless loop: 16 eighth notes of melody over 8 quarter notes of bass.
    private static func render(melody: [Int], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let eighth = 60 / bpm / 2
        let frames = AVAudioFrameCount((Double(melody.count) * eighth * sampleRate).rounded())
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let out = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames

        var noise: UInt32 = 22222
        let twoPi = 2 * Double.pi
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            let step = Int(t / eighth)
            let inStep = t - Double(step) * eighth
            var sample = 0.0

            // Melody: soft square wave with a plucky decay.
            let note = melody[step % melody.count]
            if note > 0 {
                let phase = (t * freq(note)).truncatingRemainder(dividingBy: 1)
                sample += (phase < 0.5 ? 1 : -1) * 0.09 * exp(-inStep * 7)
            }

            // Bass: triangle wave on every quarter note.
            let quarter = step / 2
            let inQuarter = t - Double(quarter) * eighth * 2
            let bp = (t * freq(bass[quarter % bass.count])).truncatingRemainder(dividingBy: 1)
            sample += (4 * abs(bp - 0.5) - 1) * 0.16 * exp(-inQuarter * 3)

            // Kick on every beat: a falling sine "boom".
            sample += sin(twoPi * (55 * inQuarter + 120 * (1 - exp(-inQuarter * 30)) / 30)) * 0.35 * exp(-inQuarter * 14)

            // Hi-hat on the off-beats: a short burst of noise.
            if step % 2 == 1 {
                noise = noise &* 1_664_525 &+ 1_013_904_223
                sample += (Double(noise) / Double(UInt32.max) * 2 - 1) * 0.06 * exp(-inStep * 60)
            }
            out[i] = Float(sample)
        }
        return buffer
    }
}
