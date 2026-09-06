import AppKit
import AVFAudio
import Foundation

protocol SoundCuePlayback: AnyObject {
    func prepareToPlay() -> Bool
    func play() -> Bool
    func stop()
}

extension AVAudioPlayer: SoundCuePlayback {}

/// Owns the audio player off the main actor; hardware preparation can overlap
/// microphone startup without playing the cue before recording succeeds.
private actor PingPlayback {
    private let makePlayer: @Sendable () -> (any SoundCuePlayback)?
    private var player: (any SoundCuePlayback)?

    init(makePlayer: @escaping @Sendable () -> (any SoundCuePlayback)?) {
        self.makePlayer = makePlayer
    }

    func prepare() {
        guard !Task.isCancelled else { return }
        player = makePlayer()
        if player?.prepareToPlay() != true || Task.isCancelled {
            stop()
        }
    }

    func play() -> Bool {
        guard !Task.isCancelled else {
            stop()
            return false
        }
        return player?.play() ?? false
    }

    func stop() {
        player?.stop()
        player = nil
    }
}

@MainActor
final class SoundCuePlayer {
    @MainActor
    private final class PendingPing {
        let playback: PingPlayback
        let preparation: Task<Void, Never>
        var playTask: Task<Void, Never>?

        init(makePlayer: @escaping @Sendable () -> (any SoundCuePlayback)?) {
            let playback = PingPlayback(makePlayer: makePlayer)
            self.playback = playback
            preparation = Task.detached(priority: .userInitiated) { await playback.prepare() }
        }

        func cancel() {
            preparation.cancel()
            playTask?.cancel()
            Task { [playback] in await playback.stop() }
        }
    }

    private let makePlayer: @Sendable () -> (any SoundCuePlayback)?
    private let shouldPlayAudibleCue: @MainActor () -> Bool
    private var pendingPing: PendingPing?

    init(
        makePlayer: @escaping @Sendable () -> (any SoundCuePlayback)? = {
            try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff"))
        },
        shouldPlayAudibleCue: @escaping @MainActor () -> Bool = SoundCuePlayer.outputAllowsCue
    ) {
        self.makePlayer = makePlayer
        self.shouldPlayAudibleCue = shouldPlayAudibleCue
    }

    func preparePing() {
        cancelPing()
        guard shouldPlayAudibleCue() else { return }
        pendingPing = PendingPing(makePlayer: makePlayer)
    }

    /// Schedule feedback without making recording startup wait for audio hardware.
    func playPing() {
        if pendingPing == nil {
            preparePing()
        }
        guard let ping = pendingPing, ping.playTask == nil else { return }
        ping.playTask = Task { [weak self] in
            await ping.preparation.value
            // Output routing may have changed while preparation was running.
            guard !Task.isCancelled, self?.shouldPlayAudibleCue() == true else {
                ping.cancel()
                return
            }
            if !(await ping.playback.play()), !Task.isCancelled, self?.shouldPlayAudibleCue() == true {
                NSSound.beep()
            }
        }
    }

    func cancelPing() {
        pendingPing?.cancel()
        pendingPing = nil
    }

    func playErrorBeep() {
        guard shouldPlayAudibleCue() else { return }
        NSSound.beep()
    }

    private static func outputAllowsCue() -> Bool {
        guard let outputDevice = try? SystemAudioDeviceInspector.defaultOutputDeviceInfo() else { return true }
        return !AudioDeviceRoutingPolicy.shouldAvoidAutomaticActivation(
            name: outputDevice.name,
            uid: outputDevice.uid,
            transportType: outputDevice.transportType
        ) && !SystemAudioDeviceInspector.isOutputMuted(outputDevice.id)
    }
}
