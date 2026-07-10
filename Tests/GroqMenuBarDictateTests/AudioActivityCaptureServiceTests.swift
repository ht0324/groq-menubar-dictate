import XCTest
@testable import GroqMenuBarDictate

final class PCM16WAVEncoderTests: XCTestCase {
    func testWAVHeaderAndPayload() {
        let samples = Data([0x01, 0x00, 0xFF, 0x7F, 0x00, 0x80])
        let wav = PCM16WAVEncoder.wavData(pcm16: samples, sampleRate: 16_000)

        XCTAssertEqual(wav.count, 44 + samples.count)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav.subdata(in: 12..<16), encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: wav.subdata(in: 36..<40), encoding: .ascii), "data")

        XCTAssertEqual(readUInt32(wav, at: 4), UInt32(36 + samples.count))
        XCTAssertEqual(readUInt16(wav, at: 20), 1) // PCM
        XCTAssertEqual(readUInt16(wav, at: 22), 1) // mono
        XCTAssertEqual(readUInt32(wav, at: 24), 16_000) // sample rate
        XCTAssertEqual(readUInt32(wav, at: 28), 32_000) // byte rate
        XCTAssertEqual(readUInt16(wav, at: 32), 2) // block align
        XCTAssertEqual(readUInt16(wav, at: 34), 16) // bits per sample
        XCTAssertEqual(readUInt32(wav, at: 40), UInt32(samples.count))
        XCTAssertEqual(wav.suffix(samples.count), samples)
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { result, byteIndex in
            result | (UInt32(data[data.startIndex + offset + byteIndex]) << (8 * UInt32(byteIndex)))
        }
    }
}

final class AudioLevelTests: XCTestCase {
    func testSilenceIsAtFloor() {
        let silence = Data(repeating: 0, count: 640)
        let level = AudioActivityCaptureService.levelDBFS(pcm16: silence)
        XCTAssertNotNil(level)
        XCTAssertLessThan(level!, -130)
    }

    func testFullScaleSquareWaveIsNearZeroDBFS() {
        var samples = Data()
        for index in 0..<320 {
            let value: Int16 = index.isMultiple(of: 2) ? .max : -.max
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        let level = AudioActivityCaptureService.levelDBFS(pcm16: samples)
        XCTAssertNotNil(level)
        XCTAssertEqual(level!, 0, accuracy: 0.01)
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(AudioActivityCaptureService.levelDBFS(pcm16: Data()))
        XCTAssertNil(AudioActivityCaptureService.levelDBFS(pcm16: Data([0x01])))
    }
}
