import Foundation

enum MarkerToneKind: Equatable {
    case start
    case stop
}

struct MarkerToneEvent: Equatable {
    let kind: MarkerToneKind
    let sampleRange: Range<Int>
    let frequency: Double
    let purity: Double

    var sampleIndex: Int {
        sampleRange.lowerBound
    }
}

struct MarkerToneDetector {
    struct Configuration: Equatable {
        var sampleRate: Int = 16_000
        // The ting firmware emits short marker bursts in the 16 kHz mono
        // Int16 stream: 6000 Hz on squeeze and 7000 Hz on release.
        var startFrequency: Double = 6_000
        var stopFrequency: Double = 7_000
        // 10 ms blocks give three decisions across a 30 ms marker while
        // keeping stop latency far below the level-based stop hold.
        var blockDurationSeconds: TimeInterval = 0.010
        // Real recordings measured near 1.0 tone energy / total energy per
        // 10 ms window, so this sits well below the marker and high above
        // speech-like broadband content.
        var purityThreshold: Double = 0.55
        var releasePurityThreshold: Double = 0.20
        // Markers measured 26-41% of full scale peak; sine RMS is roughly
        // 18-29%, so a 4% RMS gate rejects quiet floors without risking the
        // measured marker bursts.
        var minimumRMS: Double = 0.04
        // Two consecutive marker-positive blocks debounce a 30 ms burst into
        // exactly one event; release blocks re-arm the detector after it fades.
        var debounceBlockCount: Int = 2
        var releaseBlockCount: Int = 2
        var refractorySeconds: TimeInterval = 0.050
        var expectedBurstSeconds: TimeInterval = 0.030
    }

    private struct TargetState {
        let kind: MarkerToneKind
        let frequency: Double
        let coefficient: Double
        var isActive = false
        var candidateBlockCount = 0
        var candidateStartSampleIndex: Int?
        var candidatePeakPurity = 0.0
        var releaseBlockCount = 0
        var lastDetectionSampleIndex: Int?

        init(kind: MarkerToneKind, frequency: Double, sampleRate: Int) {
            self.kind = kind
            self.frequency = frequency
            let omega = 2.0 * Double.pi * frequency / Double(sampleRate)
            coefficient = 2.0 * cos(omega)
        }
    }

    private let configuration: Configuration
    private let sampleRate: Int
    private let blockSize: Int
    private let expectedBurstSamples: Int
    private let refractorySamples: Int
    private var targets: [TargetState]
    private var pendingSamples: [Int16] = []
    private var pendingStartSampleIndex: Int?
    private var nextSampleIndex = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        sampleRate = max(1, configuration.sampleRate)
        blockSize = max(
            16,
            Int((Double(sampleRate) * max(0.001, configuration.blockDurationSeconds)).rounded())
        )
        expectedBurstSamples = max(
            blockSize,
            Int((Double(sampleRate) * max(0.0, configuration.expectedBurstSeconds)).rounded())
        )
        refractorySamples = max(
            0,
            Int((Double(sampleRate) * max(0.0, configuration.refractorySeconds)).rounded())
        )

        targets = [
            TargetState(
                kind: .start,
                frequency: Self.validFrequency(configuration.startFrequency, sampleRate: sampleRate),
                sampleRate: sampleRate
            ),
            TargetState(
                kind: .stop,
                frequency: Self.validFrequency(configuration.stopFrequency, sampleRate: sampleRate),
                sampleRate: sampleRate
            ),
        ]
    }

    mutating func process(pcm16 data: Data, startingAtSampleIndex: Int? = nil) -> [MarkerToneEvent] {
        let samples = Self.samples(fromPCM16: data)
        guard !samples.isEmpty else {
            return []
        }

        let chunkStart = startingAtSampleIndex ?? nextSampleIndex
        prepareForChunk(startingAt: chunkStart)
        nextSampleIndex = chunkStart + samples.count

        var events: [MarkerToneEvent] = []
        for sample in samples {
            pendingSamples.append(sample)
            if pendingSamples.count == blockSize {
                let blockStart = pendingStartSampleIndex ?? (nextSampleIndex - pendingSamples.count)
                events.append(contentsOf: processBlock(pendingSamples, startingAt: blockStart))
                pendingSamples.removeAll(keepingCapacity: true)
                pendingStartSampleIndex = blockStart + blockSize
            }
        }
        return events
    }

    mutating func flush() -> [MarkerToneEvent] {
        guard !pendingSamples.isEmpty else {
            return []
        }

        let blockStart = pendingStartSampleIndex ?? nextSampleIndex - pendingSamples.count
        var block = pendingSamples
        block.append(contentsOf: repeatElement(Int16(0), count: blockSize - block.count))
        pendingSamples.removeAll(keepingCapacity: true)
        pendingStartSampleIndex = nextSampleIndex
        return processBlock(block, startingAt: blockStart)
    }

    private mutating func prepareForChunk(startingAt chunkStart: Int) {
        guard let pendingStartSampleIndex else {
            self.pendingStartSampleIndex = chunkStart
            return
        }

        let expectedStart = pendingStartSampleIndex + pendingSamples.count
        guard chunkStart == expectedStart else {
            pendingSamples.removeAll(keepingCapacity: true)
            self.pendingStartSampleIndex = chunkStart
            nextSampleIndex = chunkStart
            return
        }
    }

    private mutating func processBlock(
        _ block: [Int16],
        startingAt blockStart: Int
    ) -> [MarkerToneEvent] {
        let values = block.map { Double($0) / 32_768.0 }
        let totalEnergy = values.reduce(0.0) { $0 + ($1 * $1) }
        let rms = sqrt(totalEnergy / Double(block.count))

        var events: [MarkerToneEvent] = []
        for index in targets.indices {
            let score: Double
            if rms >= configuration.minimumRMS, totalEnergy > 1.0e-18 {
                score = Self.normalizedGoertzelScore(
                    values: values,
                    coefficient: targets[index].coefficient,
                    totalEnergy: totalEnergy
                )
            } else {
                score = 0
            }

            if let event = updateTarget(at: index, score: score, blockStart: blockStart) {
                events.append(event)
            }
        }
        return events
    }

    private mutating func updateTarget(
        at index: Int,
        score: Double,
        blockStart: Int
    ) -> MarkerToneEvent? {
        let threshold = configuration.purityThreshold
        let releaseThreshold = min(configuration.releasePurityThreshold, threshold)

        if targets[index].isActive {
            targets[index].candidateBlockCount = 0
            targets[index].candidateStartSampleIndex = nil
            targets[index].candidatePeakPurity = 0

            if score <= releaseThreshold {
                targets[index].releaseBlockCount += 1
                if targets[index].releaseBlockCount >= max(1, configuration.releaseBlockCount) {
                    targets[index].isActive = false
                    targets[index].releaseBlockCount = 0
                }
            } else {
                targets[index].releaseBlockCount = 0
            }
            return nil
        }

        guard score >= threshold else {
            if score <= releaseThreshold {
                targets[index].candidateBlockCount = 0
                targets[index].candidateStartSampleIndex = nil
                targets[index].candidatePeakPurity = 0
            }
            return nil
        }

        if targets[index].candidateBlockCount == 0 {
            targets[index].candidateStartSampleIndex = blockStart
            targets[index].candidatePeakPurity = score
        } else {
            targets[index].candidatePeakPurity = max(targets[index].candidatePeakPurity, score)
        }
        targets[index].candidateBlockCount += 1

        guard targets[index].candidateBlockCount >= max(1, configuration.debounceBlockCount),
              let candidateStart = targets[index].candidateStartSampleIndex,
              isOutsideRefractory(targets[index], sampleIndex: candidateStart)
        else {
            return nil
        }

        targets[index].isActive = true
        targets[index].releaseBlockCount = 0
        targets[index].candidateBlockCount = 0
        targets[index].candidateStartSampleIndex = nil
        let peakPurity = targets[index].candidatePeakPurity
        targets[index].candidatePeakPurity = 0
        targets[index].lastDetectionSampleIndex = candidateStart

        return MarkerToneEvent(
            kind: targets[index].kind,
            sampleRange: candidateStart..<(candidateStart + expectedBurstSamples),
            frequency: targets[index].frequency,
            purity: peakPurity
        )
    }

    private func isOutsideRefractory(_ target: TargetState, sampleIndex: Int) -> Bool {
        guard let lastDetectionSampleIndex = target.lastDetectionSampleIndex else {
            return true
        }
        return sampleIndex - lastDetectionSampleIndex >= refractorySamples
    }

    private static func normalizedGoertzelScore(
        values: [Double],
        coefficient: Double,
        totalEnergy: Double
    ) -> Double {
        var previous = 0.0
        var previous2 = 0.0

        for value in values {
            let current = value + coefficient * previous - previous2
            previous2 = previous
            previous = current
        }

        let power = previous2 * previous2 + previous * previous - coefficient * previous * previous2
        return max(0, (2.0 * power) / (Double(values.count) * totalEnergy))
    }

    private static func samples(fromPCM16 data: Data) -> [Int16] {
        guard data.count >= 2 else {
            return []
        }

        var samples: [Int16] = []
        samples.reserveCapacity(data.count / 2)
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var index = 0
            while index + 1 < bytes.count {
                let rawSample = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                samples.append(Int16(bitPattern: rawSample))
                index += 2
            }
        }
        return samples
    }

    private static func validFrequency(_ frequency: Double, sampleRate: Int) -> Double {
        let nyquist = Double(sampleRate) / 2.0
        guard frequency.isFinite else {
            return max(1.0, nyquist - 1.0)
        }
        return min(max(1.0, frequency), max(1.0, nyquist - 1.0))
    }
}
