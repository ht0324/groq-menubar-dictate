import Foundation
import XCTest
@testable import GroqMenuBarDictate

final class TriggerReplayCommandTests: XCTestCase {
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

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        for byteIndex in 0..<4 {
            data[data.startIndex + offset + byteIndex] = UInt8((value >> (8 * UInt32(byteIndex))) & 0xFF)
        }
    }
}
