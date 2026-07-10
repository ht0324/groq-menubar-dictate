import Foundation

enum TriggerReplayCommand {
    private static let sampleRate = 16_000
    private static let bytesPerSample = 2

    private struct Options {
        var audioPath: String?
        var chunkMilliseconds = 20
        var useSettings = false
        var verbose = false
        var showHelp = false
    }

    private struct WAVFormat {
        let formatCode: UInt16
        let channelCount: UInt16
        let sampleRate: UInt32
        let bitsPerSample: UInt16
    }

    static func shouldRun(arguments: [String]) -> Bool {
        arguments.dropFirst().contains("--trigger-replay")
    }

    static func run(arguments: [String]) -> Int32 {
        do {
            let options = try parse(arguments: Array(arguments.dropFirst()))
            if options.showHelp {
                print(usage)
                return 0
            }

            guard let audioPath = options.audioPath else {
                throw ReplayError.missingAudioPath
            }

            let pcm16 = try readPCM16MonoWAV(at: URL(fileURLWithPath: audioPath))
            try replay(pcm16: pcm16, options: options)
            return 0
        } catch {
            fputs("trigger_replay result=failed error=\"\(escape(error.localizedDescription))\"\n", stderr)
            fputs("\n\(usage)\n", stderr)
            return 1
        }
    }

    static func readPCM16MonoWAV(at url: URL) throws -> Data {
        try readPCM16MonoWAV(data: Data(contentsOf: url))
    }

    private static func readPCM16MonoWAV(data: Data) throws -> Data {
        guard data.count >= 12 else {
            throw ReplayError.invalidWAV("WAV header is truncated.")
        }
        guard asciiString(in: 0..<4, data: data) == "RIFF",
              asciiString(in: 8..<12, data: data) == "WAVE"
        else {
            throw ReplayError.invalidWAV("Expected a RIFF/WAVE file.")
        }

        var format: WAVFormat?
        var pcm16: Data?
        var offset = 12
        while offset + 8 <= data.count {
            guard let chunkID = asciiString(in: offset..<(offset + 4), data: data) else {
                throw ReplayError.invalidWAV("Chunk header is invalid.")
            }
            let declaredSize = Int(readUInt32(data, at: offset + 4))
            let payloadStart = offset + 8

            switch chunkID {
            case "fmt ":
                guard declaredSize >= 16, payloadStart + 16 <= data.count else {
                    throw ReplayError.invalidWAV("fmt chunk is truncated.")
                }
                guard payloadStart + declaredSize <= data.count else {
                    throw ReplayError.invalidWAV("fmt chunk size exceeds the file length.")
                }
                format = WAVFormat(
                    formatCode: readUInt16(data, at: payloadStart),
                    channelCount: readUInt16(data, at: payloadStart + 2),
                    sampleRate: readUInt32(data, at: payloadStart + 4),
                    bitsPerSample: readUInt16(data, at: payloadStart + 14)
                )
            case "data":
                let availableBytes = data.count - payloadStart
                guard availableBytes >= 0 else {
                    throw ReplayError.invalidWAV("data chunk is truncated.")
                }
                let declaredEnd = payloadStart + declaredSize
                let paddedDeclaredEnd = declaredEnd + (declaredSize % 2)
                if declaredSize <= availableBytes,
                   declaredEnd == data.count || paddedDeclaredEnd == data.count {
                    pcm16 = data.subdata(in: payloadStart..<declaredEnd)
                } else {
                    pcm16 = data.subdata(in: payloadStart..<data.count)
                }
                offset = data.count
                continue
            default:
                break
            }

            guard declaredSize <= data.count - payloadStart else {
                throw ReplayError.invalidWAV("\(chunkID) chunk size exceeds the file length.")
            }
            offset = payloadStart + declaredSize + (declaredSize % 2)
        }

        guard let format else {
            throw ReplayError.invalidWAV("Missing fmt chunk.")
        }
        guard format.formatCode == 1 else {
            throw ReplayError.invalidWAV("Expected PCM WAV format.")
        }
        guard format.channelCount == 1 else {
            throw ReplayError.invalidWAV("Expected mono WAV audio.")
        }
        guard format.sampleRate == UInt32(sampleRate) else {
            throw ReplayError.invalidWAV("Expected 16000 Hz WAV audio.")
        }
        guard format.bitsPerSample == 16 else {
            throw ReplayError.invalidWAV("Expected 16-bit WAV audio.")
        }
        guard let pcm16 else {
            throw ReplayError.invalidWAV("Missing data chunk.")
        }
        guard pcm16.count.isMultiple(of: bytesPerSample) else {
            throw ReplayError.invalidWAV("PCM16 data has an odd byte count.")
        }
        return pcm16
    }

    private static func replay(pcm16: Data, options: Options) throws {
        let chunkSampleCount = max(
            1,
            Int((Double(sampleRate) * Double(options.chunkMilliseconds) / 1_000.0).rounded())
        )
        let chunkByteCount = chunkSampleCount * bytesPerSample
        let configuration = options.useSettings
            ? SettingsStore().audioActivityTriggerConfiguration
            : AudioActivityTriggerConfiguration()
        var detector = AudioActivityTriggerDetector(configuration: configuration)
        var markerDetector = MarkerToneDetector(configuration: configuration.markerToneConfiguration)
        var offset = 0
        var totalSamples = 0
        var captureStartTimestamp: TimeInterval?
        var captureCount = 0
        var markerStartCount = 0
        var markerStopCount = 0

        while offset < pcm16.count {
            let end = min(offset + chunkByteCount, pcm16.count)
            let chunk = pcm16.subdata(in: offset..<end)
            let chunkStartSampleIndex = totalSamples
            totalSamples += chunk.count / bytesPerSample
            let timestamp = Double(totalSamples) / Double(sampleRate)

            guard let level = AudioActivityCaptureService.levelDBFS(pcm16: chunk) else {
                offset = end
                continue
            }
            if options.verbose {
                print("t=\(formatSeconds(timestamp)) level_dbfs=\(formatDBFS(level))")
            }

            let markerEvents = markerDetector.process(
                pcm16: chunk,
                startingAtSampleIndex: chunkStartSampleIndex
            )
            printMarkerEvents(
                markerEvents,
                markerStartCount: &markerStartCount,
                markerStopCount: &markerStopCount
            )

            switch detector.process(
                pcm16: chunk,
                levelDBFS: level,
                timestamp: timestamp,
                startingAtSampleIndex: chunkStartSampleIndex
            ) {
            case .started:
                captureCount += 1
                captureStartTimestamp = timestamp
                print("t=\(formatSeconds(timestamp)) event=started level_dbfs=\(formatDBFS(level))")
            case .stopped:
                let cause = detector.lastStopMarker == nil ? "level" : "marker"
                let duration = captureStartTimestamp.map { max(0, timestamp - $0) } ?? 0
                captureStartTimestamp = nil
                print(
                    "t=\(formatSeconds(timestamp)) event=stopped level_dbfs=\(formatDBFS(level)) cause=\(cause) duration_s=\(formatSeconds(duration))"
                )
            case nil:
                break
            }

            offset = end
        }

        printMarkerEvents(
            markerDetector.flush(),
            markerStartCount: &markerStartCount,
            markerStopCount: &markerStopCount
        )
        let duration = Double(pcm16.count / bytesPerSample) / Double(sampleRate)
        print(
            "summary duration_s=\(formatSeconds(duration)) captures=\(captureCount) marker_start_events=\(markerStartCount) marker_stop_events=\(markerStopCount)"
        )
    }

    private static func printMarkerEvents(
        _ events: [MarkerToneEvent],
        markerStartCount: inout Int,
        markerStopCount: inout Int
    ) {
        for event in events.sorted(by: { $0.sampleIndex < $1.sampleIndex }) {
            switch event.kind {
            case .start:
                markerStartCount += 1
            case .stop:
                markerStopCount += 1
            }
            let timestamp = Double(event.sampleIndex) / Double(sampleRate)
            print(
                "t=\(formatSeconds(timestamp)) marker=\(markerName(for: event.kind)) freq=\(formatFrequency(event.frequency)) purity=\(formatPurity(event.purity))"
            )
        }
    }

    private static func parse(arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--trigger-replay":
                break
            case "--help", "-h":
                options.showHelp = true
            case "--chunk-ms":
                let rawValue = try value(after: argument, in: arguments, at: &index)
                guard let milliseconds = Int(rawValue), milliseconds > 0 else {
                    throw ReplayError.invalidOption("--chunk-ms must be a positive integer.")
                }
                options.chunkMilliseconds = milliseconds
            case "--use-settings":
                options.useSettings = true
            case "--verbose":
                options.verbose = true
            default:
                if argument.hasPrefix("--") {
                    throw ReplayError.invalidOption("Unknown option: \(argument)")
                }
                if options.audioPath == nil {
                    options.audioPath = argument
                } else {
                    throw ReplayError.invalidOption("Unexpected argument: \(argument)")
                }
            }
            index += 1
        }
        return options
    }

    private static func value(after option: String, in arguments: [String], at index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw ReplayError.invalidOption("Missing value for \(option).")
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private static func asciiString(in range: Range<Int>, data: Data) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= data.count else {
            return nil
        }
        return String(data: data.subdata(in: range), encoding: .ascii)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset])
            | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { result, byteIndex in
            result | (UInt32(data[data.startIndex + offset + byteIndex]) << (8 * UInt32(byteIndex)))
        }
    }

    private static func markerName(for kind: MarkerToneKind) -> String {
        switch kind {
        case .start:
            return "start"
        case .stop:
            return "stop"
        }
    }

    private static func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }

    private static func formatDBFS(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func formatPurity(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func formatFrequency(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.001 {
            return String(Int(rounded))
        }
        return String(format: "%.1f", value)
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static var usage: String {
        """
        Usage:
          swift run groq-menubar-dictate --trigger-replay <wav-file> [--chunk-ms N] [--use-settings] [--verbose]

        Replays a 16 kHz mono PCM16 WAV dump through the ting trigger detector and prints marker and capture decisions.
        """
    }
}

private enum ReplayError: LocalizedError {
    case missingAudioPath
    case invalidOption(String)
    case invalidWAV(String)

    var errorDescription: String? {
        switch self {
        case .missingAudioPath:
            return "Missing WAV file path."
        case let .invalidOption(message):
            return message
        case let .invalidWAV(message):
            return message
        }
    }
}
