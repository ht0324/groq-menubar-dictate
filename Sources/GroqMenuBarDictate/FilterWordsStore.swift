import AppKit
import Foundation

final class FilterWordsStore {
    private struct WordsCache {
        let modificationDate: Date?
        let words: [String]
    }

    private let fileManager: FileManager
    let wordsFileURL: URL
    private var cache: WordsCache?

    init(fileManager: FileManager = .default, wordsFileURL: URL? = nil) {
        self.fileManager = fileManager
        self.wordsFileURL = wordsFileURL ?? Self.defaultWordsFileURL(fileManager: fileManager)
    }

    func ensureFileExists() throws {
        let folder = wordsFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: wordsFileURL.path) else {
            return
        }

        let initial = """
        # One filter term per line.
        # Commas inside a term stay part of that same term.
        # Matching removes term variants case-insensitively:
        # "<term> ", "<term>, ", "<term>. ", and "<term>."
        # Example: um -> removes "um ", "Um ", "um, ", "um."
        """
        try (initial + "\n").write(to: wordsFileURL, atomically: true, encoding: .utf8)
        cache = nil
    }

    func openWordsFile() throws {
        try ensureFileExists()
        NSWorkspace.shared.open(wordsFileURL)
    }

    func loadWords(limit: Int = 200) -> [String] {
        guard limit > 0 else {
            return []
        }
        let allWords = loadAllWords()
        if allWords.count <= limit {
            return allWords
        }
        return Array(allWords.prefix(limit))
    }

    func applyFilters(
        to text: String,
        words: [String]? = nil,
        endPruneEnabled: Bool = true,
        endPrunePhrases: [String] = EndPrunePhrasesStore.defaultPhrases
    ) -> String {
        let filtered = Self.applyWordFilters(to: text, words: words ?? loadWords())
        guard endPruneEnabled else {
            return Self.trimTrailingWhitespace(filtered)
        }
        return Self.applyEndingPruneRules(to: filtered, phrases: endPrunePhrases)
    }

    static func parseWords(from raw: String, limit: Int) -> [String] {
        guard limit > 0 else {
            return []
        }
        let lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        var seen = Set<String>()
        var result: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            let key = trimmed.lowercased()
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            result.append(trimmed)
            if result.count >= limit {
                break
            }
        }
        return result
    }

    private func loadAllWords() -> [String] {
        let modificationDate = fileModificationDate(for: wordsFileURL)
        if let cache, cache.modificationDate == modificationDate {
            return cache.words
        }

        guard let raw = try? String(contentsOf: wordsFileURL, encoding: .utf8) else {
            cache = WordsCache(modificationDate: modificationDate, words: [])
            return []
        }

        let parsed = Self.parseWords(from: raw, limit: Int.max)
        cache = WordsCache(modificationDate: modificationDate, words: parsed)
        return parsed
    }

    static func applyWordFilters(to text: String, words: [String]) -> String {
        var output = text
        for word in words {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            output = output.replacingOccurrences(
                of: removalPattern(for: trimmed),
                with: "",
                options: [.caseInsensitive, .regularExpression],
                range: nil
            )
        }
        return output
    }

    static func applyEndingPruneRules(
        to text: String,
        phrases: [String] = EndPrunePhrasesStore.defaultPhrases
    ) -> String {
        var output = trimTrailingWhitespace(text)
        let normalizedPhrases = phrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedPhrases.isEmpty else {
            return output
        }

        let escaped = normalizedPhrases.map(NSRegularExpression.escapedPattern(for:))
        let signoffPattern = "(?i)\\b(?:\(escaped.joined(separator: "|")))\\.?\\s*$"
        while true {
            let pruned = output.replacingOccurrences(
                of: signoffPattern,
                with: "",
                options: [.regularExpression],
                range: nil
            )
            let trimmed = trimTrailingWhitespace(pruned)
            if trimmed == output {
                return trimmed
            }
            output = trimmed
        }
    }

    private static func removalPattern(for word: String) -> String {
        let escapedWord = NSRegularExpression.escapedPattern(for: word)
        return #"(?<![\p{L}\p{N}_])\#(escapedWord)(?:,[\t ]+|\.[\t ]+|\.|[\t ]+)"#
    }

    private static func trimTrailingWhitespace(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\s+$"#,
            with: "",
            options: [.regularExpression],
            range: nil
        )
    }

    private static func defaultWordsFileURL(fileManager: FileManager) -> URL {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupportURL
            .appendingPathComponent(AppConfig.appSupportFolderName, isDirectory: true)
            .appendingPathComponent("filter-words.txt", isDirectory: false)
    }

    private func fileModificationDate(for url: URL) -> Date? {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}
