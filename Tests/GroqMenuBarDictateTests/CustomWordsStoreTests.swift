import XCTest
@testable import GroqMenuBarDictate

final class CustomWordsStoreTests: XCTestCase {
    func testParseWordsRemovesCommentsAndDedupesCaseInsensitively() {
        let raw = """
        # comment
        Codex
        codex
        OpenClaw

        Hun Tae
        # another
        """
        let parsed = CustomWordsStore.parseWords(from: raw, limit: 80)
        XCTAssertEqual(parsed, ["Codex", "OpenClaw", "Hun Tae"])
    }

    func testParseWordsRespectsLimit() {
        let raw = """
        one
        two
        three
        four
        """
        let parsed = CustomWordsStore.parseWords(from: raw, limit: 2)
        XCTAssertEqual(parsed, ["one", "two"])
    }

    func testLoadWordsReloadsWhenFileModificationDateChanges() throws {
        let fileManager = FileManager.default
        let tempFolder = fileManager.temporaryDirectory
            .appendingPathComponent("CustomWordsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempFolder) }

        let wordsURL = tempFolder.appendingPathComponent("custom-words.txt", isDirectory: false)
        try "alpha\n".write(to: wordsURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: wordsURL.path)

        let store = CustomWordsStore(fileManager: fileManager, wordsFileURL: wordsURL)
        XCTAssertEqual(store.loadWords(limit: 10), ["alpha"])

        try "beta\n".write(to: wordsURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: wordsURL.path)

        XCTAssertEqual(store.loadWords(limit: 10), ["beta"])
    }
}
