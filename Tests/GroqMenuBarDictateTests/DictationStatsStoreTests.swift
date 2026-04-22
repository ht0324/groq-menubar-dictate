import Foundation
import XCTest
@testable import GroqMenuBarDictate

final class DictationStatsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var historyFileURL: URL!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "DictationStatsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        historyFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationStatsStoreTests-\(UUID().uuidString)")
            .appendingPathExtension("jsonl")
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: historyFileURL)
        defaults = nil
        historyFileURL = nil
        suiteName = nil
    }

    func testWordCountTreatsPunctuationAsPartOfWordBoundaries() {
        XCTAssertEqual(
            TypingSavingsCalculator.wordCount(for: "Hello, world.\nOne more line."),
            5
        )
    }

    func testEstimatedTypingSecondsRequiresPositiveWordsPerMinute() {
        XCTAssertNil(
            TypingSavingsCalculator.estimatedTypingSeconds(
                forWordCount: 120,
                typingWordsPerMinute: 0
            )
        )
    }

    func testRecordSuccessfulSessionAccumulatesWordsAndDuration() {
        let store = makeStore()

        store.recordSuccessfulSession(
            text: "hello world",
            recordingDurationSeconds: 3.5,
            recordedAt: Date(timeIntervalSince1970: 100)
        )
        let snapshot = store.recordSuccessfulSession(
            text: "one more session",
            recordingDurationSeconds: 6.25,
            recordedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(snapshot.successfulSessions, 2)
        XCTAssertEqual(snapshot.totalWords, 5)
        XCTAssertEqual(snapshot.totalRecordingSeconds, 9.75, accuracy: 0.001)
        XCTAssertEqual(snapshot.lastUpdatedAt, Date(timeIntervalSince1970: 200))
    }

    func testRecordSuccessfulSessionPrefersFileMeasuredDurationAndFlagsRecorderMismatch() {
        let store = makeStore()

        let snapshot = store.recordSuccessfulSession(
            text: "one more session",
            fileMeasuredDurationSeconds: 12,
            recorderReportedDurationSeconds: 720,
            recordedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(snapshot.successfulSessions, 1)
        XCTAssertEqual(snapshot.totalWords, 3)
        XCTAssertEqual(snapshot.totalRecordingSeconds, 12, accuracy: 0.001)

        let history = store.loadSessionHistory(limit: 1)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].accepted, true)
        XCTAssertEqual(history[0].acceptedDurationSeconds ?? -1, 12, accuracy: 0.001)
        XCTAssertEqual(history[0].durationSource, .fileMeasured)
        XCTAssertEqual(history[0].flags, [.recorderDurationMismatch])
    }

    func testRecordSuccessfulSessionRejectsImplausiblyLongDurationForWordCount() {
        let store = makeStore()

        let snapshot = store.recordSuccessfulSession(
            text: "hello world",
            fileMeasuredDurationSeconds: 3600,
            recorderReportedDurationSeconds: 3600,
            recordedAt: Date(timeIntervalSince1970: 400)
        )

        XCTAssertEqual(snapshot, DictationStatsSnapshot())

        let history = store.loadSessionHistory(limit: 1)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].accepted, false)
        XCTAssertEqual(history[0].rejectionReason, .durationTooLargeForWordCount)
    }

    func testSummaryDerivesTypingAndSavedTimeFromCurrentWordsPerMinute() {
        let snapshot = DictationStatsSnapshot(
            successfulSessions: 3,
            totalWords: 120,
            totalRecordingSeconds: 72,
            lastUpdatedAt: nil
        )

        let summary = snapshot.summary(typingWordsPerMinute: 60)

        XCTAssertEqual(summary.estimatedTypingSeconds ?? -1, 120, accuracy: 0.001)
        XCTAssertEqual(summary.savedSeconds ?? -1, 48, accuracy: 0.001)
    }

    func testHealthStatusFlagsImplausiblyLargeAggregateRecordingTime() {
        let snapshot = DictationStatsSnapshot(
            successfulSessions: 488,
            totalWords: 19_982,
            totalRecordingSeconds: 1_405_898.5395,
            lastUpdatedAt: nil
        )

        guard case let .suspicious(message) = snapshot.healthStatus else {
            return XCTFail("Expected suspicious aggregate health status")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testResetClearsStoredStats() {
        let store = makeStore()
        store.recordSuccessfulSession(text: "hello world", recordingDurationSeconds: 5)

        store.reset()

        XCTAssertEqual(store.snapshot, DictationStatsSnapshot())
    }

    private func makeStore() -> DictationStatsStore {
        DictationStatsStore(
            defaults: defaults,
            historyFileURL: historyFileURL
        )
    }
}
