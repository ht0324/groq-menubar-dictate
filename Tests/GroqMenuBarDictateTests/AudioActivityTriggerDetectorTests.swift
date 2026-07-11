import Foundation
import XCTest
@testable import GroqMenuBarDictate

final class AudioActivityTriggerDetectorTests: XCTestCase {
    private let sampleRate = 16_000
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

    func testMarkerFallbackStopsDespitePeriodicBriefLoudBlips() {
        var testConfiguration = configuration
        testConfiguration.markerFallbackStopHoldSeconds = 1.0
        var detector = AudioActivityTriggerDetector(configuration: testConfiguration)

        XCTAssertEqual(processMarker(frequency: 6_000, timestamp: 0.03, detector: &detector), .started)
        XCTAssertNil(detector.process(levelDBFS: -80, timestamp: 0.10))
        XCTAssertNil(detector.process(levelDBFS: -24, timestamp: 0.30))
        XCTAssertNil(detector.process(levelDBFS: -80, timestamp: 0.31))
        XCTAssertNil(detector.process(levelDBFS: -24, timestamp: 0.50))
        XCTAssertNil(detector.process(levelDBFS: -80, timestamp: 0.51))
        XCTAssertNil(detector.process(levelDBFS: -24, timestamp: 0.70))
        XCTAssertNil(detector.process(levelDBFS: -80, timestamp: 0.71))
        XCTAssertNil(detector.process(levelDBFS: -24, timestamp: 0.90))
        XCTAssertNil(detector.process(levelDBFS: -80, timestamp: 0.91))
        XCTAssertNil(detector.process(levelDBFS: -80, timestamp: 1.09))
        XCTAssertEqual(detector.process(levelDBFS: -80, timestamp: 1.11), .stopped)
        XCTAssertNil(detector.lastStopMarker)
    }

    func testMarkerFallbackSustainedLoudRunResetsQuietHold() {
        var testConfiguration = configuration
        testConfiguration.markerFallbackStopHoldSeconds = 1.0
        var detector = AudioActivityTriggerDetector(configuration: testConfiguration)

        XCTAssertEqual(processMarker(frequency: 6_000, timestamp: 0.03, detector: &detector), .started)
        XCTAssertNil(detector.process(levelDBFS: -80, timestamp: 0.10))
        for timestamp in [0.40, 0.46, 0.52, 0.58, 0.64, 0.66] {
            XCTAssertNil(detector.process(levelDBFS: -24, timestamp: timestamp))
        }
        XCTAssertNil(detector.process(levelDBFS: -80, timestamp: 0.67))
        XCTAssertNil(detector.process(levelDBFS: -80, timestamp: 1.20))
        XCTAssertNil(detector.process(levelDBFS: -80, timestamp: 1.66))
        XCTAssertEqual(detector.process(levelDBFS: -80, timestamp: 1.68), .stopped)
    }

    private func processMarker(
        frequency: Double,
        timestamp: TimeInterval,
        startingAtSampleIndex sampleIndex: Int = 0,
        detector: inout AudioActivityTriggerDetector
    ) -> AudioActivityTriggerEvent? {
        detector.process(
            pcm16: markerData(frequency: frequency),
            levelDBFS: -24,
            timestamp: timestamp,
            startingAtSampleIndex: sampleIndex
        )
    }

    private func markerData(frequency: Double) -> Data {
        let sampleCount = Int(0.030 * Double(sampleRate))
        var data = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let phase = 2.0 * Double.pi * frequency * Double(index) / Double(sampleRate)
            var sample = Int16(clamping: Int((0.30 * sin(phase) * 32_767.0).rounded()))
            sample = sample.littleEndian
            withUnsafeBytes(of: sample) { data.append(contentsOf: $0) }
        }
        return data
    }
}
