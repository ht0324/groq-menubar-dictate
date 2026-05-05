import Foundation

final class EndPrunePhrasesStore {
    private let lineList: LineListFileStore
    let phrasesFileURL: URL

    static let defaultPhrases: [String] = [
        "thank you",
        "thank you for watching",
        "thanks for watching",
    ]

    init(fileManager: FileManager = .default, phrasesFileURL: URL? = nil) {
        let resolvedURL = phrasesFileURL ?? LineListFileStore.appSupportFileURL(
            fileManager: fileManager,
            fileName: "end-prune-phrases.txt"
        )
        self.phrasesFileURL = resolvedURL
        self.lineList = LineListFileStore(
            fileManager: fileManager,
            fileURL: resolvedURL,
            initialContents: Self.initialFileContents,
            emptyFallbackEntries: Self.defaultPhrases
        )
    }

    func ensureFileExists() throws {
        try lineList.ensureFileExists()
    }

    func openPhrasesFile() throws {
        try lineList.openFile()
    }

    func loadPhrases(limit: Int = 100) -> [String] {
        lineList.loadEntries(limit: limit)
    }

    static func parsePhrases(from raw: String, limit: Int) -> [String] {
        LineListFileStore.parseEntries(from: raw, limit: limit)
    }

    private static var initialFileContents: String {
        let header = """
        # One end-prune phrase per line.
        # If transcript ends with one of these phrases (case-insensitive),
        # it is removed (with optional trailing period and spaces).
        """
        return ([
            header,
            "",
            Self.defaultPhrases.joined(separator: "\n"),
            "",
        ]).joined(separator: "\n")
    }
}
