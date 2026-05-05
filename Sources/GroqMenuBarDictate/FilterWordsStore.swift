import AppKit
import Foundation

final class FilterWordsStore {
    private struct WordsCache {
        let modificationDate: Date?
        let words: [String]
    }

    private struct RegexCache {
        let key: [String]
        let regex: NSRegularExpression?
    }

    private let fileManager: FileManager
    let wordsFileURL: URL
    private var cache: WordsCache?
    private var wordFilterRegexCache: RegexCache?
    private var endingPruneRegexCache: RegexCache?

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
        let filterWords = words ?? loadWords()
        let filtered = Self.applyWordFilters(to: text, regex: wordFilterRegex(for: filterWords))
        guard endPruneEnabled else {
            return Self.trimTrailingWhitespace(filtered)
        }
        return Self.applyEndingPruneRules(to: filtered, regex: endingPruneRegex(for: endPrunePhrases))
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
        applyWordFilters(to: text, regex: removalRegex(for: words))
    }

    private static func applyWordFilters(to text: String, regex: NSRegularExpression?) -> String {
        guard let regex else {
            return text
        }
        return replaceMatches(in: text, regex: regex)
    }

    static func applyEndingPruneRules(
        to text: String,
        phrases: [String] = EndPrunePhrasesStore.defaultPhrases
    ) -> String {
        applyEndingPruneRules(to: text, regex: endingPruneRegex(for: phrases))
    }

    private static func applyEndingPruneRules(to text: String, regex: NSRegularExpression?) -> String {
        var output = trimTrailingWhitespace(text)
        guard let regex else {
            return output
        }

        while true {
            let pruned = replaceMatches(in: output, regex: regex)
            let trimmed = trimTrailingWhitespace(pruned)
            if trimmed == output {
                return trimmed
            }
            output = trimmed
        }
    }

    private func wordFilterRegex(for words: [String]) -> NSRegularExpression? {
        let key = Self.normalizedFilterWords(from: words)
        if let wordFilterRegexCache, wordFilterRegexCache.key == key {
            return wordFilterRegexCache.regex
        }

        let regex = Self.removalRegex(forNormalizedWords: key)
        wordFilterRegexCache = RegexCache(key: key, regex: regex)
        return regex
    }

    private func endingPruneRegex(for phrases: [String]) -> NSRegularExpression? {
        let key = Self.normalizedPhrases(from: phrases)
        if let endingPruneRegexCache, endingPruneRegexCache.key == key {
            return endingPruneRegexCache.regex
        }

        let regex = Self.endingPruneRegex(forNormalizedPhrases: key)
        endingPruneRegexCache = RegexCache(key: key, regex: regex)
        return regex
    }

    private static func removalRegex(for words: [String]) -> NSRegularExpression? {
        removalRegex(forNormalizedWords: normalizedFilterWords(from: words))
    }

    private static func normalizedFilterWords(from words: [String]) -> [String] {
        words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted {
                if $0.count == $1.count {
                    return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
                return $0.count > $1.count
            }
    }

    private static func removalRegex(forNormalizedWords normalizedWords: [String]) -> NSRegularExpression? {
        guard !normalizedWords.isEmpty else {
            return nil
        }

        let alternation = normalizedWords
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let pattern = #"(?<![\p{L}\p{N}_])(?:\#(alternation))(?:,[\t ]+|\.[\t ]+|\.|[\t ]+)"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func endingPruneRegex(for phrases: [String]) -> NSRegularExpression? {
        endingPruneRegex(forNormalizedPhrases: normalizedPhrases(from: phrases))
    }

    private static func normalizedPhrases(from phrases: [String]) -> [String] {
        phrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func endingPruneRegex(forNormalizedPhrases phrases: [String]) -> NSRegularExpression? {
        guard !phrases.isEmpty else {
            return nil
        }

        let escaped = phrases.map(NSRegularExpression.escapedPattern(for:))
        let pattern = #"\b(?:\#(escaped.joined(separator: "|")))\.?\s*$"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func replaceMatches(in text: String, regex: NSRegularExpression) -> String {
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
    }

    private static func trimTrailingWhitespace(_ text: String) -> String {
        var endIndex = text.endIndex
        while endIndex > text.startIndex {
            let previousIndex = text.index(before: endIndex)
            guard text[previousIndex].unicodeScalars.allSatisfy({
                CharacterSet.whitespacesAndNewlines.contains($0)
            }) else {
                break
            }
            endIndex = previousIndex
        }
        return String(text[..<endIndex])
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
