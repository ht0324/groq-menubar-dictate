import Foundation

final class RawStreamDumpWriter {
    let fileURL: URL

    private let fileHandle: FileHandle
    private var dataByteCount = 0
    private var isClosed = false
    private(set) var lastError: Error?

    init(directory: URL, sampleRate: Int, maxFiles: Int = 10) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        fileURL = Self.uniqueFileURL(in: directory, date: Date())
        let header = PCM16WAVEncoder.wavData(pcm16: Data(), sampleRate: max(1, sampleRate))
        try header.write(to: fileURL, options: .atomic)
        try Self.pruneDumps(in: directory, maxFiles: max(1, maxFiles), keeping: fileURL)

        fileHandle = try FileHandle(forWritingTo: fileURL)
        _ = try fileHandle.seekToEnd()
    }

    deinit {
        close()
    }

    func append(_ pcm16: Data) {
        guard !isClosed, lastError == nil, !pcm16.isEmpty else {
            return
        }

        do {
            try fileHandle.write(contentsOf: pcm16)
            dataByteCount += pcm16.count
        } catch {
            lastError = error
        }
    }

    func close() {
        guard !isClosed else {
            return
        }
        isClosed = true

        do {
            try patchHeaderSizes()
            try fileHandle.close()
        } catch {
            lastError = error
            try? fileHandle.close()
        }
    }

    private func patchHeaderSizes() throws {
        let riffSize = UInt32(clamping: 36 + dataByteCount)
        let dataSize = UInt32(clamping: dataByteCount)

        try fileHandle.seek(toOffset: 4)
        try fileHandle.write(contentsOf: Self.littleEndianData(riffSize))
        try fileHandle.seek(toOffset: 40)
        try fileHandle.write(contentsOf: Self.littleEndianData(dataSize))
    }

    private static func littleEndianData(_ value: UInt32) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }

    private static func filename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "ting-raw-\(formatter.string(from: date)).wav"
    }

    private static func uniqueFileURL(in directory: URL, date: Date) -> URL {
        var candidateDate = date
        for _ in 0..<1_000 {
            let candidate = directory.appendingPathComponent(filename(for: candidateDate))
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            candidateDate = candidateDate.addingTimeInterval(1)
        }
        return directory.appendingPathComponent(filename(for: candidateDate))
    }

    private static func pruneDumps(in directory: URL, maxFiles: Int, keeping newFileURL: URL) throws {
        let fileManager = FileManager.default
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        let dumps = files
            .filter { $0.lastPathComponent.hasPrefix("ting-raw-") && $0.pathExtension == "wav" }
            .sorted { lhs, rhs in
                let lhsDate = modificationDate(for: lhs) ?? .distantPast
                let rhsDate = modificationDate(for: rhs) ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.path < rhs.path
                }
                return lhsDate < rhsDate
            }

        let overflow = dumps.count - maxFiles
        guard overflow > 0 else {
            return
        }

        var removed = 0
        for dump in dumps where removed < overflow {
            guard dump != newFileURL else {
                continue
            }
            try fileManager.removeItem(at: dump)
            removed += 1
        }
    }

    private static func modificationDate(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return values?.contentModificationDate ?? values?.creationDate
    }
}
