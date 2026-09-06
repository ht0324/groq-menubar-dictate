import CoreAudio
import XCTest
@testable import GroqMenuBarDictate

final class AudioInputDeviceCacheTests: XCTestCase {
    func testValidCachedDeviceSkipsRepeatedDiscovery() throws {
        let cache = AudioInputDeviceCache()
        let device = AudioDeviceInfo(id: 1, name: "Microphone", uid: "built-in", transportType: nil)
        var discoveries = 0
        let discover = { discoveries += 1; return device as AudioDeviceInfo? }

        XCTAssertEqual(cache.resolve(discover: discover, isValid: { _ in true }), 1)
        XCTAssertEqual(cache.resolve(discover: discover, isValid: { _ in true }), 1)
        XCTAssertEqual(discoveries, 1)
    }

    func testRecycledDeviceIDRequiresRediscoveryOfCorrectIdentity() {
        let cache = AudioInputDeviceCache()
        let original = AudioDeviceInfo(id: 1, name: nil, uid: "built-in", transportType: nil)
        _ = cache.resolve(discover: { original }, isValid: { _ in true })

        // CoreAudio has reassigned the old ID to a different input.
        let connectedUIDs: [AudioDeviceID: String] = [1: "usb-input", 2: "built-in"]
        let replacement = AudioDeviceInfo(id: 2, name: nil, uid: "built-in", transportType: nil)
        var discoveries = 0
        let result = cache.resolve(discover: {
            discoveries += 1
            return replacement
        }, isValid: { connectedUIDs[$0.id] == $0.uid })

        XCTAssertEqual(result, 2)
        XCTAssertEqual(discoveries, 1)
    }

    func testUnavailableDeviceDoesNotPreventLaterRecovery() {
        let cache = AudioInputDeviceCache()
        XCTAssertNil(cache.resolve(discover: { nil }, isValid: { _ in true }))
        let device = AudioDeviceInfo(id: 3, name: nil, uid: "built-in", transportType: nil)
        XCTAssertEqual(cache.resolve(discover: { device }, isValid: { _ in true }), 3)
        XCTAssertNil(cache.resolve(discover: { device }, isValid: { _ in false }))
        XCTAssertEqual(cache.resolve(discover: { device }, isValid: { _ in true }), 3)
    }

    func testDiscoveryFailureClearsStaleDeviceAndAllowsRetry() throws {
        let cache = AudioInputDeviceCache()
        let device = AudioDeviceInfo(id: 1, name: nil, uid: "built-in", transportType: nil)
        _ = cache.resolve(discover: { device }, isValid: { _ in true })
        struct DiscoveryError: Error {}
        XCTAssertThrowsError(try cache.resolve(discover: { throw DiscoveryError() }, isValid: { _ in false }))
        var discoveries = 0
        XCTAssertEqual(cache.resolve(discover: {
            discoveries += 1
            return device
        }, isValid: { _ in true }), 1)
        XCTAssertEqual(discoveries, 1)
    }
}
