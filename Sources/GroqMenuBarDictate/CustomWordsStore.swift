import AppKit
import Foundation

final class CustomWordsStore {
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

    static let seedWords: [String] = [
        "Codex",
        "OpenClaw",
        "Hun Tae",
        "WHOOP",
        "claude",
        "Iris",
        "Groq",
        "cron job",
        "Miri",
        "SOUL.md",
        "USER.md",
        "AGENTS.md",
        "ElevenLabs",
        "skill",
    ]

    func ensureSeedFileExists() throws {
        let folder = wordsFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: wordsFileURL.path) else {
            return
        }
        let body = Self.seedWords.joined(separator: "\n") + "\n"
        try body.write(to: wordsFileURL, atomically: true, encoding: .utf8)
        cache = nil
    }

    func loadWords(limit: Int = 80) -> [String] {
        guard limit > 0 else {
            return []
        }

        let allWords = loadAllWords()
        if allWords.count <= limit {
            return allWords
        }
        return Array(allWords.prefix(limit))
    }

    func transcriptionPrompt(limit: Int = 80) -> String? {
        Self.transcriptionPrompt(from: loadWords(limit: limit))
    }

    static func transcriptionPrompt(from words: [String]) -> String? {
        guard !words.isEmpty else {
            return nil
        }
        return "Use exact spelling for these terms if spoken: \(words.joined(separator: ", "))."
    }

    func openWordsFile() throws {
        try ensureSeedFileExists()
        NSWorkspace.shared.open(wordsFileURL)
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

    private func fileModificationDate(for url: URL) -> Date? {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    private static func defaultWordsFileURL(fileManager: FileManager) -> URL {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupportURL
            .appendingPathComponent(AppConfig.appSupportFolderName, isDirectory: true)
            .appendingPathComponent("custom-words.txt", isDirectory: false)
    }
}
