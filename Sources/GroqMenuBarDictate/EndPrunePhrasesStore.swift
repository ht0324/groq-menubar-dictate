import AppKit
import Foundation

final class EndPrunePhrasesStore {
    private struct PhrasesCache {
        let modificationDate: Date?
        let phrases: [String]
    }

    private let fileManager: FileManager
    let phrasesFileURL: URL
    private var cache: PhrasesCache?

    static let defaultPhrases: [String] = [
        "thank you",
        "thank you for watching",
        "thanks for watching",
    ]

    init(fileManager: FileManager = .default, phrasesFileURL: URL? = nil) {
        self.fileManager = fileManager
        self.phrasesFileURL = phrasesFileURL ?? Self.defaultPhrasesFileURL(fileManager: fileManager)
    }

    func ensureFileExists() throws {
        let folder = phrasesFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: phrasesFileURL.path) else {
            return
        }

        let header = """
        # One end-prune phrase per line.
        # If transcript ends with one of these phrases (case-insensitive),
        # it is removed (with optional trailing period and spaces).
        """
        let body = ([
            header,
            "",
            Self.defaultPhrases.joined(separator: "\n"),
            "",
        ]).joined(separator: "\n")
        try body.write(to: phrasesFileURL, atomically: true, encoding: .utf8)
        cache = nil
    }

    func openPhrasesFile() throws {
        try ensureFileExists()
        NSWorkspace.shared.open(phrasesFileURL)
    }

    func loadPhrases(limit: Int = 100) -> [String] {
        guard limit > 0 else {
            return []
        }

        let allPhrases = loadAllPhrases()
        if allPhrases.count <= limit {
            return allPhrases
        }
        return Array(allPhrases.prefix(limit))
    }

    static func parsePhrases(from raw: String, limit: Int) -> [String] {
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

    private func loadAllPhrases() -> [String] {
        let modificationDate = fileModificationDate(for: phrasesFileURL)
        if let cache, cache.modificationDate == modificationDate {
            return cache.phrases
        }

        guard let raw = try? String(contentsOf: phrasesFileURL, encoding: .utf8) else {
            let fallback = Self.defaultPhrases
            cache = PhrasesCache(modificationDate: modificationDate, phrases: fallback)
            return fallback
        }

        let parsed = Self.parsePhrases(from: raw, limit: Int.max)
        let resolved = parsed.isEmpty ? Self.defaultPhrases : parsed
        cache = PhrasesCache(modificationDate: modificationDate, phrases: resolved)
        return resolved
    }

    private static func defaultPhrasesFileURL(fileManager: FileManager) -> URL {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupportURL
            .appendingPathComponent(AppConfig.appSupportFolderName, isDirectory: true)
            .appendingPathComponent("end-prune-phrases.txt", isDirectory: false)
    }

    private func fileModificationDate(for url: URL) -> Date? {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}
