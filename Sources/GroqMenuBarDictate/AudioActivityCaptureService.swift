@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Continuously captures the ting's USB audio adapter with a single
/// in-process AVAudioEngine and turns handle squeezes into finished WAV
/// clips ready for transcription.
///
/// - The engine is pinned to the target device directly (no system default
///   input change) and only runs while the feature is enabled AND the
///   adapter is present, so the macOS mic indicator is off otherwise.
/// - Audio is converted to 16 kHz mono PCM on ingest and kept in a short
///   pre-roll ring while idle; when activity starts, the ring becomes the
///   head of the clip, so no leading speech is lost to detection latency.
/// - When activity stops, the trailing silence hold is trimmed and the clip
///   is finalized in memory — "recording" has zero start/stop device cost.
final class AudioActivityCaptureService: @unchecked Sendable {
    static let targetDeviceName = "Cable Creation"
    private static let outputSampleRate = 16_000
    private static let bytesPerSample = 2
    private static let engineRestartDelaySeconds: TimeInterval = 0.5
    private static let levelLogIntervalSeconds: TimeInterval = 5

    private let logger = Logger(subsystem: "com.huntae.groq-menubar-dictate", category: "audio-trigger")
    /// Owns detector, pending PCM, and capture state. Engine lifecycle and
    /// device watching stay on the main queue.
    private let captureQueue = DispatchQueue(label: "com.huntae.groq-menubar-dictate.audio-capture")

    // Main-queue state.
    private var isEnabled = false
    private var levelLoggingEnabled = false
    private var rawDumpEnabled = false
    private var configuration = AudioActivityTriggerConfiguration()
    private var engine: AVAudioEngine?
    private var engineDeviceID: AudioDeviceID?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var configurationChangeObserver: NSObjectProtocol?
    private var pendingEngineRestart = false

    // captureQueue state.
    private var detector = AudioActivityTriggerDetector()
    private var pendingPCM = Data()
    private var pendingPCMStartSampleIndex = 0
    private var isCapturing = false
    private var totalIngestedSamples = 0
    private var levelStats: (min: Double, max: Double, sum: Double, count: Int, lastLogged: TimeInterval)?
    private var rawDumpWriter: RawStreamDumpWriter?
    /// Diagnostic-only mirror of the marker detector that is never reset
    /// between captures (matching --trigger-replay conditions), so live logs
    /// show what a continuously-running detector hears regardless of the
    /// capture lifecycle. captureQueue only.
    private var diagnosticMarkerDetector: MarkerToneDetector?

    /// All callbacks are invoked on captureQueue (or the main queue for
    /// device connection changes); hop to the main actor in the handler.
    var onCaptureStarted: (() -> Void)?
    var onCaptureFinished: ((RecordedClip) -> Void)?
    var onCaptureCancelled: (() -> Void)?
    var onDeviceConnectionChanged: ((Bool) -> Void)?
    var onMonitorError: ((String) -> Void)?

    var isDeviceConnected: Bool {
        SystemAudioDeviceInspector.firstInputDevice(matchingName: Self.targetDeviceName) != nil
    }

    /// Main queue only.
    func setEnabled(
        _ enabled: Bool,
        configuration: AudioActivityTriggerConfiguration = AudioActivityTriggerConfiguration(),
        levelLoggingEnabled: Bool = false,
        rawDumpEnabled: Bool = false
    ) {
        let rawDumpChanged = self.rawDumpEnabled != rawDumpEnabled
        self.configuration = configuration
        self.levelLoggingEnabled = levelLoggingEnabled
        self.rawDumpEnabled = rawDumpEnabled
        guard enabled != isEnabled else {
            if enabled {
                // Re-apply tuning changes without a full restart.
                captureQueue.async { [weak self] in
                    guard let self else {
                        return
                    }
                    if rawDumpChanged {
                        self.updateRawDumpWriter(enabled: rawDumpEnabled)
                    }
                    guard !self.isCapturing else {
                        return
                    }
                    self.detector = AudioActivityTriggerDetector(configuration: configuration)
                }
            }
            return
        }
        isEnabled = enabled

        if enabled {
            installDeviceListListener()
            evaluateDevicePresence()
        } else {
            removeDeviceListListener()
            stopEngine(cancelActiveCapture: true)
        }
    }

    /// Finalize the in-flight capture immediately (e.g. user tapped Option
    /// mid-utterance). No-op when nothing is being captured.
    func finishActiveCapture() {
        captureQueue.async { [weak self] in
            guard let self, self.isCapturing else {
                return
            }
            self.finalizeCapture(trimTailSeconds: 0)
        }
    }

    /// Discard the in-flight capture (e.g. Esc abort, device unplugged).
    func cancelActiveCapture() {
        captureQueue.async { [weak self] in
            guard let self, self.isCapturing else {
                return
            }
            self.logger.notice("ting capture cancelled")
            self.resetCaptureState()
            self.onCaptureCancelled?()
        }
    }

    // MARK: - Device presence (main queue)

    private func installDeviceListListener() {
        guard deviceListListener == nil else {
            return
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.evaluateDevicePresence()
        }
        var address = Self.deviceListPropertyAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        )
        if status == noErr {
            deviceListListener = listener
        } else {
            logger.error("Failed to install audio device list listener status=\(status, privacy: .public)")
        }
    }

    private func removeDeviceListListener() {
        guard let listener = deviceListListener else {
            return
        }
        var address = Self.deviceListPropertyAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        )
        deviceListListener = nil
    }

    private static var deviceListPropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func evaluateDevicePresence() {
        guard isEnabled else {
            return
        }
        let device = SystemAudioDeviceInspector.firstInputDevice(matchingName: Self.targetDeviceName)

        if let device {
            guard engine == nil else {
                return
            }
            do {
                try startEngine(deviceID: device.id)
                onDeviceConnectionChanged?(true)
            } catch {
                onMonitorError?("Failed to start ting audio monitor: \(error.localizedDescription)")
            }
        } else if engine != nil {
            stopEngine(cancelActiveCapture: true)
            onDeviceConnectionChanged?(false)
        }
    }

    // MARK: - Engine lifecycle (main queue)

    private func startEngine(deviceID: AudioDeviceID) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioActivityCaptureError.inputUnitUnavailable
        }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioActivityCaptureError.failedToPinDevice(status)
        }

        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioActivityCaptureError.invalidInputFormat
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(Self.outputSampleRate),
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioActivityCaptureError.converterUnavailable
        }

        let configuration = configuration
        let rawDumpEnabled = rawDumpEnabled
        var rawDumpError: Error?
        captureQueue.sync {
            detector = AudioActivityTriggerDetector(configuration: configuration)
            diagnosticMarkerDetector = MarkerToneDetector(
                configuration: configuration.markerToneConfiguration
            )
            pendingPCM.removeAll(keepingCapacity: true)
            pendingPCMStartSampleIndex = 0
            isCapturing = false
            totalIngestedSamples = 0
            levelStats = nil
            rawDumpWriter?.close()
            rawDumpWriter = nil
            if rawDumpEnabled {
                do {
                    try startRawDumpWriter()
                } catch {
                    rawDumpError = error
                }
            }
        }
        if let rawDumpError {
            throw rawDumpError
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTapBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            captureQueue.sync {
                rawDumpWriter?.close()
                rawDumpWriter = nil
            }
            throw error
        }

        self.engine = engine
        engineDeviceID = deviceID
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleEngineRestart()
        }
        logger.notice("ting audio monitor started device_id=\(deviceID, privacy: .public) input_rate=\(inputFormat.sampleRate, privacy: .public)")
    }

    private func stopEngine(cancelActiveCapture shouldCancel: Bool) {
        if let configurationChangeObserver {
            NotificationCenter.default.removeObserver(configurationChangeObserver)
            self.configurationChangeObserver = nil
        }
        captureQueue.sync {
            rawDumpWriter?.close()
            rawDumpWriter = nil
        }
        guard let engine else {
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        engineDeviceID = nil
        if shouldCancel {
            cancelActiveCapture()
        }
        logger.notice("ting audio monitor stopped")
    }

    /// Device sample-rate/route changes invalidate the tap format; tear the
    /// engine down and re-evaluate shortly after things settle.
    private func scheduleEngineRestart() {
        guard !pendingEngineRestart else {
            return
        }
        pendingEngineRestart = true
        stopEngine(cancelActiveCapture: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.engineRestartDelaySeconds) { [weak self] in
            guard let self else {
                return
            }
            self.pendingEngineRestart = false
            self.evaluateDevicePresence()
        }
    }

    // MARK: - Audio ingest (tap thread -> captureQueue)

    private func handleTapBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var conversionError: NSError?
        // The converter invokes this block synchronously inside convert();
        // the flag never crosses threads despite the Sendable annotation.
        nonisolated(unsafe) var didConsumeInput = false
        converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if didConsumeInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didConsumeInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil,
              converted.frameLength > 0,
              let channel = converted.int16ChannelData?[0]
        else {
            return
        }

        let chunk = Data(bytes: channel, count: Int(converted.frameLength) * Self.bytesPerSample)
        captureQueue.async { [weak self] in
            self?.ingest(chunk)
        }
    }

    private func ingest(_ chunk: Data) {
        rawDumpWriter?.append(chunk)

        let chunkStartSampleIndex = totalIngestedSamples
        totalIngestedSamples += chunk.count / Self.bytesPerSample
        let timestamp = Double(totalIngestedSamples) / Double(Self.outputSampleRate)

        pendingPCM.append(chunk)
        if !isCapturing {
            let preRollBytes = bytes(forSeconds: configuration.preRollSeconds)
            if pendingPCM.count > preRollBytes {
                let removedBytes = pendingPCM.count - preRollBytes
                pendingPCM.removeSubrange(0..<removedBytes)
                pendingPCMStartSampleIndex += removedBytes / Self.bytesPerSample
            }
        }

        guard let level = Self.levelDBFS(pcm16: chunk) else {
            return
        }
        logLevelIfNeeded(level, timestamp: timestamp)

        if diagnosticMarkerDetector != nil {
            let diagnosticEvents = diagnosticMarkerDetector!.process(
                pcm16: chunk,
                startingAtSampleIndex: chunkStartSampleIndex
            )
            for event in diagnosticEvents {
                logger.notice(
                    "ting marker diag kind=\(event.kind == .start ? "start" : "stop", privacy: .public) sample=\(event.sampleIndex, privacy: .public) purity=\(event.purity, format: .fixed(precision: 2), privacy: .public)"
                )
            }
        }

        switch detector.process(
            pcm16: chunk,
            levelDBFS: level,
            timestamp: timestamp,
            startingAtSampleIndex: chunkStartSampleIndex
        ) {
        case .started:
            isCapturing = true
            logger.notice("ting activity started level_dbfs=\(level, format: .fixed(precision: 1), privacy: .public)")
            onCaptureStarted?()
        case .stopped:
            let stoppedByMarker = detector.lastStopMarker != nil
            logger.notice("ting activity stopped level_dbfs=\(level, format: .fixed(precision: 1), privacy: .public) cause=\(stoppedByMarker ? "marker" : "level", privacy: .public)")
            // Keep a small tail margin for the level fallback so trailing
            // phonemes survive the silence trim. Marker stops trim at the
            // marker onset instead and do not wait out stopHoldSeconds.
            finalizeCapture(
                trimTailSeconds: stoppedByMarker ? 0 : max(0, configuration.stopHoldSeconds - 0.1)
            )
        case nil:
            if isCapturing, pendingPCM.count > bytes(forSeconds: configuration.maxUtteranceSeconds) {
                logger.error("ting capture hit max utterance duration; finalizing")
                finalizeCapture(trimTailSeconds: 0)
            }
        }
    }

    /// captureQueue only.
    private func finalizeCapture(trimTailSeconds: TimeInterval) {
        guard isCapturing else {
            return
        }
        let clipStartSampleIndex = pendingPCMStartSampleIndex
        let startMarker = detector.activeStartMarker
        let stopMarker = detector.lastStopMarker
        var samples = pendingPCM
        resetCaptureState()

        samples = Self.trimMarkerTones(
            pcm16: samples,
            clipStartSampleIndex: clipStartSampleIndex,
            startMarker: startMarker,
            stopMarker: stopMarker,
            configuration: configuration,
            trimTailSeconds: trimTailSeconds
        )
        guard !samples.isEmpty else {
            onCaptureCancelled?()
            return
        }

        let durationSeconds = Double(samples.count / Self.bytesPerSample) / Double(Self.outputSampleRate)
        logger.notice("ting capture finalized duration_s=\(durationSeconds, format: .fixed(precision: 2), privacy: .public) trim_tail_s=\(trimTailSeconds, format: .fixed(precision: 2), privacy: .public)")
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        do {
            try PCM16WAVEncoder.wavData(pcm16: samples, sampleRate: Self.outputSampleRate)
                .write(to: fileURL, options: .atomic)
        } catch {
            onMonitorError?("Failed to save ting recording: \(error.localizedDescription)")
            return
        }

        onCaptureFinished?(RecordedClip(
            fileURL: fileURL,
            recorderReportedDurationSeconds: durationSeconds
        ))
    }

    /// captureQueue only.
    private func resetCaptureState() {
        isCapturing = false
        pendingPCM.removeAll(keepingCapacity: true)
        pendingPCMStartSampleIndex = totalIngestedSamples
        detector = AudioActivityTriggerDetector(configuration: configuration)
    }

    static func trimMarkerTones(
        pcm16 samples: Data,
        clipStartSampleIndex: Int,
        startMarker: MarkerToneEvent?,
        stopMarker: MarkerToneEvent?,
        configuration: AudioActivityTriggerConfiguration,
        trimTailSeconds: TimeInterval
    ) -> Data {
        let totalSampleCount = samples.count / bytesPerSample
        guard totalSampleCount > 0 else {
            return Data()
        }

        let clipEndSampleIndex = clipStartSampleIndex + totalSampleCount
        var keepStartSampleIndex = clipStartSampleIndex
        var keepEndSampleIndex = clipEndSampleIndex

        let marginSamples = max(
            0,
            Int((configuration.markerTrimMarginSeconds * Double(outputSampleRate)).rounded())
        )

        if let startMarker,
           shouldTrimStartMarker(
               startMarker,
               clipStartSampleIndex: clipStartSampleIndex,
               marginSamples: marginSamples,
               configuration: configuration
           ) {
            keepStartSampleIndex = max(
                keepStartSampleIndex,
                startMarker.sampleRange.upperBound + marginSamples
            )
        }

        if let stopMarker {
            keepEndSampleIndex = min(keepEndSampleIndex, stopMarker.sampleRange.lowerBound)
        } else {
            let tailTrimSamples = min(
                max(0, Int((trimTailSeconds * Double(outputSampleRate)).rounded())),
                totalSampleCount
            )
            keepEndSampleIndex = max(clipStartSampleIndex, keepEndSampleIndex - tailTrimSamples)
        }

        keepStartSampleIndex = min(max(keepStartSampleIndex, clipStartSampleIndex), clipEndSampleIndex)
        keepEndSampleIndex = min(max(keepEndSampleIndex, clipStartSampleIndex), clipEndSampleIndex)
        guard keepStartSampleIndex < keepEndSampleIndex else {
            return Data()
        }

        let startByte = (keepStartSampleIndex - clipStartSampleIndex) * bytesPerSample
        let endByte = (keepEndSampleIndex - clipStartSampleIndex) * bytesPerSample
        return samples.subdata(in: startByte..<endByte)
    }

    private static func shouldTrimStartMarker(
        _ marker: MarkerToneEvent,
        clipStartSampleIndex: Int,
        marginSamples: Int,
        configuration: AudioActivityTriggerConfiguration
    ) -> Bool {
        let headWindowSamples = max(
            0,
            Int((configuration.markerStartHeadWindowSeconds * Double(outputSampleRate)).rounded())
        )
        let markerOffset = marker.sampleRange.lowerBound - clipStartSampleIndex
        return marker.sampleRange.upperBound > clipStartSampleIndex
            && markerOffset >= -marginSamples
            && markerOffset <= headWindowSamples
    }

    private func bytes(forSeconds seconds: TimeInterval) -> Int {
        max(0, Int(seconds * Double(Self.outputSampleRate)) * Self.bytesPerSample)
    }

    /// Periodic floor/peak logging for threshold calibration; enable via the
    /// performance diagnostics setting and watch with:
    /// log stream --predicate 'subsystem == "com.huntae.groq-menubar-dictate" AND category == "audio-trigger"'
    private func logLevelIfNeeded(_ level: Double, timestamp: TimeInterval) {
        guard levelLoggingEnabled else {
            levelStats = nil
            return
        }
        var stats = levelStats ?? (min: level, max: level, sum: 0, count: 0, lastLogged: timestamp)
        stats.min = Swift.min(stats.min, level)
        stats.max = Swift.max(stats.max, level)
        stats.sum += level
        stats.count += 1
        if timestamp - stats.lastLogged >= Self.levelLogIntervalSeconds {
            let average = stats.sum / Double(stats.count)
            logger.notice(
                "ting levels window_s=\(Self.levelLogIntervalSeconds, format: .fixed(precision: 0), privacy: .public) min_dbfs=\(stats.min, format: .fixed(precision: 1), privacy: .public) avg_dbfs=\(average, format: .fixed(precision: 1), privacy: .public) max_dbfs=\(stats.max, format: .fixed(precision: 1), privacy: .public) capturing=\(self.isCapturing, privacy: .public)"
            )
            stats = (min: level, max: level, sum: 0, count: 0, lastLogged: timestamp)
        }
        levelStats = stats
    }

    /// captureQueue only.
    private func updateRawDumpWriter(enabled: Bool) {
        if enabled {
            do {
                try startRawDumpWriter()
            } catch {
                onMonitorError?("Failed to start ting raw dump: \(error.localizedDescription)")
            }
        } else {
            rawDumpWriter?.close()
            rawDumpWriter = nil
        }
    }

    /// captureQueue only.
    private func startRawDumpWriter() throws {
        guard rawDumpWriter == nil else {
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ting-raw", isDirectory: true)
        let writer = try RawStreamDumpWriter(
            directory: directory,
            sampleRate: Self.outputSampleRate
        )
        rawDumpWriter = writer
        logger.notice("ting raw dump path=\(writer.fileURL.path, privacy: .public)")
    }

    static func levelDBFS(pcm16 data: Data) -> Double? {
        guard data.count >= bytesPerSample else {
            return nil
        }

        var sumSquares = 0.0
        var sampleCount = 0
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var index = 0
            while index + 1 < bytes.count {
                let rawSample = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                let sample = Int16(bitPattern: rawSample)
                let normalized = Double(sample) / 32_768.0
                sumSquares += normalized * normalized
                sampleCount += 1
                index += bytesPerSample
            }
        }

        guard sampleCount > 0 else {
            return nil
        }
        let rms = (sumSquares / Double(sampleCount)).squareRoot()
        return 20 * log10(max(rms, 0.000_000_1))
    }
}

enum AudioActivityCaptureError: LocalizedError {
    case inputUnitUnavailable
    case failedToPinDevice(OSStatus)
    case invalidInputFormat
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .inputUnitUnavailable:
            return "Audio input unit unavailable."
        case let .failedToPinDevice(status):
            return "Failed to select the ting input device (status \(status))."
        case .invalidInputFormat:
            return "The ting input device reported an invalid format."
        case .converterUnavailable:
            return "Failed to prepare the audio converter."
        }
    }
}
