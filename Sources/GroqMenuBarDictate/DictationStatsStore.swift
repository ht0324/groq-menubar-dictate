import Foundation
import OSLog

struct DictationStatsSnapshot: Equatable {
    var successfulSessions: Int = 0
    var totalWords: Int = 0
    var totalRecordingSeconds: TimeInterval = 0
    var lastUpdatedAt: Date?

    var isEmpty: Bool {
        successfulSessions == 0
    }

    var healthStatus: DictationStatsHealthStatus {
        guard !isEmpty else {
            return .normal
        }

        let maximumExpectedDuration = max(
            DictationStatsStore.maximumBaselineDurationSeconds * Double(successfulSessions),
            Double(max(totalWords, 1)) * DictationStatsStore.maximumSecondsPerWord
        )

        guard totalRecordingSeconds > maximumExpectedDuration else {
            return .normal
        }

        return .suspicious("Recording time looks implausibly high for the stored word count.")
    }

    func summary(typingWordsPerMinute: Int) -> DictationStatsSummary {
        DictationStatsSummary(
            snapshot: self,
            typingWordsPerMinute: max(0, typingWordsPerMinute)
        )
    }
}

enum DictationStatsHealthStatus: Equatable {
    case normal
    case suspicious(String)
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

    var healthStatus: DictationStatsHealthStatus {
        snapshot.healthStatus
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

enum DictationStatsDurationSource: String, Codable, Equatable {
    case fileMeasured
    case recorderReported
}

enum DictationStatsSessionFlag: String, Codable, Equatable {
    case recorderDurationMismatch
}

enum DictationStatsSessionRejectionReason: String, Codable, Equatable {
    case missingDuration
    case durationTooLargeForWordCount
}

struct DictationStatsSessionRecord: Codable, Equatable {
    let recordedAt: Date
    let wordCount: Int
    let accepted: Bool
    let acceptedDurationSeconds: TimeInterval?
    let fileMeasuredDurationSeconds: TimeInterval?
    let recorderReportedDurationSeconds: TimeInterval?
    let durationSource: DictationStatsDurationSource?
    let rejectionReason: DictationStatsSessionRejectionReason?
    let flags: [DictationStatsSessionFlag]
}

private struct DictationStatsSessionDecision {
    let acceptedDurationSeconds: TimeInterval?
    let durationSource: DictationStatsDurationSource?
    let rejectionReason: DictationStatsSessionRejectionReason?
    let flags: [DictationStatsSessionFlag]
}

final class DictationStatsStore {
    static let maximumBaselineDurationSeconds: TimeInterval = 10 * 60
    static let maximumSecondsPerWord = 30.0
    private static let mismatchRatioThreshold = 5.0
    private static let maximumHistoryEntries = 500

    private enum Key {
        static let successfulSessions = "stats.successfulSessions"
        static let totalWords = "stats.totalWords"
        static let totalRecordingSeconds = "stats.totalRecordingSeconds"
        static let lastUpdatedAt = "stats.lastUpdatedAt"
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.huntae.groq-menubar-dictate", category: "stats")
    let historyFileURL: URL

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        historyFileURL: URL? = nil
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.historyFileURL = historyFileURL ?? Self.defaultHistoryFileURL(fileManager: fileManager)
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
        recordSuccessfulSession(
            text: text,
            fileMeasuredDurationSeconds: recordingDurationSeconds,
            recorderReportedDurationSeconds: nil,
            recordedAt: recordedAt
        )
    }

    @discardableResult
    func recordSuccessfulSession(
        text: String,
        fileMeasuredDurationSeconds: TimeInterval?,
        recorderReportedDurationSeconds: TimeInterval?,
        recordedAt: Date = Date()
    ) -> DictationStatsSnapshot {
        let wordCount = TypingSavingsCalculator.wordCount(for: text)
        let decision = Self.makeSessionDecision(
            wordCount: wordCount,
            fileMeasuredDurationSeconds: fileMeasuredDurationSeconds,
            recorderReportedDurationSeconds: recorderReportedDurationSeconds
        )

        let sessionRecord = DictationStatsSessionRecord(
            recordedAt: recordedAt,
            wordCount: wordCount,
            accepted: decision.acceptedDurationSeconds != nil,
            acceptedDurationSeconds: decision.acceptedDurationSeconds,
            fileMeasuredDurationSeconds: Self.normalizedDuration(fileMeasuredDurationSeconds),
            recorderReportedDurationSeconds: Self.normalizedDuration(recorderReportedDurationSeconds),
            durationSource: decision.durationSource,
            rejectionReason: decision.rejectionReason,
            flags: decision.flags
        )
        appendSessionRecord(sessionRecord)

        guard let acceptedDurationSeconds = decision.acceptedDurationSeconds else {
            logRejectedSession(sessionRecord)
            return snapshot
        }

        var snapshot = snapshot
        snapshot.successfulSessions += 1
        snapshot.totalWords += wordCount
        snapshot.totalRecordingSeconds += acceptedDurationSeconds
        snapshot.lastUpdatedAt = recordedAt
        save(snapshot)
        logAcceptedSession(sessionRecord)
        return snapshot
    }

    func loadSessionHistory(limit: Int = 50) -> [DictationStatsSessionRecord] {
        guard limit > 0,
              let raw = try? String(contentsOf: historyFileURL, encoding: .utf8)
        else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return raw
            .split(whereSeparator: \.isNewline)
            .suffix(limit)
            .compactMap { Data($0.utf8) }
            .compactMap { try? decoder.decode(DictationStatsSessionRecord.self, from: $0) }
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

    private static func makeSessionDecision(
        wordCount: Int,
        fileMeasuredDurationSeconds: TimeInterval?,
        recorderReportedDurationSeconds: TimeInterval?
    ) -> DictationStatsSessionDecision {
        let normalizedFileDuration = normalizedDuration(fileMeasuredDurationSeconds)
        let normalizedRecorderDuration = normalizedDuration(recorderReportedDurationSeconds)
        var flags: [DictationStatsSessionFlag] = []

        if let normalizedFileDuration, let normalizedRecorderDuration {
            let ratio = max(normalizedFileDuration, normalizedRecorderDuration) /
                max(min(normalizedFileDuration, normalizedRecorderDuration), 0.001)
            if ratio >= mismatchRatioThreshold {
                flags.append(.recorderDurationMismatch)
            }
        }

        let acceptedDurationSeconds: TimeInterval?
        let durationSource: DictationStatsDurationSource?
        if let normalizedFileDuration {
            acceptedDurationSeconds = normalizedFileDuration
            durationSource = .fileMeasured
        } else if let normalizedRecorderDuration {
            acceptedDurationSeconds = normalizedRecorderDuration
            durationSource = .recorderReported
        } else {
            return DictationStatsSessionDecision(
                acceptedDurationSeconds: nil,
                durationSource: nil,
                rejectionReason: .missingDuration,
                flags: flags
            )
        }

        let maximumExpectedDuration = max(
            maximumBaselineDurationSeconds,
            Double(max(wordCount, 1)) * maximumSecondsPerWord
        )
        guard let acceptedDurationSeconds, acceptedDurationSeconds <= maximumExpectedDuration else {
            return DictationStatsSessionDecision(
                acceptedDurationSeconds: nil,
                durationSource: nil,
                rejectionReason: .durationTooLargeForWordCount,
                flags: flags
            )
        }

        return DictationStatsSessionDecision(
            acceptedDurationSeconds: acceptedDurationSeconds,
            durationSource: durationSource,
            rejectionReason: nil,
            flags: flags
        )
    }

    private static func normalizedDuration(_ durationSeconds: TimeInterval?) -> TimeInterval? {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else {
            return nil
        }
        return durationSeconds
    }

    private func appendSessionRecord(_ sessionRecord: DictationStatsSessionRecord) {
        let historyFolderURL = historyFileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: historyFolderURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        guard let encodedRecord = try? encoder.encode(sessionRecord),
              let encodedLine = String(data: encodedRecord, encoding: .utf8)
        else {
            return
        }

        if !fileManager.fileExists(atPath: historyFileURL.path) {
            try? (encodedLine + "\n").write(to: historyFileURL, atomically: true, encoding: .utf8)
            return
        }

        guard let fileHandle = try? FileHandle(forWritingTo: historyFileURL) else {
            return
        }

        do {
            defer {
                try? fileHandle.close()
            }
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: Data((encodedLine + "\n").utf8))
        } catch {
            return
        }

        pruneHistoryIfNeeded()
    }

    private func pruneHistoryIfNeeded() {
        guard let raw = try? String(contentsOf: historyFileURL, encoding: .utf8) else {
            return
        }

        let lines = raw.split(whereSeparator: \.isNewline)
        guard lines.count > Self.maximumHistoryEntries else {
            return
        }

        let trimmed = lines.suffix(Self.maximumHistoryEntries).joined(separator: "\n") + "\n"
        try? trimmed.write(to: historyFileURL, atomically: true, encoding: .utf8)
    }

    private func logAcceptedSession(_ sessionRecord: DictationStatsSessionRecord) {
        let flags = sessionRecord.flags.map(\.rawValue).joined(separator: ",")
        logger.notice(
            "Stats accepted words=\(sessionRecord.wordCount, privacy: .public) accepted_duration_s=\(sessionRecord.acceptedDurationSeconds ?? -1, format: .fixed(precision: 3)) file_duration_s=\(sessionRecord.fileMeasuredDurationSeconds ?? -1, format: .fixed(precision: 3)) recorder_duration_s=\(sessionRecord.recorderReportedDurationSeconds ?? -1, format: .fixed(precision: 3)) source=\(sessionRecord.durationSource?.rawValue ?? "none", privacy: .public) flags=\(flags, privacy: .public)"
        )
    }

    private func logRejectedSession(_ sessionRecord: DictationStatsSessionRecord) {
        let flags = sessionRecord.flags.map(\.rawValue).joined(separator: ",")
        logger.error(
            "Stats rejected words=\(sessionRecord.wordCount, privacy: .public) file_duration_s=\(sessionRecord.fileMeasuredDurationSeconds ?? -1, format: .fixed(precision: 3)) recorder_duration_s=\(sessionRecord.recorderReportedDurationSeconds ?? -1, format: .fixed(precision: 3)) reason=\(sessionRecord.rejectionReason?.rawValue ?? "unknown", privacy: .public) flags=\(flags, privacy: .public)"
        )
    }

    private static func defaultHistoryFileURL(fileManager: FileManager) -> URL {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupportURL
            .appendingPathComponent(AppConfig.appSupportFolderName, isDirectory: true)
            .appendingPathComponent("stats-history.jsonl", isDirectory: false)
    }
}
