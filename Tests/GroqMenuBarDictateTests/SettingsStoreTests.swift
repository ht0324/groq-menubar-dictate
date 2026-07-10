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
        XCTAssertFalse(store.audioActivityTriggerEnabled)
        XCTAssertFalse(store.audioTriggerRawDumpEnabled)
        XCTAssertEqual(store.microphoneInputMode, .automatic)
        XCTAssertEqual(store.optionKeyMode, .any)
        XCTAssertEqual(store.typingWordsPerMinute, 0)
    }

    func testPersistsNonDefaultUserFacingSettings() {
        let store = SettingsStore(defaults: defaults)

        store.tapDebounceMilliseconds = 0
        store.performanceDiagnosticsEnabled = true
        store.audioActivityTriggerEnabled = true
        store.audioTriggerRawDumpEnabled = true
        store.microphoneInputMode = .cableCreation
        store.optionKeyMode = .right
        store.typingWordsPerMinute = 72

        let reloadedStore = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.tapDebounceMilliseconds, 0)
        XCTAssertTrue(reloadedStore.performanceDiagnosticsEnabled)
        XCTAssertTrue(reloadedStore.audioActivityTriggerEnabled)
        XCTAssertTrue(reloadedStore.audioTriggerRawDumpEnabled)
        XCTAssertEqual(reloadedStore.microphoneInputMode, .cableCreation)
        XCTAssertEqual(reloadedStore.optionKeyMode, .right)
        XCTAssertEqual(reloadedStore.typingWordsPerMinute, 72)
    }

    func testAudioTriggerConfigurationUsesDefaultsUntilOverridden() {
        let store = SettingsStore(defaults: defaults)
        let baseline = AudioActivityTriggerConfiguration()

        var configuration = store.audioActivityTriggerConfiguration
        XCTAssertEqual(configuration.startThresholdDBFS, baseline.startThresholdDBFS)
        XCTAssertEqual(configuration.stopThresholdDBFS, baseline.stopThresholdDBFS)
        XCTAssertEqual(configuration.stopHoldSeconds, baseline.stopHoldSeconds)
        XCTAssertEqual(configuration.preRollSeconds, baseline.preRollSeconds)

        defaults.set(-64.5, forKey: "settings.audioTriggerStartThresholdDBFS")
        defaults.set(-77.0, forKey: "settings.audioTriggerStopThresholdDBFS")
        defaults.set(0.5, forKey: "settings.audioTriggerStopHoldSeconds")
        defaults.set(1.0, forKey: "settings.audioTriggerPreRollSeconds")

        configuration = store.audioActivityTriggerConfiguration
        XCTAssertEqual(configuration.startThresholdDBFS, -64.5)
        XCTAssertEqual(configuration.stopThresholdDBFS, -77.0)
        XCTAssertEqual(configuration.stopHoldSeconds, 0.5)
        XCTAssertEqual(configuration.preRollSeconds, 1.0)
    }

    func testAudioTriggerConfigurationClampsBadOverrides() {
        let store = SettingsStore(defaults: defaults)

        defaults.set(50.0, forKey: "settings.audioTriggerStartThresholdDBFS")
        defaults.set(-10.0, forKey: "settings.audioTriggerStopThresholdDBFS")
        defaults.set(-1.0, forKey: "settings.audioTriggerStopHoldSeconds")
        defaults.set(120.0, forKey: "settings.audioTriggerPreRollSeconds")

        let configuration = store.audioActivityTriggerConfiguration
        XCTAssertEqual(configuration.startThresholdDBFS, 0)
        // Stop is capped at the start threshold to preserve hysteresis.
        XCTAssertEqual(configuration.stopThresholdDBFS, -10.0)
        XCTAssertEqual(configuration.stopHoldSeconds, 0.05)
        XCTAssertEqual(configuration.preRollSeconds, 5.0)

        defaults.set(-90.0, forKey: "settings.audioTriggerStartThresholdDBFS")
        XCTAssertEqual(store.audioActivityTriggerConfiguration.stopThresholdDBFS, -90.0)
    }
}
