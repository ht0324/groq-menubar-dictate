import XCTest
@testable import GroqMenuBarDictate

final class AppVersionInfoTests: XCTestCase {
    func testMenuTitleUsesStampedDisplayVersion() {
        let info = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "GMDGitCommit": "1234567890abcdef",
            "GMDGitDirty": true,
            "GMDVersionDisplay": "v1.2.3 build 42 (1234567890, dirty)",
        ])

        XCTAssertEqual(info.menuTitle, "Version v1.2.3 build 42 (1234567890, dirty)")
    }

    func testDisplayTextFallsBackToBundleAndCommitFields() {
        let info = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "GMDGitCommit": "1234567890abcdef",
            "GMDGitDirty": true,
        ])

        XCTAssertEqual(info.menuTitle, "Version 1.2.3 (42) 1234567890 dirty")
    }

    func testDisplayTextAcceptsStringDirtyFlag() {
        let info = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "GMDGitCommit": "1234567890abcdef",
            "GMDGitDirty": "yes",
        ])

        XCTAssertEqual(info.displayText, "1.2.3 (42) 1234567890 dirty")
    }

    func testDisplayTextFallsBackForSourceRuns() {
        let info = AppVersionInfo(infoDictionary: [:])

        XCTAssertEqual(info.menuTitle, "Version source run")
    }
}
