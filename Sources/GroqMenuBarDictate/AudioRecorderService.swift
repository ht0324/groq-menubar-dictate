import AVFoundation
import CoreAudio
import Foundation

enum AudioRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case failedToStart
    case builtInMicrophoneUnavailable
    case failedToSelectBuiltInMicrophone

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
        }
    }
}

struct RecordedClip {
    let fileURL: URL
    let fileMeasuredDurationSeconds: TimeInterval?
    let recorderReportedDurationSeconds: TimeInterval
}

final class AudioRecorderService: NSObject {
    private var recorder: AVAudioRecorder?
    private var inputDeviceOverride: InputDeviceOverride?

    var isRecording: Bool {
        recorder?.isRecording ?? false
    }

    deinit {
        restoreInputOverrideIfNeeded()
    }

    func startRecording(mode: MicrophoneInputMode = .automatic) throws {
        guard recorder == nil else {
            throw AudioRecorderError.alreadyRecording
        }

        let inputOverride: InputDeviceOverride
        switch mode {
        case .automatic:
            inputOverride = .none
        case .macBookInternal:
            do {
                inputOverride = try InputDeviceOverride.installBuiltInMicrophoneAsDefaultInput()
            } catch AudioRecorderError.builtInMicrophoneUnavailable {
                throw AudioRecorderError.builtInMicrophoneUnavailable
            } catch {
                throw AudioRecorderError.failedToSelectBuiltInMicrophone
            }
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        for profile in recordingProfiles {
            do {
                let recorder = try AVAudioRecorder(url: outputURL, settings: profile)
                recorder.prepareToRecord()
                if recorder.record() {
                    self.recorder = recorder
                    inputDeviceOverride = inputOverride
                    return
                }
            } catch {
                continue
            }
        }

        try? inputOverride.restore()
        throw AudioRecorderError.failedToStart
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
        let fileMeasuredDurationSeconds = recordedFileDuration(for: fileURL)
        return RecordedClip(
            fileURL: fileURL,
            fileMeasuredDurationSeconds: fileMeasuredDurationSeconds,
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

    private var recordingProfiles: [[String: Any]] {
        [
            makeSettings(sampleRate: 16_000),
            makeSettings(sampleRate: 22_050),
            makeSettings(sampleRate: 44_100),
        ]
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

    private func recordedFileDuration(for fileURL: URL) -> TimeInterval? {
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
    static let none = InputDeviceOverride(
        previousInputDeviceID: AudioDeviceID(bitPattern: 0),
        changedDefaultInputDevice: false,
        shouldRestorePreviousInputDevice: true
    )

    let previousInputDeviceID: AudioDeviceID
    let changedDefaultInputDevice: Bool
    let shouldRestorePreviousInputDevice: Bool

    static func installBuiltInMicrophoneAsDefaultInput() throws -> InputDeviceOverride {
        let previousInputDeviceID = try SystemAudioInputSelector.defaultInputDeviceID()
        guard let builtInMicrophoneID = try SystemAudioInputSelector.builtInMicrophoneInputDeviceID() else {
            throw AudioRecorderError.builtInMicrophoneUnavailable
        }
        let shouldRestorePreviousInputDevice = SystemAudioInputSelector
            .shouldRestoreInputDeviceAfterRecording(previousInputDeviceID)

        guard builtInMicrophoneID != previousInputDeviceID else {
            return InputDeviceOverride(
                previousInputDeviceID: previousInputDeviceID,
                changedDefaultInputDevice: false,
                shouldRestorePreviousInputDevice: shouldRestorePreviousInputDevice
            )
        }

        try SystemAudioInputSelector.setDefaultInputDeviceID(builtInMicrophoneID)
        return InputDeviceOverride(
            previousInputDeviceID: previousInputDeviceID,
            changedDefaultInputDevice: true,
            shouldRestorePreviousInputDevice: shouldRestorePreviousInputDevice
        )
    }

    func restore() throws {
        guard changedDefaultInputDevice, shouldRestorePreviousInputDevice else {
            return
        }
        try SystemAudioInputSelector.setDefaultInputDeviceID(previousInputDeviceID)
    }
}

private enum SystemAudioInputSelector {
    static func defaultInputDeviceID() throws -> AudioDeviceID {
        try SystemAudioDeviceInspector.defaultInputDeviceID()
    }

    static func setDefaultInputDeviceID(_ deviceID: AudioDeviceID) throws {
        try SystemAudioDeviceInspector.setDefaultInputDeviceID(deviceID)
    }

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

        return try deviceID(matchingUID: builtInMic.uniqueID)
    }

    private static func deviceID(matchingUID targetUID: String) throws -> AudioDeviceID? {
        for deviceID in try allAudioDeviceIDs() {
            guard let uid = try SystemAudioDeviceInspector.deviceInfo(for: deviceID).uid else {
                continue
            }
            if uid == targetUID {
                return deviceID
            }
        }
        return nil
    }

    private static func allAudioDeviceIDs() throws -> [AudioDeviceID] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr else {
            throw CoreAudioError.failed(operation: "read audio device list size", status: sizeStatus)
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else {
            return []
        }
        var deviceIDs = Array(repeating: AudioDeviceID(bitPattern: 0), count: count)
        var mutableDataSize = dataSize
        let readStatus = deviceIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                &mutableDataSize,
                buffer.baseAddress!
            )
        }
        guard readStatus == noErr else {
            throw CoreAudioError.failed(operation: "read audio device list", status: readStatus)
        }
        return deviceIDs
    }

}
