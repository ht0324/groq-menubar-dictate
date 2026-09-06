import Foundation

final class FilterWordsStore {
    private struct RegexCache {
        let key: [String]
        let regex: NSRegularExpression?
    }

    private let lineList: LineListFileStore
    private let endPrunePhrases: LineListFileStore
    private var wordFilterRegexCache: RegexCache?
    private var endingPruneRegexCache: RegexCache?

    init(
        fileManager: FileManager = .default,
        wordsFileURL: URL? = nil,
        phrasesFileURL: URL? = nil
    ) {
        self.lineList = LineListFileStore(
            fileManager: fileManager,
            fileURL: wordsFileURL ?? LineListFileStore.appSupportFileURL(
                fileManager: fileManager,
                fileName: "filter-words.txt"
            ),
            initialContents: Self.initialFileContents
        )
        self.endPrunePhrases = LineListFileStore(
            fileManager: fileManager,
            fileURL: phrasesFileURL ?? LineListFileStore.appSupportFileURL(
                fileManager: fileManager,
                fileName: "end-prune-phrases.txt"
            ),
            initialContents: """
            # One end-prune phrase per line.
            # If transcript ends with one of these phrases (case-insensitive),
            # it is removed (with optional trailing period and spaces).
            # Remove all entries to leave trailing phrases unchanged.

            thank you
            thank you for watching
            thanks for watching

            """
        )
    }

    func ensureFilesExist() throws {
        try lineList.ensureFileExists()
        try endPrunePhrases.ensureFileExists()
    }

    func openWordsFile() throws {
        try lineList.openFile()
    }

    func openEndPrunePhrasesFile() throws {
        try endPrunePhrases.openFile()
    }

    func applyFilters(
        to text: String,
        endPruneEnabled: Bool = true
    ) -> String {
        let filterWords = lineList.loadEntries(limit: 200)
        let filtered = Self.applyWordFilters(to: text, regex: wordFilterRegex(for: filterWords))
        guard endPruneEnabled else {
            return Self.trimTrailingWhitespace(filtered)
        }
        let phrases = endPrunePhrases.loadEntries(limit: 100)
        return Self.applyEndingPruneRules(to: filtered, regex: endingPruneRegex(for: phrases))
    }

    private static func applyWordFilters(to text: String, regex: NSRegularExpression?) -> String {
        guard let regex else {
            return text
        }
        return replaceMatches(in: text, regex: regex)
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

    private static var initialFileContents: String {
        """
        # One filter term per line.
        # Commas inside a term stay part of that same term.
        # Matching removes term variants case-insensitively:
        # "<term> ", "<term>, ", "<term>. ", and "<term>."
        # Example: um -> removes "um ", "Um ", "um, ", "um."

        """
    }
}
