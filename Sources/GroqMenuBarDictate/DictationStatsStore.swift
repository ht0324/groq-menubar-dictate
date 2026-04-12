import Foundation

struct DictationStatsSnapshot: Equatable {
    var successfulSessions: Int = 0
    var totalWords: Int = 0
    var totalRecordingSeconds: TimeInterval = 0
    var lastUpdatedAt: Date?

    var isEmpty: Bool {
        successfulSessions == 0
    }

    func summary(typingWordsPerMinute: Int) -> DictationStatsSummary {
        DictationStatsSummary(
            snapshot: self,
            typingWordsPerMinute: max(0, typingWordsPerMinute)
        )
    }
}

struct DictationStatsSummary: Equatable {
    let snapshot: DictationStatsSnapshot
    let typingWordsPerMinute: Int

    var estimatedTypingSeconds: TimeInterval? {
        TypingSavingsCalculator.estimatedTypingSeconds(
            forWordCount: snapshot.totalWords,
            typingWordsPerMinute: typingWordsPerMinute
        )
    }

    var savedSeconds: TimeInterval? {
        guard let estimatedTypingSeconds else {
            return nil
        }
        return estimatedTypingSeconds - snapshot.totalRecordingSeconds
    }
}

enum TypingSavingsCalculator {
    static func wordCount(for text: String) -> Int {
        guard !text.isEmpty else {
            return 0
        }

        var count = 0
        text.enumerateSubstrings(
            in: text.startIndex ..< text.endIndex,
            options: [.byWords]
        ) { _, _, _, _ in
            count += 1
        }

        if count > 0 {
            return count
        }

        return text.split(whereSeparator: \.isWhitespace).count
    }

    static func estimatedTypingSeconds(
        forWordCount wordCount: Int,
        typingWordsPerMinute: Int
    ) -> TimeInterval? {
        guard wordCount > 0, typingWordsPerMinute > 0 else {
            return nil
        }
        return Double(wordCount) / Double(typingWordsPerMinute) * 60
    }
}

final class DictationStatsStore {
    private enum Key {
        static let successfulSessions = "stats.successfulSessions"
        static let totalWords = "stats.totalWords"
        static let totalRecordingSeconds = "stats.totalRecordingSeconds"
        static let lastUpdatedAt = "stats.lastUpdatedAt"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var snapshot: DictationStatsSnapshot {
        DictationStatsSnapshot(
            successfulSessions: max(0, defaults.integer(forKey: Key.successfulSessions)),
            totalWords: max(0, defaults.integer(forKey: Key.totalWords)),
            totalRecordingSeconds: max(0, defaults.double(forKey: Key.totalRecordingSeconds)),
            lastUpdatedAt: defaults.object(forKey: Key.lastUpdatedAt) as? Date
        )
    }

    @discardableResult
    func recordSuccessfulSession(
        text: String,
        recordingDurationSeconds: TimeInterval,
        recordedAt: Date = Date()
    ) -> DictationStatsSnapshot {
        var snapshot = snapshot
        snapshot.successfulSessions += 1
        snapshot.totalWords += TypingSavingsCalculator.wordCount(for: text)
        snapshot.totalRecordingSeconds += max(0, recordingDurationSeconds)
        snapshot.lastUpdatedAt = recordedAt
        save(snapshot)
        return snapshot
    }

    func reset() {
        defaults.removeObject(forKey: Key.successfulSessions)
        defaults.removeObject(forKey: Key.totalWords)
        defaults.removeObject(forKey: Key.totalRecordingSeconds)
        defaults.removeObject(forKey: Key.lastUpdatedAt)
    }

    private func save(_ snapshot: DictationStatsSnapshot) {
        defaults.set(snapshot.successfulSessions, forKey: Key.successfulSessions)
        defaults.set(snapshot.totalWords, forKey: Key.totalWords)
        defaults.set(snapshot.totalRecordingSeconds, forKey: Key.totalRecordingSeconds)
        defaults.set(snapshot.lastUpdatedAt, forKey: Key.lastUpdatedAt)
    }
}
