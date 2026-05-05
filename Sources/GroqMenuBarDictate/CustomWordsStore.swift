import Foundation

final class CustomWordsStore {
    private let lineList: LineListFileStore
    let wordsFileURL: URL

    init(fileManager: FileManager = .default, wordsFileURL: URL? = nil) {
        let resolvedURL = wordsFileURL ?? LineListFileStore.appSupportFileURL(
            fileManager: fileManager,
            fileName: "custom-words.txt"
        )
        self.wordsFileURL = resolvedURL
        self.lineList = LineListFileStore(
            fileManager: fileManager,
            fileURL: resolvedURL,
            initialContents: Self.seedWords.joined(separator: "\n") + "\n"
        )
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
        try lineList.ensureFileExists()
    }

    func loadWords(limit: Int = 80) -> [String] {
        lineList.loadEntries(limit: limit)
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
        try lineList.openFile()
    }

    static func parseWords(from raw: String, limit: Int) -> [String] {
        LineListFileStore.parseEntries(from: raw, limit: limit)
    }
}
