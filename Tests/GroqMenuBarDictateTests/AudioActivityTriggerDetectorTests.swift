import XCTest
@testable import GroqMenuBarDictate

final class AudioActivityTriggerDetectorTests: XCTestCase {
    private let configuration = AudioActivityTriggerConfiguration(
        startThresholdDBFS: -60,
        stopThresholdDBFS: -68,
        startHoldSeconds: 0.1,
        stopHoldSeconds: 0.4,
        minimumActiveSeconds: 0.5
    )

    func testDoesNotStartForQuietSignal() {
        var detector = AudioActivityTriggerDetector(configuration: configuration)

        XCTAssertNil(detector.process(levelDBFS: -80, timestamp: 0))
        XCTAssertNil(detector.process(levelDBFS: -75, timestamp: 1))
        XCTAssertFalse(detector.isActive)
    }

    func testStartsAfterSustainedLoudSignal() {
        var detector = AudioActivityTriggerDetector(configuration: configuration)

        XCTAssertNil(detector.process(levelDBFS: -50, timestamp: 0))
        XCTAssertNil(detector.process(levelDBFS: -50, timestamp: 0.05))
        XCTAssertEqual(detector.process(levelDBFS: -50, timestamp: 0.11), .started)
        XCTAssertTrue(detector.isActive)
    }

    func testTransientLoudSignalDoesNotStart() {
        var detector = AudioActivityTriggerDetector(configuration: configuration)

        XCTAssertNil(detector.process(levelDBFS: -50, timestamp: 0))
        XCTAssertNil(detector.process(levelDBFS: -80, timestamp: 0.05))
        XCTAssertNil(detector.process(levelDBFS: -50, timestamp: 0.11))
        XCTAssertFalse(detector.isActive)
    }

    func testStopsAfterSustainedQuietSignal() {
        var detector = AudioActivityTriggerDetector(configuration: configuration)

        XCTAssertNil(detector.process(levelDBFS: -50, timestamp: 0))
        XCTAssertEqual(detector.process(levelDBFS: -50, timestamp: 0.11), .started)
        XCTAssertNil(detector.process(levelDBFS: -75, timestamp: 0.3))
        XCTAssertNil(detector.process(levelDBFS: -75, timestamp: 0.6))
        XCTAssertEqual(detector.process(levelDBFS: -75, timestamp: 0.72), .stopped)
        XCTAssertFalse(detector.isActive)
    }

    func testQuietTimerResetsWhenSignalReturns() {
        var detector = AudioActivityTriggerDetector(configuration: configuration)

        XCTAssertNil(detector.process(levelDBFS: -50, timestamp: 0))
        XCTAssertEqual(detector.process(levelDBFS: -50, timestamp: 0.11), .started)
        XCTAssertNil(detector.process(levelDBFS: -75, timestamp: 0.3))
        XCTAssertNil(detector.process(levelDBFS: -50, timestamp: 0.5))
        XCTAssertNil(detector.process(levelDBFS: -75, timestamp: 0.6))
        XCTAssertNil(detector.process(levelDBFS: -75, timestamp: 0.9))
        XCTAssertEqual(detector.process(levelDBFS: -75, timestamp: 1.01), .stopped)
    }

    func testHysteresisKeepsActiveBetweenThresholds() {
        var detector = AudioActivityTriggerDetector(configuration: configuration)

        XCTAssertNil(detector.process(levelDBFS: -50, timestamp: 0))
        XCTAssertEqual(detector.process(levelDBFS: -50, timestamp: 0.11), .started)
        XCTAssertNil(detector.process(levelDBFS: -64, timestamp: 1.0))
        XCTAssertTrue(detector.isActive)
    }
}
