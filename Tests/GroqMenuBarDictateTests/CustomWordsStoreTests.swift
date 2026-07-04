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

        XCTAssertEqual(store.loadWords(limit: 10), [])
    }
}
