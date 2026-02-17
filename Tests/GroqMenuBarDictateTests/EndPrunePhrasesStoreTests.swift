import XCTest
@testable import GroqMenuBarDictate

final class EndPrunePhrasesStoreTests: XCTestCase {
    func testParsePhrasesIgnoresCommentsAndDedupesCaseInsensitive() {
        let raw = """
        # comment
        thank you
        Thank You
        see ya
        """
        let parsed = EndPrunePhrasesStore.parsePhrases(from: raw, limit: 20)
        XCTAssertEqual(parsed, ["thank you", "see ya"])
    }

    func testLoadPhrasesReloadsWhenFileModificationDateChanges() throws {
        let fileManager = FileManager.default
        let tempFolder = fileManager.temporaryDirectory
            .appendingPathComponent("EndPrunePhrasesStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempFolder) }

        let phrasesURL = tempFolder.appendingPathComponent("end-prune-phrases.txt", isDirectory: false)
        try "thanks for watching\n".write(to: phrasesURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: phrasesURL.path)

        let store = EndPrunePhrasesStore(fileManager: fileManager, phrasesFileURL: phrasesURL)
        XCTAssertEqual(store.loadPhrases(limit: 10), ["thanks for watching"])

        try "see ya\n".write(to: phrasesURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: phrasesURL.path)

        XCTAssertEqual(store.loadPhrases(limit: 10), ["see ya"])
    }
}
