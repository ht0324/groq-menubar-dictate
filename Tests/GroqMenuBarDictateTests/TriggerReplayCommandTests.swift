import Foundation
import XCTest
@testable import GroqMenuBarDictate

final class TriggerReplayCommandTests: XCTestCase {
    private let sampleRate = 16_000

    func testReadPCM16MonoWAVRoundTripsEncoderOutput() throws {
        let samples = Data([0x01, 0x00, 0xFF, 0x7F, 0x00, 0x80, 0x34, 0x12])
        let url = try writeWAV(PCM16WAVEncoder.wavData(pcm16: samples, sampleRate: 16_000))

        let decoded = try TriggerReplayCommand.readPCM16MonoWAV(at: url)

        XCTAssertEqual(decoded, samples)
    }

    func testReadPCM16MonoWAVToleratesUnpatchedHeaderSizes() throws {
        let samples = Data([0x10, 0x00, 0x20, 0x00, 0x30, 0x00])
        var wav = PCM16WAVEncoder.wavData(pcm16: samples, sampleRate: 16_000)
        writeUInt32(0, to: &wav, at: 4)
        writeUInt32(0, to: &wav, at: 40)
        let url = try writeWAV(wav)

        let decoded = try TriggerReplayCommand.readPCM16MonoWAV(at: url)

        XCTAssertEqual(decoded, samples)
    }

    func testTriggerConfigurationReadsInstalledAppDomain() {
        let suiteName = "TriggerReplayCommandTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(-64.5, forKey: "settings.audioTriggerStartThresholdDBFS")
        defaults.set(-77.0, forKey: "settings.audioTriggerStopThresholdDBFS")
        var requestedDomains: [String] = []

        let configuration = TriggerReplayCommand.triggerConfiguration(useSettings: true) { domain in
            requestedDomains.append(domain)
            return defaults
        }

        XCTAssertEqual(requestedDomains, [AppConfig.bundleIdentifier])
        XCTAssertEqual(configuration.startThresholdDBFS, -64.5)
        XCTAssertEqual(configuration.stopThresholdDBFS, -77.0)
    }

    func testTriggerConfigurationDoesNotReadDefaultsWithoutUseSettings() {
        var didRequestDefaults = false

        let configuration = TriggerReplayCommand.triggerConfiguration(useSettings: false) { _ in
            didRequestDefaults = true
            return nil
        }

        let baseline = AudioActivityTriggerConfiguration()
        XCTAssertFalse(didRequestDefaults)
        XCTAssertEqual(configuration.startThresholdDBFS, baseline.startThresholdDBFS)
        XCTAssertEqual(configuration.stopThresholdDBFS, baseline.stopThresholdDBFS)
    }

    func testEndOfStreamFlushDeliversPendingStopMarkerToTriggerDetector() {
        var configuration = AudioActivityTriggerConfiguration()
        configuration.minimumActiveSeconds = 0
        var detector = AudioActivityTriggerDetector(configuration: configuration)
        let startMarker = markerPCM16(frequency: 6_000, sampleCount: 320)

        XCTAssertEqual(
            detector.process(
                pcm16: startMarker,
                levelDBFS: -9,
                timestamp: 0.020,
                startingAtSampleIndex: 0
            ),
            .started
        )

        let stopMarker = markerPCM16(frequency: 7_000, sampleCount: 280)
        XCTAssertNil(
            detector.process(
                pcm16: stopMarker,
                levelDBFS: -9,
                timestamp: 0.0375,
                startingAtSampleIndex: 320
            )
        )

        XCTAssertEqual(
            TriggerReplayCommand.flushTriggerDetectorAtEndOfStream(
                detector: &detector,
                configuration: configuration,
                totalSampleCount: 600,
                timestamp: 0.0375
            ),
            .stopped
        )
        XCTAssertEqual(detector.lastStopMarker?.kind, .stop)
    }

    private func writeWAV(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TriggerReplayCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fixture.wav")
        try data.write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return url
    }

    private func markerPCM16(frequency: Double, sampleCount: Int) -> Data {
        var data = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let phase = 2 * Double.pi * frequency * Double(index) / Double(sampleRate)
            let sample = Int16((0.5 * sin(phase) * Double(Int16.max)).rounded())
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 0xFF))
            data.append(UInt8((bits >> 8) & 0xFF))
        }
        return data
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        for byteIndex in 0..<4 {
            data[data.startIndex + offset + byteIndex] = UInt8((value >> (8 * UInt32(byteIndex))) & 0xFF)
        }
    }
}
