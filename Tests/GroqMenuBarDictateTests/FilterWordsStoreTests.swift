import XCTest
@testable import GroqMenuBarDictate

final class FilterWordsStoreTests: XCTestCase {
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

    func testApplyWordFiltersPrefersLongerPhrasesWhenWordsOverlap() {
        let output = FilterWordsStore.applyWordFilters(
            to: "uh huh okay uh done",
            words: ["uh", "uh huh"]
        )
        XCTAssertEqual(output, "okay done")
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
