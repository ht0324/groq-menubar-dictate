import AppKit
import Foundation

final class LineListFileStore {
    private struct EntriesCache {
        let modificationDate: Date?
        let entries: [String]
    }

    private let fileManager: FileManager
    private let initialContents: String
    private let emptyFallbackEntries: [String]
    private var cache: EntriesCache?

    let fileURL: URL

    init(
        fileManager: FileManager = .default,
        fileURL: URL,
        initialContents: String,
        emptyFallbackEntries: [String] = []
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL
        self.initialContents = initialContents
        self.emptyFallbackEntries = emptyFallbackEntries
    }

    func ensureFileExists() throws {
        let folder = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try initialContents.write(to: fileURL, atomically: true, encoding: .utf8)
        cache = nil
    }

    func openFile() throws {
        try ensureFileExists()
        NSWorkspace.shared.open(fileURL)
    }

    func loadEntries(limit: Int) -> [String] {
        guard limit > 0 else {
            return []
        }

        let allEntries = loadAllEntries()
        if allEntries.count <= limit {
            return allEntries
        }
        return Array(allEntries.prefix(limit))
    }

    static func parseEntries(from raw: String, limit: Int) -> [String] {
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

    static func appSupportFileURL(fileManager: FileManager, fileName: String) -> URL {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupportURL
            .appendingPathComponent(AppConfig.appSupportFolderName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func loadAllEntries() -> [String] {
        let modificationDate = fileModificationDate(for: fileURL)
        if let cache, cache.modificationDate == modificationDate {
            return cache.entries
        }

        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            cache = EntriesCache(modificationDate: modificationDate, entries: emptyFallbackEntries)
            return emptyFallbackEntries
        }

        let parsed = Self.parseEntries(from: raw, limit: Int.max)
        let entries = parsed.isEmpty ? emptyFallbackEntries : parsed
        cache = EntriesCache(modificationDate: modificationDate, entries: entries)
        return entries
    }

    private func fileModificationDate(for url: URL) -> Date? {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}
