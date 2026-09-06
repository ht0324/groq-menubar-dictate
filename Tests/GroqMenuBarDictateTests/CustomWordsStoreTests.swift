import XCTest
@testable import GroqMenuBarDictate

final class CustomWordsStoreTests: XCTestCase {
    func testSeedFileStartsWithoutCustomWords() throws {
        let fileManager = FileManager.default
        let tempFolder = fileManager.temporaryDirectory
            .appendingPathComponent("CustomWordsStoreSeedTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempFolder) }

        let wordsURL = tempFolder.appendingPathComponent("custom-words.txt", isDirectory: false)
        let store = CustomWordsStore(fileManager: fileManager, wordsFileURL: wordsURL)

        try store.ensureSeedFileExists()

        XCTAssertTrue(fileManager.fileExists(atPath: wordsURL.path))
        XCTAssertNil(store.transcriptionPrompt())
    }

    func testPromptUsesConfiguredWordsWithOriginalSpelling() throws {
        let wordsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CustomWordsStoreTests-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: wordsURL) }
        try "# names\nAcme\nacme\nWidget Pro\n".write(to: wordsURL, atomically: true, encoding: .utf8)

        let store = CustomWordsStore(wordsFileURL: wordsURL)

        XCTAssertEqual(
            store.transcriptionPrompt(),
            "Use exact spelling for these terms if spoken: Acme, Widget Pro."
        )
    }
}
