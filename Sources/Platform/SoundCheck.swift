import AVFoundation
import AppKit
import Combine
import CoreAudio

/// The menu's 🔊 sound test: speaks a line, plays a pop, and reports which device the sound went
/// to (screen mirroring often moves sound to the TV, which can be muted).
final class SoundCheck: ObservableObject {
    /// e.g. "Living Room TV" while the test message is showing.
    @Published private(set) var playingOn: String?

    private let speech = AVSpeechSynthesizer()
    private var pop: NSSound?
    private var hideWork: DispatchWorkItem?

    func run() {
        guard !Snapshot.isActive else { return }
        let utterance = AVSpeechUtterance(string: "Hello! Can you hear me?")
        utterance.rate = 0.45
        utterance.pitchMultiplier = 1.25
        speech.stopSpeaking(at: .immediate)
        speech.speak(utterance)
        pop = NSSound(named: "Pop")?.copy() as? NSSound
        pop?.play()

        playingOn = Self.defaultOutputName() ?? "the default speaker"
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.playingOn = nil }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Name of the device macOS sends app audio to (System Settings → Sound → Output).
    static func defaultOutputName() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return nil }

        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }
}
