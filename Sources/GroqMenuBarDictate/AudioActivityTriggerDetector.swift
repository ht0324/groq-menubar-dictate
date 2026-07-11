import Foundation

enum AudioActivityTriggerEvent {
    case started
    case stopped
}

/// Tuned for the ting's push-to-talk handle: the goal is to detect the
/// channel going live (handle squeezed) versus the ADC idle floor (handle
/// released), not to detect speech. Pre-roll makes start latency moot, so
/// thresholds should sit between the adapter's idle floor and the live mic
/// channel floor. All values can be overridden without a rebuild via
/// hidden defaults (see SettingsStore.audioActivityTriggerConfiguration).
struct AudioActivityTriggerConfiguration {
    // Calibrated 2026-07-03 against the user's Cable Creation ADC: idle
    // floor (ting released) is -78.6 dBFS +-0.5; speech peaks -16 to -19.
    // Stop must sit ABOVE the idle floor or release is never detected.
    var startThresholdDBFS: Double = -70
    var stopThresholdDBFS: Double = -76
    // Stop hold is the release-to-stop latency, but also the only guard
    // against splitting on a mid-squeeze pause (squeezed-but-silent reads
    // the same floor as released on this hardware). 0.22s tolerates normal
    // inter-phrase gaps while keeping release snappy.
    var startHoldSeconds: TimeInterval = 0.06
    var stopHoldSeconds: TimeInterval = 0.22
    // When the clip began with a start marker the firmware is proven live,
    // so the stop marker is the primary release signal and the level-based
    // stop only rescues a missed marker. A long hold here is what lets a
    // mid-squeeze thinking pause stay one clip; it never applies when the
    // marker firmware is absent (no start marker seen), so stock hardware
    // keeps the snappy 0.22s behavior.
    var markerFallbackStopHoldSeconds: TimeInterval = 12.0
    // Brief single-chunk USB tether noise blips near -24 dBFS must not
    // restart the 12s marker fallback hold. Real speech stays loud for
    // this long and still resets it.
    var markerFallbackLoudResetSeconds: TimeInterval = 0.25
    var minimumActiveSeconds: TimeInterval = 0.3
    var preRollSeconds: TimeInterval = 0.6
    var maxUtteranceSeconds: TimeInterval = 300
    var markerToneConfiguration = MarkerToneDetector.Configuration()
    // Trim past the 30 ms start marker with a little room for detector/block
    // alignment, matching the measured marker timing without eating speech.
    var markerTrimMarginSeconds: TimeInterval = 0.010
    // A true start marker should live inside the pre-roll near the clip head.
    // Ignore later start tones for head trimming so a mid-capture marker does
    // not discard spoken content.
    var markerStartHeadWindowSeconds: TimeInterval = 0.8
}

struct AudioActivityTriggerDetector {
    private let configuration: AudioActivityTriggerConfiguration
    private var markerDetector: MarkerToneDetector
    private(set) var isActive = false
    private(set) var activeStartMarker: MarkerToneEvent?
    private(set) var lastStopMarker: MarkerToneEvent?
    private var loudSince: TimeInterval?
    private var quietSince: TimeInterval?
    private var activeSince: TimeInterval?

    init(configuration: AudioActivityTriggerConfiguration = AudioActivityTriggerConfiguration()) {
        self.configuration = configuration
        markerDetector = MarkerToneDetector(configuration: configuration.markerToneConfiguration)
    }

    mutating func process(levelDBFS: Double, timestamp: TimeInterval) -> AudioActivityTriggerEvent? {
        guard levelDBFS.isFinite, timestamp.isFinite else {
            return nil
        }

        return process(levelDBFS: levelDBFS, timestamp: timestamp, markerEvents: [])
    }

    mutating func process(
        pcm16 data: Data,
        levelDBFS: Double,
        timestamp: TimeInterval,
        startingAtSampleIndex sampleIndex: Int
    ) -> AudioActivityTriggerEvent? {
        guard levelDBFS.isFinite, timestamp.isFinite else {
            return nil
        }

        let markerEvents = markerDetector.process(
            pcm16: data,
            startingAtSampleIndex: sampleIndex
        )
        return process(levelDBFS: levelDBFS, timestamp: timestamp, markerEvents: markerEvents)
    }

    private mutating func process(
        levelDBFS: Double,
        timestamp: TimeInterval,
        markerEvents: [MarkerToneEvent]
    ) -> AudioActivityTriggerEvent? {
        if let markerEvent = processMarkerEvents(markerEvents, timestamp: timestamp) {
            return markerEvent
        }

        if isActive {
            return processActiveLevel(levelDBFS, timestamp: timestamp)
        }
        return processInactiveLevel(levelDBFS, timestamp: timestamp)
    }

    private mutating func processMarkerEvents(
        _ markerEvents: [MarkerToneEvent],
        timestamp: TimeInterval
    ) -> AudioActivityTriggerEvent? {
        for markerEvent in markerEvents.sorted(by: { $0.sampleIndex < $1.sampleIndex }) {
            switch markerEvent.kind {
            case .start:
                if isActive {
                    if activeStartMarker == nil {
                        activeStartMarker = markerEvent
                    }
                    continue
                }
                return startCapture(
                    timestamp: timestampForMarker(markerEvent, fallback: timestamp),
                    startMarker: markerEvent
                )
            case .stop:
                guard isActive else {
                    continue
                }
                // Firmware emits one stop tone per release, so even an immediate
                // 7 kHz stop after the distinct 6 kHz start tone is real.
                return stopCapture(stopMarker: markerEvent)
            }
        }
        return nil
    }

    private mutating func processInactiveLevel(
        _ levelDBFS: Double,
        timestamp: TimeInterval
    ) -> AudioActivityTriggerEvent? {
        guard levelDBFS >= configuration.startThresholdDBFS else {
            loudSince = nil
            return nil
        }

        if loudSince == nil {
            loudSince = timestamp
        }
        guard let loudStart = loudSince,
              timestamp - loudStart >= configuration.startHoldSeconds
        else {
            return nil
        }

        return startCapture(timestamp: timestamp, startMarker: nil)
    }

    private mutating func processActiveLevel(
        _ levelDBFS: Double,
        timestamp: TimeInterval
    ) -> AudioActivityTriggerEvent? {
        guard levelDBFS <= configuration.stopThresholdDBFS else {
            guard activeStartMarker != nil else {
                quietSince = nil
                return nil
            }

            if loudSince == nil {
                loudSince = timestamp
            }
            if let loudStart = loudSince,
               timestamp - loudStart >= configuration.markerFallbackLoudResetSeconds {
                quietSince = nil
            }
            return nil
        }

        loudSince = nil
        if quietSince == nil {
            quietSince = timestamp
        }

        let stopHold = activeStartMarker != nil
            ? configuration.markerFallbackStopHoldSeconds
            : configuration.stopHoldSeconds
        let activeDuration = timestamp - (activeSince ?? timestamp)
        guard let quietStart = quietSince,
              timestamp - quietStart >= stopHold,
              activeDuration >= configuration.minimumActiveSeconds
        else {
            return nil
        }

        return stopCapture(stopMarker: nil)
    }

    private mutating func startCapture(
        timestamp: TimeInterval,
        startMarker: MarkerToneEvent?
    ) -> AudioActivityTriggerEvent {
        isActive = true
        activeSince = timestamp
        quietSince = nil
        loudSince = nil
        activeStartMarker = startMarker
        lastStopMarker = nil
        return .started
    }

    private mutating func stopCapture(stopMarker: MarkerToneEvent?) -> AudioActivityTriggerEvent {
        isActive = false
        activeSince = nil
        quietSince = nil
        loudSince = nil
        lastStopMarker = stopMarker
        return .stopped
    }

    private func timestampForMarker(
        _ markerEvent: MarkerToneEvent,
        fallback: TimeInterval
    ) -> TimeInterval {
        let sampleRate = max(1, configuration.markerToneConfiguration.sampleRate)
        let timestamp = Double(markerEvent.sampleIndex) / Double(sampleRate)
        return timestamp.isFinite ? timestamp : fallback
    }
}
