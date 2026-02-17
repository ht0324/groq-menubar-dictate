import AVFoundation
import Foundation

enum AudioRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case failedToStart

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recording is already in progress."
        case .notRecording:
            return "No active recording was found."
        case .failedToStart:
            return "Failed to start recording."
        }
    }
}

final class AudioRecorderService: NSObject {
    private var recorder: AVAudioRecorder?

    var isRecording: Bool {
        recorder?.isRecording ?? false
    }

    func startRecording() throws {
        guard recorder == nil else {
            throw AudioRecorderError.alreadyRecording
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
                    return
                }
            } catch {
                continue
            }
        }

        throw AudioRecorderError.failedToStart
    }

    func stopRecording() throws -> URL {
        guard let recorder else {
            throw AudioRecorderError.notRecording
        }
        recorder.stop()
        self.recorder = nil
        return recorder.url
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
