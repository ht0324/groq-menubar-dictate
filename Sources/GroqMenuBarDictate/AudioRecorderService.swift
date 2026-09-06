import AVFoundation
import CoreAudio
import Foundation

enum AudioRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case failedToStart
    case builtInMicrophoneUnavailable
    case failedToSelectBuiltInMicrophone
    case cableCreationInputUnavailable
    case failedToSelectCableCreationInput

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recording is already in progress."
        case .notRecording:
            return "No active recording was found."
        case .failedToStart:
            return "Failed to start recording."
        case .builtInMicrophoneUnavailable:
            return "Built-in microphone not available on this Mac."
        case .failedToSelectBuiltInMicrophone:
            return "Failed to switch to the built-in microphone."
        case .cableCreationInputUnavailable:
            return "\(AppConfig.tingInputDeviceName) input not available."
        case .failedToSelectCableCreationInput:
            return "Failed to switch to the \(AppConfig.tingInputDeviceName) input."
        }
    }
}

struct RecordedClip {
    let fileURL: URL
    let recorderReportedDurationSeconds: TimeInterval
}

final class AudioRecorderService {
    private var recorder: AVAudioRecorder?
    private var inputDeviceOverride: InputDeviceOverride?

    deinit {
        restoreInputOverrideIfNeeded()
    }

    /// Warms AVFoundation and CoreAudio device discovery without opening an
    /// audio stream or requesting microphone access.
    static func prewarmBuiltInMicrophone() {
        _ = try? SystemAudioInputSelector.builtInMicrophoneInputDeviceID()
    }

    func startRecording(mode: MicrophoneInputMode = .automatic) throws -> RecordingStartTiming {
        guard recorder == nil else {
            throw AudioRecorderError.alreadyRecording
        }

        var timing = RecordingStartTiming()
        let inputOverride = try RecordingStartTiming.measure(&timing.deviceSelectionMilliseconds) {
            try selectInput(mode: mode)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        for sampleRate in [16_000.0, 22_050.0, 44_100.0] {
            timing.profileAttempts += 1
            do {
                let recorder = try RecordingStartTiming.measure(&timing.recorderCreationMilliseconds) {
                    try AVAudioRecorder(url: outputURL, settings: makeSettings(sampleRate: sampleRate))
                }
                let prepared = RecordingStartTiming.measure(&timing.preparationMilliseconds) {
                    recorder.prepareToRecord()
                }
                guard prepared else { continue }
                let started = RecordingStartTiming.measure(&timing.recordMilliseconds) {
                    recorder.record()
                }
                if started {
                    self.recorder = recorder
                    inputDeviceOverride = inputOverride
                    timing.sampleRate = recorder.format.sampleRate
                    return timing
                }
            } catch {
                continue
            }
        }

        try? inputOverride.restore()
        try? FileManager.default.removeItem(at: outputURL)
        throw AudioRecorderError.failedToStart
    }

    private func selectInput(mode: MicrophoneInputMode) throws -> InputDeviceOverride {
        switch mode {
        case .automatic:
            return .none
        case .macBookInternal:
            do {
                return try InputDeviceOverride.installBuiltInMicrophoneAsDefaultInput()
            } catch AudioRecorderError.builtInMicrophoneUnavailable {
                throw AudioRecorderError.builtInMicrophoneUnavailable
            } catch {
                throw AudioRecorderError.failedToSelectBuiltInMicrophone
            }
        case .cableCreation:
            do {
                return try InputDeviceOverride.installCableCreationAsDefaultInput()
            } catch AudioRecorderError.cableCreationInputUnavailable {
                throw AudioRecorderError.cableCreationInputUnavailable
            } catch {
                throw AudioRecorderError.failedToSelectCableCreationInput
            }
        }
    }

    func stopRecording() throws -> RecordedClip {
        guard let recorder else {
            throw AudioRecorderError.notRecording
        }
        let recorderReportedDurationSeconds = max(0, recorder.currentTime)
        let fileURL = recorder.url
        recorder.stop()
        self.recorder = nil
        restoreInputOverrideIfNeeded()
        return RecordedClip(
            fileURL: fileURL,
            recorderReportedDurationSeconds: recorderReportedDurationSeconds
        )
    }

    private func restoreInputOverrideIfNeeded() {
        guard let inputDeviceOverride else {
            return
        }
        try? inputDeviceOverride.restore()
        self.inputDeviceOverride = nil
    }

    private func makeSettings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
    }

    /// Reads the encoded clip's duration without touching recorder state, so it
    /// is safe to call off the main actor (e.g. from a detached task).
    static func fileDuration(at fileURL: URL) -> TimeInterval? {
        guard let player = try? AVAudioPlayer(contentsOf: fileURL) else {
            return nil
        }
        let durationSeconds = player.duration
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return nil
        }
        return durationSeconds
    }
}

private struct InputDeviceOverride {
    static let none = InputDeviceOverride(previousInputDeviceID: nil)

    let previousInputDeviceID: AudioDeviceID?

    static func installBuiltInMicrophoneAsDefaultInput() throws -> InputDeviceOverride {
        let previousInputDeviceID = try SystemAudioDeviceInspector.defaultInputDeviceID()
        guard let builtInMicrophoneID = try SystemAudioInputSelector.builtInMicrophoneInputDeviceID() else {
            throw AudioRecorderError.builtInMicrophoneUnavailable
        }
        return try installDefaultInputDevice(builtInMicrophoneID, previousInputDeviceID: previousInputDeviceID)
    }

    static func installCableCreationAsDefaultInput() throws -> InputDeviceOverride {
        let previousInputDeviceID = try SystemAudioDeviceInspector.defaultInputDeviceID()
        guard let cableCreation = SystemAudioDeviceInspector.firstInputDevice(
            matchingName: AppConfig.tingInputDeviceName
        ) else {
            throw AudioRecorderError.cableCreationInputUnavailable
        }
        return try installDefaultInputDevice(cableCreation.id, previousInputDeviceID: previousInputDeviceID)
    }

    private static func installDefaultInputDevice(
        _ inputDeviceID: AudioDeviceID,
        previousInputDeviceID: AudioDeviceID
    ) throws -> InputDeviceOverride {
        guard inputDeviceID != previousInputDeviceID else {
            return .none
        }
        let restorePrevious = SystemAudioInputSelector.shouldRestoreInputDeviceAfterRecording(previousInputDeviceID)
        try SystemAudioDeviceInspector.setDefaultInputDeviceID(inputDeviceID)
        return InputDeviceOverride(previousInputDeviceID: restorePrevious ? previousInputDeviceID : nil)
    }

    func restore() throws {
        if let previousInputDeviceID {
            try SystemAudioDeviceInspector.setDefaultInputDeviceID(previousInputDeviceID)
        }
    }
}

private enum SystemAudioInputSelector {
    private static let builtInMicrophoneCache = AudioInputDeviceCache()

    static func shouldRestoreInputDeviceAfterRecording(_ deviceID: AudioDeviceID) -> Bool {
        guard let deviceInfo = try? SystemAudioDeviceInspector.deviceInfo(for: deviceID) else {
            return true
        }
        return !AudioDeviceRoutingPolicy.shouldAvoidAutomaticActivation(
            name: deviceInfo.name,
            uid: deviceInfo.uid,
            transportType: deviceInfo.transportType
        )
    }

    static func builtInMicrophoneInputDeviceID() throws -> AudioDeviceID? {
        try builtInMicrophoneCache.resolve(discover: discoverBuiltInMicrophone) { device in
            guard let uid = device.uid,
                  (try? SystemAudioDeviceInspector.deviceUID(for: device.id)) == uid
            else {
                return false
            }
            return SystemAudioDeviceInspector.hasInputStreams(device.id)
        }
    }

    private static func discoverBuiltInMicrophone() throws -> AudioDeviceInfo? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone],
            mediaType: .audio,
            position: .unspecified
        ).devices

        guard let builtInMic = devices.first(where: {
            $0.localizedName.localizedCaseInsensitiveContains("macbook")
        }) ?? devices.first else {
            return nil
        }

        for deviceID in try SystemAudioDeviceInspector.allAudioDeviceIDs() {
            if (try? SystemAudioDeviceInspector.deviceUID(for: deviceID)) == builtInMic.uniqueID {
                return AudioDeviceInfo(id: deviceID, name: builtInMic.localizedName, uid: builtInMic.uniqueID, transportType: nil)
            }
        }
        return nil
    }
}
