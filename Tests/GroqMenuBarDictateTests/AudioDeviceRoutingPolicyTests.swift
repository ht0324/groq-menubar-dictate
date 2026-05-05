import CoreAudio
import XCTest
@testable import GroqMenuBarDictate

final class AudioDeviceRoutingPolicyTests: XCTestCase {
    func testShouldAvoidAutomaticActivationForBluetoothTransport() {
        XCTAssertTrue(
            AudioDeviceRoutingPolicy.shouldAvoidAutomaticActivation(
                name: "Headphones",
                uid: "headphones-input",
                transportType: kAudioDeviceTransportTypeBluetooth
            )
        )
    }

    func testShouldAvoidAutomaticActivationForAirPodsNameFallback() {
        XCTAssertTrue(
            AudioDeviceRoutingPolicy.shouldAvoidAutomaticActivation(
                name: "Hun Tae's AirPods Pro",
                uid: "BC-80-4E-EF-61-DF:input",
                transportType: nil
            )
        )
    }

    func testShouldAllowBuiltInAudioDevices() {
        XCTAssertFalse(
            AudioDeviceRoutingPolicy.shouldAvoidAutomaticActivation(
                name: "MacBook Pro Microphone",
                uid: "BuiltInMicrophoneDevice",
                transportType: nil
            )
        )
    }
}
