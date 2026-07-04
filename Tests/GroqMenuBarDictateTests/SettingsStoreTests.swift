import Foundation
import XCTest
@testable import GroqMenuBarDictate

final class SettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testDefaultsForUserFacingSettings() {
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.tapDebounceMilliseconds, 250)
        XCTAssertFalse(store.performanceDiagnosticsEnabled)
        XCTAssertEqual(store.microphoneInputMode, .automatic)
        XCTAssertEqual(store.optionKeyMode, .any)
        XCTAssertEqual(store.typingWordsPerMinute, 0)
    }

    func testPersistsNonDefaultUserFacingSettings() {
        let store = SettingsStore(defaults: defaults)

        store.tapDebounceMilliseconds = 0
        store.performanceDiagnosticsEnabled = true
        store.microphoneInputMode = .macBookInternal
        store.optionKeyMode = .right
        store.typingWordsPerMinute = 72

        let reloadedStore = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.tapDebounceMilliseconds, 0)
        XCTAssertTrue(reloadedStore.performanceDiagnosticsEnabled)
        XCTAssertEqual(reloadedStore.microphoneInputMode, .macBookInternal)
        XCTAssertEqual(reloadedStore.optionKeyMode, .right)
        XCTAssertEqual(reloadedStore.typingWordsPerMinute, 72)
    }
}
