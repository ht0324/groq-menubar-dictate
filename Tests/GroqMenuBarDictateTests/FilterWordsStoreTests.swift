import Foundation
import XCTest
@testable import GroqMenuBarDictate

final class FilterWordsStoreTests: XCTestCase {
    private var folderURL: URL!
    private var wordsURL: URL!
    private var phrasesURL: URL!
    private var store: FilterWordsStore!

    override func setUpWithError() throws {
        folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterWordsStoreTests-\(UUID().uuidString)", isDirectory: true)
        wordsURL = folderURL.appendingPathComponent("filter-words.txt")
        phrasesURL = folderURL.appendingPathComponent("end-prune-phrases.txt")
        store = FilterWordsStore(wordsFileURL: wordsURL, phrasesFileURL: phrasesURL)
        try store.ensureFilesExist()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folderURL)
    }

    func testApplyFiltersRemovesSpaceCommaAndPeriodVariants() throws {
        try "um\n".write(to: wordsURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(store.applyFilters(to: "um okay Um okay um, well um. done"), "okay okay well done")
    }

    func testApplyFiltersDoesNotRemoveEmbeddedSubstringsInsideWords() throws {
        try "um\n".write(to: wordsURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(store.applyFilters(to: "museum um done"), "museum done")
    }

    func testApplyFiltersPrefersLongerPhrasesWhenWordsOverlap() throws {
        try "uh\nuh huh\n".write(to: wordsURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(store.applyFilters(to: "uh huh okay uh done"), "okay done")
    }

    func testApplyFiltersTrimsTrailingWhitespace() {
        XCTAssertEqual(store.applyFilters(to: "good. \n"), "good.")
    }

    func testApplyFiltersRemovesTrailingSignoffCaseInsensitive() {
        XCTAssertEqual(store.applyFilters(to: "Here is the answer THANK YOU FOR WATCHING."), "Here is the answer")
    }

    func testApplyFiltersAllowsEmptyResult() {
        XCTAssertEqual(store.applyFilters(to: "thanks for watching"), "")
    }

    func testApplyFiltersUsesCustomPhrasesWithoutRestoringDefaults() throws {
        try "see ya\n".write(to: phrasesURL, atomically: true, encoding: .utf8)
        try store.ensureFilesExist()

        XCTAssertEqual(store.applyFilters(to: "That is all for now see ya."), "That is all for now")
        XCTAssertEqual(store.applyFilters(to: "That is all thank you."), "That is all thank you.")
    }

    func testApplyFiltersHonorsClearedPhrasesAfterCachedUseAndReopening() throws {
        try setPhraseModificationDate(100)
        XCTAssertEqual(store.applyFilters(to: "Hello thank you."), "Hello")

        try "# intentionally empty\n".write(to: phrasesURL, atomically: true, encoding: .utf8)
        try setPhraseModificationDate(200)
        XCTAssertEqual(store.applyFilters(to: "Hello thank you."), "Hello thank you.")

        let reopened = FilterWordsStore(wordsFileURL: wordsURL, phrasesFileURL: phrasesURL)
        try reopened.ensureFilesExist()
        XCTAssertEqual(reopened.applyFilters(to: "Hello thank you."), "Hello thank you.")
    }

    func testApplyFiltersPreservesPhrasesWhenFileIsUnavailable() throws {
        XCTAssertEqual(store.applyFilters(to: "Hello thank you."), "Hello")
        try FileManager.default.removeItem(at: phrasesURL)

        XCTAssertEqual(store.applyFilters(to: "Hello thank you."), "Hello thank you.")
    }

    func testApplyFiltersStillRemovesFilterWordsWhenEndPruningDisabled() throws {
        try "um\n".write(to: wordsURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(store.applyFilters(to: "um hello thank you. ", endPruneEnabled: false), "hello thank you.")
    }

    private func setPhraseModificationDate(_ timestamp: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: timestamp)],
            ofItemAtPath: phrasesURL.path
        )
    }
}
