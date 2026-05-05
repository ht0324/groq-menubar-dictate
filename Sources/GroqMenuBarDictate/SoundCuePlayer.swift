import AppKit
import Foundation

@MainActor
final class SoundCuePlayer {
    private let pingURL = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")
    private var pingSound: NSSound?

    init() {
        pingSound = NSSound(contentsOf: pingURL, byReference: true)
    }

    func playPing() {
        guard shouldPlayAudibleCue() else {
            return
        }

        if let pingSound {
            pingSound.stop()
            pingSound.play()
        } else {
            NSSound.beep()
        }
    }

    func playErrorBeep() {
        guard shouldPlayAudibleCue() else {
            return
        }

        NSSound.beep()
    }

    private func shouldPlayAudibleCue() -> Bool {
        guard let outputDevice = try? SystemAudioDeviceInspector.defaultOutputDeviceInfo() else {
            return true
        }
        return !AudioDeviceRoutingPolicy.shouldAvoidAutomaticActivation(
            name: outputDevice.name,
            uid: outputDevice.uid,
            transportType: outputDevice.transportType
        )
    }
}
