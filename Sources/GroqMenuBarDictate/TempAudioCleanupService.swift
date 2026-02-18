import Foundation

struct TempAudioCleanupReport {
    let scannedCount: Int
    let removedCount: Int
    let failedCount: Int
}

final class TempAudioCleanupService {
    static let defaultMaxFileAge: TimeInterval = 24 * 60 * 60

    typealias RemoveItemHandler = (URL) throws -> Void

    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let nowProvider: () -> Date
    private let removeItemHandler: RemoveItemHandler

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        nowProvider: @escaping () -> Date = Date.init,
        removeItemHandler: RemoveItemHandler? = nil
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.nowProvider = nowProvider
        self.removeItemHandler = removeItemHandler ?? { url in
            try fileManager.removeItem(at: url)
        }
    }

    func cleanupStaleFiles(olderThan maxAge: TimeInterval = TempAudioCleanupService.defaultMaxFileAge) -> TempAudioCleanupReport {
        let staleCutoff = nowProvider().addingTimeInterval(-maxAge)
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let fileURLs: [URL]
        do {
            fileURLs = try fileManager.contentsOfDirectory(
                at: temporaryDirectory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            return TempAudioCleanupReport(scannedCount: 0, removedCount: 0, failedCount: 1)
        }

        var scannedCount = 0
        var removedCount = 0
        var failedCount = 0

        for fileURL in fileURLs {
            guard isManagedAudioTempFile(fileURL) else {
                continue
            }
            scannedCount += 1

            do {
                let values = try fileURL.resourceValues(forKeys: resourceKeys)
                guard values.isRegularFile == true else {
                    continue
                }
                guard let modificationDate = values.contentModificationDate else {
                    failedCount += 1
                    continue
                }
                guard modificationDate <= staleCutoff else {
                    continue
                }
                try removeItemHandler(fileURL)
                removedCount += 1
            } catch {
                failedCount += 1
            }
        }

        return TempAudioCleanupReport(
            scannedCount: scannedCount,
            removedCount: removedCount,
            failedCount: failedCount
        )
    }

    private func isManagedAudioTempFile(_ fileURL: URL) -> Bool {
        let fileName = fileURL.lastPathComponent
        return fileName.hasPrefix("dictation-") && fileURL.pathExtension.lowercased() == "m4a"
    }
}
