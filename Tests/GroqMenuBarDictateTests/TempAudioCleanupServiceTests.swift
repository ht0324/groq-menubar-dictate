import Foundation
import XCTest
@testable import GroqMenuBarDictate

final class TempAudioCleanupServiceTests: XCTestCase {
    private let maxAge: TimeInterval = 24 * 60 * 60

    func testCleanupStaleFilesRemovesOldMatchingFiles() throws {
        let fixture = try TempDirectoryFixture()
        let now = Date()
        let staleURL = try fixture.createFile(
            named: "dictation-old.m4a",
            modifiedAt: now.addingTimeInterval(-(maxAge + 60))
        )
        let recentURL = try fixture.createFile(
            named: "dictation-recent.m4a",
            modifiedAt: now.addingTimeInterval(-60)
        )

        let service = TempAudioCleanupService(
            fileManager: .default,
            temporaryDirectory: fixture.url,
            nowProvider: { now }
        )

        let report = service.cleanupStaleFiles(olderThan: maxAge)

        XCTAssertEqual(report.scannedCount, 2)
        XCTAssertEqual(report.removedCount, 1)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentURL.path))
    }

    func testCleanupStaleFilesKeepsRecentMatchingFiles() throws {
        let fixture = try TempDirectoryFixture()
        let now = Date()
        let recentURL = try fixture.createFile(
            named: "dictation-recent-only.m4a",
            modifiedAt: now.addingTimeInterval(-120)
        )

        let service = TempAudioCleanupService(
            fileManager: .default,
            temporaryDirectory: fixture.url,
            nowProvider: { now }
        )

        let report = service.cleanupStaleFiles(olderThan: maxAge)

        XCTAssertEqual(report.scannedCount, 1)
        XCTAssertEqual(report.removedCount, 0)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentURL.path))
    }

    func testCleanupStaleFilesKeepsNonMatchingFiles() throws {
        let fixture = try TempDirectoryFixture()
        let now = Date()
        let nonMatchingURL = try fixture.createFile(
            named: "unrelated-audio.m4a",
            modifiedAt: now.addingTimeInterval(-(maxAge + 60))
        )

        let service = TempAudioCleanupService(
            fileManager: .default,
            temporaryDirectory: fixture.url,
            nowProvider: { now }
        )

        let report = service.cleanupStaleFiles(olderThan: maxAge)

        XCTAssertEqual(report.scannedCount, 0)
        XCTAssertEqual(report.removedCount, 0)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonMatchingURL.path))
    }

    func testCleanupStaleFilesContinuesWhenDeleteFails() throws {
        let fixture = try TempDirectoryFixture()
        let now = Date()
        let failURL = try fixture.createFile(
            named: "dictation-fail.m4a",
            modifiedAt: now.addingTimeInterval(-(maxAge + 60))
        )
        let deleteURL = try fixture.createFile(
            named: "dictation-delete.m4a",
            modifiedAt: now.addingTimeInterval(-(maxAge + 120))
        )

        let service = TempAudioCleanupService(
            fileManager: .default,
            temporaryDirectory: fixture.url,
            nowProvider: { now },
            removeItemHandler: { url in
                if url.lastPathComponent == failURL.lastPathComponent {
                    throw NSError(domain: "TempAudioCleanupServiceTests", code: 1)
                }
                try FileManager.default.removeItem(at: url)
            }
        )

        let report = service.cleanupStaleFiles(olderThan: maxAge)

        XCTAssertEqual(report.scannedCount, 2)
        XCTAssertEqual(report.removedCount, 1)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleteURL.path))
    }
}

private final class TempDirectoryFixture {
    let url: URL
    private let fileManager = FileManager.default

    init() throws {
        url = fileManager.temporaryDirectory.appendingPathComponent(
            "temp-audio-cleanup-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func createFile(named fileName: String, modifiedAt: Date) throws -> URL {
        let fileURL = url.appendingPathComponent(fileName)
        let data = Data("test".utf8)
        try data.write(to: fileURL)
        try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: fileURL.path)
        return fileURL
    }

    deinit {
        try? fileManager.removeItem(at: url)
    }
}
