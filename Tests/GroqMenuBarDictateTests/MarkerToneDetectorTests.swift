import Foundation
import XCTest
@testable import GroqMenuBarDictate

final class MarkerToneDetectorTests: XCTestCase {
    private let sampleRate = 16_000

    func testDetectsPureStartAndStopMarkers() {
        var samples = [Double](repeating: 0, count: sampleRate)
        let startOffset = 1_600
        let stopOffset = 8_000
        renderMarker(into: &samples, at: startOffset, frequency: 6_000, amplitude: 0.30)
        renderMarker(into: &samples, at: stopOffset, frequency: 7_000, amplitude: 0.30)

        let events = detectMarkers(in: pcmData(from: samples), chunkSize: 257)
        let startEvents = events.filter { $0.kind == .start }
        let stopEvents = events.filter { $0.kind == .stop }

        XCTAssertEqual(startEvents.count, 1, "\(events)")
        XCTAssertEqual(stopEvents.count, 1, "\(events)")
        XCTAssertLessThanOrEqual(abs(startEvents[0].sampleIndex - startOffset), sampleRate / 100)
        XCTAssertLessThanOrEqual(abs(stopEvents[0].sampleIndex - stopOffset), sampleRate / 100)
        XCTAssertGreaterThan(startEvents[0].purity, 0.9)
        XCTAssertGreaterThan(stopEvents[0].purity, 0.9)
    }

    func testDetectsMarkersMixedIntoSpeechLikeNoiseAtMeasuredAmplitudes() {
        var samples = speechLikeAudio(durationSeconds: 2.0, seed: 101)
        let startOffset = Int(0.503 * Double(sampleRate))
        let stopOffset = Int(1.347 * Double(sampleRate))
        renderMarker(into: &samples, at: startOffset, frequency: 6_000, amplitude: 0.26)
        renderMarker(into: &samples, at: stopOffset, frequency: 7_000, amplitude: 0.41)

        let events = detectMarkers(in: pcmData(from: samples), chunkSize: 257)
        let startEvents = events.filter { $0.kind == .start }
        let stopEvents = events.filter { $0.kind == .stop }

        XCTAssertEqual(startEvents.count, 1, "\(events)")
        XCTAssertEqual(stopEvents.count, 1, "\(events)")
        XCTAssertLessThanOrEqual(abs(startEvents[0].sampleIndex - startOffset), sampleRate / 100)
        XCTAssertLessThanOrEqual(abs(stopEvents[0].sampleIndex - stopOffset), sampleRate / 100)
    }

    func testNoFalsePositivesOnSixtySecondsOfSpeechLikeNoise() {
        let samples = speechLikeAudio(durationSeconds: 60.0, seed: 202)
        let events = detectMarkers(in: pcmData(from: samples), chunkSize: 257)

        XCTAssertEqual(events, [])
    }

    func testDebounceYieldsOneEventPerBurst() {
        var samples = [Double](repeating: 0, count: sampleRate / 2)
        renderMarker(into: &samples, at: 1_600, frequency: 6_000, amplitude: 0.35)

        let events = detectMarkers(in: pcmData(from: samples), chunkSize: 53)

        XCTAssertEqual(events.filter { $0.kind == .start }.count, 1, "\(events)")
    }

    func testStopMarkerEndsActivityWithoutWaitingForStopHold() {
        var markerConfiguration = MarkerToneDetector.Configuration()
        markerConfiguration.minimumRMS = 0.02
        let configuration = AudioActivityTriggerConfiguration(
            startThresholdDBFS: -20,
            stopThresholdDBFS: -90,
            startHoldSeconds: 0.5,
            stopHoldSeconds: 5.0,
            minimumActiveSeconds: 0.3,
            preRollSeconds: 0.6,
            maxUtteranceSeconds: 300,
            markerToneConfiguration: markerConfiguration
        )
        var detector = AudioActivityTriggerDetector(configuration: configuration)

        let startMarker = markerData(frequency: 6_000, amplitude: 0.30)
        let startLevel = AudioActivityCaptureService.levelDBFS(pcm16: startMarker)!
        XCTAssertEqual(
            detector.process(
                pcm16: startMarker,
                levelDBFS: startLevel,
                timestamp: 0.03,
                startingAtSampleIndex: 0
            ),
            .started
        )
        XCTAssertEqual(detector.activeStartMarker?.kind, .start)

        let speech = pcmData(from: speechLikeAudio(durationSeconds: 0.2, seed: 303))
        let speechLevel = AudioActivityCaptureService.levelDBFS(pcm16: speech)!
        XCTAssertNil(
            detector.process(
                pcm16: speech,
                levelDBFS: speechLevel,
                timestamp: 0.23,
                startingAtSampleIndex: startMarker.count / 2
            )
        )

        let stopStartSample = (startMarker.count + speech.count) / 2
        let stopMarker = markerData(frequency: 7_000, amplitude: 0.30)
        let stopLevel = AudioActivityCaptureService.levelDBFS(pcm16: stopMarker)!
        XCTAssertLessThan(0.26, configuration.minimumActiveSeconds)
        XCTAssertGreaterThan(stopLevel, configuration.stopThresholdDBFS)
        XCTAssertEqual(
            detector.process(
                pcm16: stopMarker,
                levelDBFS: stopLevel,
                timestamp: 0.26,
                startingAtSampleIndex: stopStartSample
            ),
            .stopped
        )
        XCTAssertFalse(detector.isActive)
        XCTAssertEqual(detector.lastStopMarker?.kind, .stop)
    }

    func testMidSqueezePauseDoesNotSplitClipStartedWithMarker() {
        var markerConfiguration = MarkerToneDetector.Configuration()
        markerConfiguration.minimumRMS = 0.02
        var configuration = AudioActivityTriggerConfiguration(
            startThresholdDBFS: -20,
            stopThresholdDBFS: -76,
            startHoldSeconds: 5.0,
            stopHoldSeconds: 0.22,
            minimumActiveSeconds: 0,
            preRollSeconds: 0.6,
            maxUtteranceSeconds: 300,
            markerToneConfiguration: markerConfiguration
        )
        configuration.markerFallbackStopHoldSeconds = 2.0
        var detector = AudioActivityTriggerDetector(configuration: configuration)

        let startMarker = markerData(frequency: 6_000, amplitude: 0.30)
        let startLevel = AudioActivityCaptureService.levelDBFS(pcm16: startMarker)!
        XCTAssertEqual(
            detector.process(
                pcm16: startMarker,
                levelDBFS: startLevel,
                timestamp: 0.03,
                startingAtSampleIndex: 0
            ),
            .started
        )

        // A thinking pause far beyond the 0.22s level hold must NOT stop the
        // clip while the start marker proved the firmware is emitting markers.
        XCTAssertNil(detector.process(levelDBFS: -90, timestamp: 0.30))
        XCTAssertNil(detector.process(levelDBFS: -90, timestamp: 0.60))
        XCTAssertNil(detector.process(levelDBFS: -90, timestamp: 1.50))
        XCTAssertTrue(detector.isActive)

        // The extended fallback still rescues a genuinely missed stop marker.
        XCTAssertEqual(detector.process(levelDBFS: -90, timestamp: 2.40), .stopped)
        XCTAssertNil(detector.lastStopMarker)
    }

    func testLevelStartedClipKeepsSnappyStopHoldWithoutMarker() {
        let configuration = AudioActivityTriggerConfiguration(
            startThresholdDBFS: -70,
            stopThresholdDBFS: -76,
            startHoldSeconds: 0.06,
            stopHoldSeconds: 0.22,
            minimumActiveSeconds: 0,
            preRollSeconds: 0.6,
            maxUtteranceSeconds: 300
        )
        var detector = AudioActivityTriggerDetector(configuration: configuration)

        XCTAssertNil(detector.process(levelDBFS: -30, timestamp: 0.00))
        XCTAssertEqual(detector.process(levelDBFS: -30, timestamp: 0.10), .started)
        XCTAssertNil(detector.activeStartMarker)
        XCTAssertNil(detector.process(levelDBFS: -90, timestamp: 1.00))
        XCTAssertEqual(detector.process(levelDBFS: -90, timestamp: 1.30), .stopped)
    }

    func testMarkerTrimRemovesStartAndStopMarkerRanges() {
        let clipStart = 1_000
        let startMarker = MarkerToneEvent(
            kind: .start,
            sampleRange: (clipStart + 320)..<(clipStart + 800),
            frequency: 6_000,
            purity: 1
        )
        let speechStart = startMarker.sampleRange.upperBound + 160
        let stopStart = speechStart + 4_000
        let stopMarker = MarkerToneEvent(
            kind: .stop,
            sampleRange: stopStart..<(stopStart + 480),
            frequency: 7_000,
            purity: 1
        )
        let sampleCount = stopMarker.sampleRange.upperBound - clipStart + 320
        let samples = rampPCMData(sampleCount: sampleCount)

        let trimmed = AudioActivityCaptureService.trimMarkerTones(
            pcm16: samples,
            clipStartSampleIndex: clipStart,
            startMarker: startMarker,
            stopMarker: stopMarker,
            configuration: AudioActivityTriggerConfiguration(),
            trimTailSeconds: 0
        )

        XCTAssertEqual(trimmed.count / 2, stopStart - speechStart)
        XCTAssertEqual(sample(at: 0, in: trimmed), sample(at: speechStart - clipStart, in: samples))
        XCTAssertEqual(
            sample(at: (trimmed.count / 2) - 1, in: trimmed),
            sample(at: stopStart - clipStart - 1, in: samples)
        )
    }

    func testMarkerTrimKeepsLateStartMarkerToProtectSpokenContent() {
        let configuration = AudioActivityTriggerConfiguration()
        let clipStart = 1_000
        let headWindowSamples = Int(
            configuration.markerStartHeadWindowSeconds
                * Double(configuration.markerToneConfiguration.sampleRate)
        )
        let lateMarkerStart = clipStart + headWindowSamples + 1
        let startMarker = MarkerToneEvent(
            kind: .start,
            sampleRange: lateMarkerStart..<(lateMarkerStart + 480),
            frequency: 6_000,
            purity: 1
        )
        let samples = rampPCMData(sampleCount: headWindowSamples + 1_000)

        let trimmed = AudioActivityCaptureService.trimMarkerTones(
            pcm16: samples,
            clipStartSampleIndex: clipStart,
            startMarker: startMarker,
            stopMarker: nil,
            configuration: configuration,
            trimTailSeconds: 0
        )

        XCTAssertEqual(trimmed, samples)
    }

    private func detectMarkers(in data: Data, chunkSize: Int) -> [MarkerToneEvent] {
        var detector = MarkerToneDetector()
        var events: [MarkerToneEvent] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize * 2, data.count)
            events.append(
                contentsOf: detector.process(
                    pcm16: data.subdata(in: offset..<end),
                    startingAtSampleIndex: offset / 2
                )
            )
            offset = end
        }
        events.append(contentsOf: detector.flush())
        return events
    }

    private func markerData(frequency: Double, amplitude: Double) -> Data {
        var samples = [Double](repeating: 0, count: Int(0.030 * Double(sampleRate)))
        renderMarker(into: &samples, at: 0, frequency: frequency, amplitude: amplitude)
        return pcmData(from: samples)
    }

    private func renderMarker(
        into samples: inout [Double],
        at offset: Int,
        frequency: Double,
        amplitude: Double,
        durationSeconds: TimeInterval = 0.030
    ) {
        let markerSamples = Int((durationSeconds * Double(sampleRate)).rounded())
        guard offset < samples.count else {
            return
        }

        for markerIndex in 0..<markerSamples where offset + markerIndex < samples.count {
            let phase = 2.0 * Double.pi * frequency * Double(markerIndex) / Double(sampleRate)
            samples[offset + markerIndex] += amplitude * sin(phase)
        }
    }

    private func speechLikeAudio(durationSeconds: TimeInterval, seed: UInt64) -> [Double] {
        var rng = SeededGenerator(seed: seed)
        let count = Int((durationSeconds * Double(sampleRate)).rounded())
        var samples: [Double] = []
        samples.reserveCapacity(count)

        var low = 0.0
        let cutoff = 3_400.0
        let alpha = 1.0 / (1.0 + Double(sampleRate) / (2.0 * Double.pi * cutoff))
        var phases = [0.0, 0.7, 1.6, 2.4]
        let increments = [
            2.0 * Double.pi * 135.0 / Double(sampleRate),
            2.0 * Double.pi * 710.0 / Double(sampleRate),
            2.0 * Double.pi * 1_840.0 / Double(sampleRate),
            2.0 * Double.pi * 4_700.0 / Double(sampleRate),
        ]
        var env1 = 0.0
        var env2 = 1.1
        let env1Step = 2.0 * Double.pi * 2.6 / Double(sampleRate)
        let env2Step = 2.0 * Double.pi * 5.1 / Double(sampleRate)

        for _ in 0..<count {
            let white = rng.nextSignedUnit()
            low += alpha * (white - low)
            let envelope = 0.46 + 0.24 * sin(env1) + 0.10 * sin(env2)
            let tone = 0.035 * sin(phases[0])
                + 0.022 * sin(phases[1])
                + 0.018 * sin(phases[2])
                + 0.010 * sin(phases[3])
            samples.append(envelope * (0.115 * low + tone))

            env1 += env1Step
            env2 += env2Step
            for index in phases.indices {
                phases[index] += increments[index]
                if phases[index] > 2.0 * Double.pi {
                    phases[index] -= 2.0 * Double.pi
                }
            }
        }

        return samples
    }

    private func pcmData(from samples: [Double]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(clamping: Int((sample * 32_767.0).rounded()))
            value = value.littleEndian
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func rampPCMData(sampleCount: Int) -> Data {
        var data = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let value = Int16(index % Int(Int16.max)).littleEndian
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func sample(at index: Int, in data: Data) -> Int16 {
        let byteIndex = index * 2
        let low = UInt16(data[data.startIndex + byteIndex])
        let high = UInt16(data[data.startIndex + byteIndex + 1]) << 8
        return Int16(bitPattern: low | high)
    }
}

private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextSignedUnit() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let value = Double(state >> 11) / 9_007_199_254_740_992.0
        return value * 2.0 - 1.0
    }
}
