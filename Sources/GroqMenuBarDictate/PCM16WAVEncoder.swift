import Foundation

enum PCM16WAVEncoder {
    static func wavData(pcm16 samples: Data, sampleRate: Int, channelCount: Int = 1) -> Data {
        let bytesPerSample = 2
        let byteRate = sampleRate * channelCount * bytesPerSample
        let blockAlign = channelCount * bytesPerSample

        var data = Data(capacity: 44 + samples.count)
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(&data, UInt32(36 + samples.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(&data, 16)
        appendUInt16(&data, 1) // PCM
        appendUInt16(&data, UInt16(channelCount))
        appendUInt32(&data, UInt32(sampleRate))
        appendUInt32(&data, UInt32(byteRate))
        appendUInt16(&data, UInt16(blockAlign))
        appendUInt16(&data, 16) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(&data, UInt32(samples.count))
        data.append(samples)
        return data
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
