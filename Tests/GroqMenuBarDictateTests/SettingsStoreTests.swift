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

    func testTapDebounceMillisecondsDefaultsTo250WhenUnset() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.tapDebounceMilliseconds, 250)
    }

    func testTapDebounceMillisecondsAllowsExplicitZero() {
        let store = SettingsStore(defaults: defaults)
        store.tapDebounceMilliseconds = 0
        XCTAssertEqual(store.tapDebounceMilliseconds, 0)
    }

    func testPerformanceDiagnosticsDisabledByDefault() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.performanceDiagnosticsEnabled)
    }

    func testPerformanceDiagnosticsPersistsExplicitToggle() {
        let store = SettingsStore(defaults: defaults)
        store.performanceDiagnosticsEnabled = true
        XCTAssertTrue(store.performanceDiagnosticsEnabled)
        store.performanceDiagnosticsEnabled = false
        XCTAssertFalse(store.performanceDiagnosticsEnabled)
    }

    func testMicrophoneInputModeDefaultsToAutomatic() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.microphoneInputMode, .automatic)
    }

    func testMicrophoneInputModePersistsSelectedValue() {
        let store = SettingsStore(defaults: defaults)
        store.microphoneInputMode = .macBookInternal
        XCTAssertEqual(store.microphoneInputMode, .macBookInternal)

        store.microphoneInputMode = .automatic
        XCTAssertEqual(store.microphoneInputMode, .automatic)
    }
}
