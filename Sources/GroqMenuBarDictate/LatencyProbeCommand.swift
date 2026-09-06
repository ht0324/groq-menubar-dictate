import AppKit
import Foundation

enum LatencyProbeCommand {
    private struct Options {
        var audioPath: String?
        var apiKey: String?
        var model: String?
        var language: String?
        var timeout: TimeInterval = 20
        var restoreClipboard = true
        var showHelp = false
    }

    private struct PasteboardSnapshot {
        let items: [NSPasteboardItem]

        static func capture() -> PasteboardSnapshot {
            let copiedItems: [NSPasteboardItem] = NSPasteboard.general.pasteboardItems?.map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        copy.setData(data, forType: type)
                    } else if let string = item.string(forType: type) {
                        copy.setString(string, forType: type)
                    }
                }
                return copy
            } ?? []
            return PasteboardSnapshot(items: copiedItems)
        }

        func restore() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard !items.isEmpty else {
                return
            }
            pasteboard.writeObjects(items)
        }
    }

    static func shouldRun(arguments: [String]) -> Bool {
        arguments.dropFirst().contains("--latency-probe")
    }

    @MainActor
    static func run(arguments: [String]) async -> Int32 {
        do {
            let options = try parse(arguments: Array(arguments.dropFirst()))
            if options.showHelp {
                print(usage)
                return 0
            }

            guard let audioPath = options.audioPath else {
                throw ProbeError.missingAudioPath
            }

            let apiKey = resolvedAPIKey(explicitAPIKey: options.apiKey)
            guard !apiKey.isEmpty else {
                throw ProbeError.missingAPIKey
            }

            let audioURL = URL(fileURLWithPath: audioPath)
            let settings = SettingsStore()
            let model = options.model ?? resolvedEnvironmentValue("GROQ_MODEL") ?? settings.model
            let language = options.language ?? resolvedEnvironmentValue("GROQ_LANGUAGE") ?? settings.languageHint
            let maxAudioBytes = settings.maxAudioBytes
            let clipboard = ClipboardAndPasteService()
            let transcriber = GroqTranscriptionService()
            let filterWords = FilterWordsStore()
            try filterWords.ensureFilesExist()

            let totalStart = DispatchTime.now()
            let prepStart = DispatchTime.now()
            let prompt = CustomWordsStore().transcriptionPrompt()
            let endPruneEnabled = settings.endPruneEnabled
            let audioDurationSeconds = AudioRecorderService.fileDuration(at: audioURL)
            let prepMilliseconds = millisecondsSince(prepStart)

            let transcribeStart = DispatchTime.now()
            let response = try await transcriber.transcribe(
                fileURL: audioURL,
                apiKey: apiKey,
                model: model,
                language: language,
                prompt: prompt,
                maxAudioBytes: maxAudioBytes,
                timeout: options.timeout,
                collectMetrics: true
            )
            let transcriptionMilliseconds = millisecondsSince(transcribeStart)

            let postProcessingStart = DispatchTime.now()
            let filtered = filterWords.applyFilters(
                to: response.text,
                endPruneEnabled: endPruneEnabled
            )
            let text = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
            let postProcessingMilliseconds = millisecondsSince(postProcessingStart)
            guard !text.isEmpty else {
                throw ProbeError.emptyTranscript
            }

            let pasteboardSnapshot = options.restoreClipboard ? PasteboardSnapshot.capture() : nil
            defer {
                pasteboardSnapshot?.restore()
            }

            let clipboardStart = DispatchTime.now()
            guard clipboard.copyText(text) else {
                throw ProbeError.clipboardCopyFailed
            }
            let clipboardMilliseconds = millisecondsSince(clipboardStart)

            let pasteSimulationStart = DispatchTime.now()
            let pastedText = NSPasteboard.general.string(forType: .string) ?? ""
            let pasteSimulationMilliseconds = millisecondsSince(pasteSimulationStart)
            let totalMilliseconds = millisecondsSince(totalStart)

            printSuccessLine(
                audioDurationSeconds: audioDurationSeconds,
                metrics: response.metrics,
                textCharacterCount: text.count,
                pastedCharacterCount: pastedText.count,
                prepMilliseconds: prepMilliseconds,
                transcriptionMilliseconds: transcriptionMilliseconds,
                postProcessingMilliseconds: postProcessingMilliseconds,
                clipboardMilliseconds: clipboardMilliseconds,
                pasteSimulationMilliseconds: pasteSimulationMilliseconds,
                totalMilliseconds: totalMilliseconds,
                restoredClipboard: options.restoreClipboard
            )
            return 0
        } catch {
            fputs("latency_probe result=failed error=\"\(escape(error.localizedDescription))\"\n", stderr)
            fputs("\n\(usage)\n", stderr)
            return 1
        }
    }

    private static func parse(arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--latency-probe":
                break
            case "--help", "-h":
                options.showHelp = true
            case "--api-key":
                options.apiKey = try value(after: argument, in: arguments, at: &index)
            case "--model":
                options.model = try value(after: argument, in: arguments, at: &index)
            case "--language":
                options.language = try value(after: argument, in: arguments, at: &index)
            case "--timeout":
                let rawValue = try value(after: argument, in: arguments, at: &index)
                guard let timeout = TimeInterval(rawValue), timeout > 0 else {
                    throw ProbeError.invalidOption("--timeout must be a positive number.")
                }
                options.timeout = timeout
            case "--keep-clipboard":
                options.restoreClipboard = false
            default:
                if argument.hasPrefix("--") {
                    throw ProbeError.invalidOption("Unknown option: \(argument)")
                }
                if options.audioPath == nil {
                    options.audioPath = argument
                } else {
                    throw ProbeError.invalidOption("Unexpected argument: \(argument)")
                }
            }
            index += 1
        }
        return options
    }

    private static func value(after option: String, in arguments: [String], at index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw ProbeError.invalidOption("Missing value for \(option).")
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private static func resolvedAPIKey(explicitAPIKey: String?) -> String {
        if let explicitAPIKey, !explicitAPIKey.isEmpty {
            return explicitAPIKey
        }
        if let environmentAPIKey = resolvedEnvironmentValue("GROQ_API_KEY") {
            return environmentAPIKey
        }
        let standardAPIKey = SettingsStore().apiKey
        if !standardAPIKey.isEmpty {
            return standardAPIKey
        }
        if let bundleDefaults = UserDefaults(suiteName: AppConfig.bundleIdentifier) {
            let bundleAPIKey = SettingsStore(defaults: bundleDefaults).apiKey
            if !bundleAPIKey.isEmpty {
                return bundleAPIKey
            }
        }
        return ""
    }

    private static func resolvedEnvironmentValue(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func printSuccessLine(
        audioDurationSeconds: TimeInterval?,
        metrics: TranscriptionMetrics?,
        textCharacterCount: Int,
        pastedCharacterCount: Int,
        prepMilliseconds: Double,
        transcriptionMilliseconds: Double,
        postProcessingMilliseconds: Double,
        clipboardMilliseconds: Double,
        pasteSimulationMilliseconds: Double,
        totalMilliseconds: Double,
        restoredClipboard: Bool
    ) {
        let taskMetrics = metrics?.urlSessionTaskMetrics
        let fields = [
            "latency_probe",
            "result=ok",
            "audio_bytes=\(metrics?.audioFileSizeBytes ?? -1)",
            "audio_duration_s=\(formatSeconds(audioDurationSeconds))",
            "upload_body_bytes=\(metrics?.uploadBodySizeBytes ?? -1)",
            "text_chars=\(textCharacterCount)",
            "pasted_chars=\(pastedCharacterCount)",
            "total_ms=\(formatMilliseconds(totalMilliseconds))",
            "prep_ms=\(formatMilliseconds(prepMilliseconds))",
            "transcribe_ms=\(formatMilliseconds(transcriptionMilliseconds))",
            "upload_prep_ms=\(formatMilliseconds(metrics?.uploadPreparationMilliseconds))",
            "network_ms=\(formatMilliseconds(metrics?.networkRoundTripMilliseconds))",
            "task_interval_ms=\(formatMilliseconds(taskMetrics?.taskIntervalMilliseconds))",
            "fetch_to_response_end_ms=\(formatMilliseconds(taskMetrics?.fetchToResponseEndMilliseconds))",
            "dns_ms=\(formatMilliseconds(taskMetrics?.domainLookupMilliseconds))",
            "tcp_ms=\(formatMilliseconds(taskMetrics?.tcpConnectionMilliseconds))",
            "tls_ms=\(formatMilliseconds(taskMetrics?.tlsHandshakeMilliseconds))",
            "request_upload_ms=\(formatMilliseconds(taskMetrics?.requestUploadMilliseconds))",
            "first_byte_wait_ms=\(formatMilliseconds(taskMetrics?.timeToFirstByteAfterUploadMilliseconds))",
            "response_download_ms=\(formatMilliseconds(taskMetrics?.responseDownloadMilliseconds))",
            "reused_connection=\(formatBool(taskMetrics?.isReusedConnection))",
            "network_protocol=\(taskMetrics?.networkProtocolName ?? "unknown")",
            "parse_ms=\(formatMilliseconds(metrics?.responseParseMilliseconds))",
            "post_ms=\(formatMilliseconds(postProcessingMilliseconds))",
            "clipboard_ms=\(formatMilliseconds(clipboardMilliseconds))",
            "paste_sim_ms=\(formatMilliseconds(pasteSimulationMilliseconds))",
            "clipboard_restored=\(restoredClipboard ? "true" : "false")",
        ]
        print(fields.joined(separator: " "))
    }

    private static func formatMilliseconds(_ value: Double?) -> String {
        guard let value else {
            return "-1.0"
        }
        return String(format: "%.1f", value)
    }

    private static func formatSeconds(_ value: TimeInterval?) -> String {
        guard let value else {
            return "-1.000"
        }
        return String(format: "%.3f", value)
    }

    private static func formatBool(_ value: Bool?) -> String {
        guard let value else {
            return "unknown"
        }
        return value ? "true" : "false"
    }

    private static func millisecondsSince(_ start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static var usage: String {
        """
        Usage:
          swift run Bolt --latency-probe <audio-file> [--api-key <key>] [--model <model>] [--language <hint>] [--timeout <seconds>] [--keep-clipboard]

        API key resolution order:
          --api-key, GROQ_API_KEY, app settings.

        The probe uploads the audio to Groq, post-processes the transcript, copies it to the clipboard, safely simulates paste by reading the pasteboard, and restores the previous clipboard unless --keep-clipboard is set.
        """
    }
}

private enum ProbeError: LocalizedError {
    case missingAudioPath
    case missingAPIKey
    case emptyTranscript
    case clipboardCopyFailed
    case invalidOption(String)

    var errorDescription: String? {
        switch self {
        case .missingAudioPath:
            return "Missing audio file path."
        case .missingAPIKey:
            return "Missing Groq API key."
        case .emptyTranscript:
            return "Transcript was empty after filtering."
        case .clipboardCopyFailed:
            return "Failed to copy transcript to the clipboard."
        case let .invalidOption(message):
            return message
        }
    }
}
