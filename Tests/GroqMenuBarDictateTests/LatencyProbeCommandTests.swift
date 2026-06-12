import XCTest
@testable import GroqMenuBarDictate

final class LatencyProbeCommandTests: XCTestCase {
    func testShouldRunWhenLatencyProbeFlagIsPresent() {
        XCTAssertTrue(
            LatencyProbeCommand.shouldRun(
                arguments: ["groq-menubar-dictate", "--latency-probe", "/tmp/sample.m4a"]
            )
        )
    }

    func testShouldNotRunWithoutLatencyProbeFlag() {
        XCTAssertFalse(
            LatencyProbeCommand.shouldRun(
                arguments: ["groq-menubar-dictate"]
            )
        )
    }
}
