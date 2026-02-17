import XCTest
@testable import GroqMenuBarDictate

final class FilterWordsStoreTests: XCTestCase {
    func testParseWordsIgnoresCommentsAndDedupesCaseInsensitive() {
        let raw = """
        # comment
        cat
        CAT
        dog
        """
        let parsed = FilterWordsStore.parseWords(from: raw, limit: 50)
        XCTAssertEqual(parsed, ["cat", "dog"])
    }

    func testApplyWordFiltersRemovesSpaceCommaAndPeriodVariants() {
        let output = FilterWordsStore.applyWordFilters(
            to: "um okay Um okay um, well um. done",
            words: ["um"]
        )
        XCTAssertEqual(output, "okay okay well done")
    }

    func testApplyWordFiltersDoesNotRemoveEmbeddedSubstringsInsideWords() {
        let output = FilterWordsStore.applyWordFilters(
            to: "museum um done",
            words: ["um"]
        )
        XCTAssertEqual(output, "museum done")
    }

    func testLoadWordsReloadsWhenFileModificationDateChanges() throws {
        let fileManager = FileManager.default
        let tempFolder = fileManager.temporaryDirectory
            .appendingPathComponent("FilterWordsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempFolder) }

        let wordsURL = tempFolder.appendingPathComponent("filter-words.txt", isDirectory: false)
        try "um\n".write(to: wordsURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: wordsURL.path)

        let store = FilterWordsStore(fileManager: fileManager, wordsFileURL: wordsURL)
        XCTAssertEqual(store.loadWords(limit: 10), ["um"])

        try "uh\n".write(to: wordsURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: wordsURL.path)

        XCTAssertEqual(store.loadWords(limit: 10), ["uh"])
    }

    func testApplyEndingPruneRulesTrimsTrailingWhitespace() {
        let output = FilterWordsStore.applyEndingPruneRules(to: "good. ")
        XCTAssertEqual(output, "good.")
    }

    func testApplyEndingPruneRulesRemovesTrailingSignoffCaseInsensitive() {
        let output = FilterWordsStore.applyEndingPruneRules(to: "Here is the answer THANK YOU FOR WATCHING.")
        XCTAssertEqual(output, "Here is the answer")
    }

    func testApplyEndingPruneRulesAllowsEmptyResult() {
        let output = FilterWordsStore.applyEndingPruneRules(to: "thanks for watching")
        XCTAssertEqual(output, "")
    }

    func testApplyEndingPruneRulesSupportsCustomPhraseList() {
        let output = FilterWordsStore.applyEndingPruneRules(
            to: "That is all for now see ya.",
            phrases: ["see ya"]
        )
        XCTAssertEqual(output, "That is all for now")
    }
}
