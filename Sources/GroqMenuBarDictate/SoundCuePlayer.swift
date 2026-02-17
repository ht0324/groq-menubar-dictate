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
        if let pingSound {
            pingSound.stop()
            pingSound.play()
        } else {
            NSSound.beep()
        }
    }

    func playErrorBeep() {
        NSSound.beep()
    }
}
