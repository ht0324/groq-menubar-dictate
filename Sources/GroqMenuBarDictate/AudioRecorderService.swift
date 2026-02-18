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

    func stopRecording() throws -> URL {
        guard let recorder else {
            throw AudioRecorderError.notRecording
        }
        recorder.stop()
        self.recorder = nil
        restoreInputOverrideIfNeeded()
        return recorder.url
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
}

private struct InputDeviceOverride {
    static let none = InputDeviceOverride(
        previousInputDeviceID: AudioDeviceID(bitPattern: 0),
        changedDefaultInputDevice: false
    )

    let previousInputDeviceID: AudioDeviceID
    let changedDefaultInputDevice: Bool

    static func installBuiltInMicrophoneAsDefaultInput() throws -> InputDeviceOverride {
        let previousInputDeviceID = try SystemAudioInputSelector.defaultInputDeviceID()
        guard let builtInMicrophoneID = try SystemAudioInputSelector.builtInMicrophoneInputDeviceID() else {
            throw AudioRecorderError.builtInMicrophoneUnavailable
        }

        guard builtInMicrophoneID != previousInputDeviceID else {
            return InputDeviceOverride(
                previousInputDeviceID: previousInputDeviceID,
                changedDefaultInputDevice: false
            )
        }

        try SystemAudioInputSelector.setDefaultInputDeviceID(builtInMicrophoneID)
        return InputDeviceOverride(
            previousInputDeviceID: previousInputDeviceID,
            changedDefaultInputDevice: true
        )
    }

    func restore() throws {
        guard changedDefaultInputDevice else {
            return
        }
        try SystemAudioInputSelector.setDefaultInputDeviceID(previousInputDeviceID)
    }
}

private enum SystemAudioInputSelector {
    static func defaultInputDeviceID() throws -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(bitPattern: 0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr else {
            throw CoreAudioError.failed(operation: "read default input device", status: status)
        }
        return deviceID
    }

    static func setDefaultInputDeviceID(_ deviceID: AudioDeviceID) throws {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )
        guard status == noErr else {
            throw CoreAudioError.failed(operation: "set default input device", status: status)
        }
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
            guard let uid = try deviceUID(for: deviceID) else {
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

    private static func deviceUID(for deviceID: AudioDeviceID) throws -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else {
            return nil
        }

        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let uidStorage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<CFString?>.alignment
        )
        defer {
            uidStorage.deallocate()
        }

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            uidStorage
        )
        guard status == noErr else {
            throw CoreAudioError.failed(operation: "read audio device UID", status: status)
        }
        let uid = uidStorage.load(as: CFString?.self)
        return uid as String?
    }
}

private enum CoreAudioError: Error {
    case failed(operation: String, status: OSStatus)
}
