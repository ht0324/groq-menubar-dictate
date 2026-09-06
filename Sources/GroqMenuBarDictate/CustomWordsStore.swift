import Foundation

final class CustomWordsStore {
    private let lineList: LineListFileStore

    init(fileManager: FileManager = .default, wordsFileURL: URL? = nil) {
        let resolvedURL = wordsFileURL ?? LineListFileStore.appSupportFileURL(
            fileManager: fileManager,
            fileName: "custom-words.txt"
        )
        self.lineList = LineListFileStore(
            fileManager: fileManager,
            fileURL: resolvedURL,
            initialContents: Self.initialFileContents
        )
    }

    func ensureSeedFileExists() throws {
        try lineList.ensureFileExists()
    }

    func transcriptionPrompt() -> String? {
        let words = lineList.loadEntries(limit: 80)
        guard !words.isEmpty else {
            return nil
        }
        return "Use exact spelling for these terms if spoken: \(words.joined(separator: ", "))."
    }

    func openWordsFile() throws {
        try lineList.openFile()
    }

    private static var initialFileContents: String {
        """
        # One custom word or phrase per line.
        # These entries are used as transcription spelling hints when spoken.

        """
    }
}
