import Foundation
import XCTest
@testable import GroqMenuBarDictate

final class DictationStatsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "DictationStatsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
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
        let store = DictationStatsStore(defaults: defaults)

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

    func testResetClearsStoredStats() {
        let store = DictationStatsStore(defaults: defaults)
        store.recordSuccessfulSession(text: "hello world", recordingDurationSeconds: 5)

        store.reset()

        XCTAssertEqual(store.snapshot, DictationStatsSnapshot())
    }
}
