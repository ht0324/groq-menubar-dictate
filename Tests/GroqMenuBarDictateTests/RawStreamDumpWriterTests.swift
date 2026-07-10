import Foundation
import XCTest
@testable import GroqMenuBarDictate

final class RawStreamDumpWriterTests: XCTestCase {
    func testWritesValidWAVWithPatchedSizes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstChunk = Data([0x01, 0x00, 0xFF, 0x7F])
        let secondChunk = Data([0x00, 0x80, 0x34, 0x12])
        var expectedPayload = Data()
        expectedPayload.append(firstChunk)
        expectedPayload.append(secondChunk)

        let writer = try RawStreamDumpWriter(directory: directory, sampleRate: 16_000)
        writer.append(firstChunk)
        writer.append(secondChunk)
        writer.close()

        let wav = try Data(contentsOf: writer.fileURL)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav.subdata(in: 12..<16), encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: wav.subdata(in: 36..<40), encoding: .ascii), "data")
        XCTAssertEqual(readUInt32(wav, at: 4), UInt32(36 + expectedPayload.count))
        XCTAssertEqual(readUInt16(wav, at: 20), 1)
        XCTAssertEqual(readUInt16(wav, at: 22), 1)
        XCTAssertEqual(readUInt32(wav, at: 24), 16_000)
        XCTAssertEqual(readUInt32(wav, at: 28), 32_000)
        XCTAssertEqual(readUInt16(wav, at: 32), 2)
        XCTAssertEqual(readUInt16(wav, at: 34), 16)
        XCTAssertEqual(readUInt32(wav, at: 40), UInt32(expectedPayload.count))
        XCTAssertEqual(wav.subdata(in: 44..<wav.count), expectedPayload)
    }

    func testPrunesOldRawDumpsToMaxFilesIncludingNewDump() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = FileManager.default

        for index in 0..<5 {
            let url = directory.appendingPathComponent("ting-raw-20010101-00000\(index).wav")
            try PCM16WAVEncoder.wavData(pcm16: Data([UInt8(index), 0]), sampleRate: 16_000)
                .write(to: url)
            try fileManager.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: url.path
            )
        }

        let writer = try RawStreamDumpWriter(directory: directory, sampleRate: 16_000, maxFiles: 3)
        writer.close()

        let dumpNames = try fileManager.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("ting-raw-") && $0.hasSuffix(".wav") }
        XCTAssertLessThanOrEqual(dumpNames.count, 3)
        XCTAssertTrue(dumpNames.contains(writer.fileURL.lastPathComponent))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawStreamDumpWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset])
            | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { result, byteIndex in
            result | (UInt32(data[data.startIndex + offset + byteIndex]) << (8 * UInt32(byteIndex)))
        }
    }
}
