import AppKit
import Foundation
import OSLog

@MainActor
final class AppCoordinator: NSObject {
    private enum State {
        case idle
        case recording
        case transcribing
        case error
    }

    private let settings = SettingsStore()
    private let customWords = CustomWordsStore()
    private let filterWords = FilterWordsStore()
    private let endPrunePhrases = EndPrunePhrasesStore()
    private let permissions = PermissionService()
    private let launchAtLogin = LaunchAtLoginService()
    private let recorder = AudioRecorderService()
    private let transcriber = GroqTranscriptionService()
    private let clipboard = ClipboardAndPasteService()
    private let dictationStats = DictationStatsStore()
    private let sounds = SoundCuePlayer()
    private let tempAudioCleanup = TempAudioCleanupService()
    private let menuBar = MenuBarController()
    private let logger = Logger(subsystem: "com.huntae.groq-menubar-dictate", category: "workflow")

    private lazy var optionTapRecognizer = OptionTapRecognizer(
        settingsProvider: { [settings] in
            settings.tapSettings
        },
        optionKeyModeProvider: { [settings] in
            settings.optionKeyMode
        }
    )

    private var state: State = .idle
    private var statusMessage = "Idle: tap Option to record."
    private var idleResetWorkItem: DispatchWorkItem?
    private var pendingRetryClip: RecordedClip?

    private struct WorkflowTiming {
        var stopRecordingMilliseconds: Double = 0
        var promptPreparationMilliseconds: Double = 0
        var transcriptionMilliseconds: Double = 0
        var uploadPreparationMilliseconds: Double = 0
        var networkRoundTripMilliseconds: Double = 0
        var responseParseMilliseconds: Double = 0
        var postProcessingMilliseconds: Double = 0
        var clipboardMilliseconds: Double = 0
        var pasteMilliseconds: Double?
        var totalMilliseconds: Double = 0
        var result: String = "unknown"
    }

    override init() {
        super.init()
        menuBar.configure(
            target: self,
            actions: MenuBarActions(
                retryLastRecording: #selector(retryLastRecordingFromMenu),
                discardLastRecording: #selector(discardLastRecordingFromMenu),
                openSettings: #selector(openSettingsFromMenu),
                testPermissions: #selector(testPermissionsFromMenu),
                quit: #selector(quitFromMenu)
            )
        )
        refreshStatsMenu()
        refreshMenuBarStatus()
        optionTapRecognizer.onValidTap = { [weak self] in
            self?.handleOptionTap()
        }
        optionTapRecognizer.onStopRequested = { [weak self] in
            self?.handleStopRequest()
        }
        optionTapRecognizer.onEscapeKeyDown = { [weak self] in
            self?.handleEscapeKey()
        }
    }

    func start() {
        let cleanupReport = tempAudioCleanup.cleanupStaleFiles()
        if cleanupReport.removedCount > 0 || cleanupReport.failedCount > 0 {
            logger.info(
                "Temp audio cleanup scanned=\(cleanupReport.scannedCount, privacy: .public) removed=\(cleanupReport.removedCount, privacy: .public) failed=\(cleanupReport.failedCount, privacy: .public)"
            )
        }

        do {
            try customWords.ensureSeedFileExists()
            try filterWords.ensureFileExists()
            try endPrunePhrases.ensureFileExists()
        } catch {
            setError("Failed to prepare word files: \(error.localizedDescription)")
            return
        }

        optionTapRecognizer.start()
        logSuspiciousStatsIfNeeded()
        presentSetupGuidanceIfNeeded()
    }

    private func handleOptionTap() {
        switch state {
        case .idle, .error:
            Task { [weak self] in
                await self?.startRecordingFlow()
            }
        case .recording:
            Task { [weak self] in
                await self?.stopAndTranscribeFlow()
            }
        case .transcribing:
            return
        }
    }

    private func handleStopRequest() {
        guard state == .recording else {
            return
        }
        Task { [weak self] in
            await self?.stopAndTranscribeFlow()
        }
    }

    private func handleEscapeKey() {
        guard state == .recording else {
            return
        }
        abortRecordingFlow()
    }

    private func startRecordingFlow() async {
        guard state == .idle || state == .error else {
            return
        }

        let status = permissions.microphoneAuthorizationStatus()
        let allowed: Bool
        switch status {
        case .authorized:
            allowed = true
        case .notDetermined:
            allowed = await permissions.requestMicrophoneAccess()
        case .denied, .restricted:
            allowed = false
        @unknown default:
            allowed = false
        }

        guard allowed else {
            setError("Microphone permission denied.")
            return
        }

        do {
            try recorder.startRecording(mode: settings.microphoneInputMode)
            clearPendingRetryClip(deleteFile: true)
            let hasListen = ensureEventPermission(.listen)
            if hasListen {
                setState(.recording, message: "Recording... tap Option to stop (Esc aborts).")
            } else {
                setState(.recording, message: "Recording... tap Option to stop. (Esc abort unavailable: Input Monitoring missing)")
            }
            sounds.playPing()
        } catch {
            setError("Failed to start recording: \(error.localizedDescription)")
        }
    }

    private func stopAndTranscribeFlow() async {
        guard state == .recording else {
            return
        }

        let diagnosticsEnabled = settings.performanceDiagnosticsEnabled
        let flowStart = DispatchTime.now()
        var timing = WorkflowTiming()

        let recordedClip: RecordedClip
        let stopRecordingStart = DispatchTime.now()
        do {
            recordedClip = try recorder.stopRecording()
            timing.stopRecordingMilliseconds = millisecondsSince(stopRecordingStart)
        } catch {
            timing.result = "stop_recording_failed"
            timing.totalMilliseconds = millisecondsSince(flowStart)
            logWorkflowTimingIfEnabled(timing, diagnosticsEnabled: diagnosticsEnabled)
            setError("Failed to stop recording: \(error.localizedDescription)")
            return
        }

        await transcribeRecordedClip(
            recordedClip,
            diagnosticsEnabled: diagnosticsEnabled,
            flowStart: flowStart,
            initialTiming: timing,
            transcribingMessage: "Transcribing..."
        )
    }

    private func retryLastRecordingFlow() async {
        guard state == .idle || state == .error else {
            return
        }
        guard let recordedClip = pendingRetryClip else {
            return
        }
        guard FileManager.default.fileExists(atPath: recordedClip.fileURL.path) else {
            clearPendingRetryClip(deleteFile: false)
            setError("Last recording file is no longer available.")
            return
        }

        await transcribeRecordedClip(
            recordedClip,
            diagnosticsEnabled: settings.performanceDiagnosticsEnabled,
            flowStart: DispatchTime.now(),
            initialTiming: WorkflowTiming(),
            transcribingMessage: "Retrying last recording..."
        )
    }

    private func transcribeRecordedClip(
        _ recordedClip: RecordedClip,
        diagnosticsEnabled: Bool,
        flowStart: DispatchTime,
        initialTiming: WorkflowTiming,
        transcribingMessage: String
    ) async {
        var timing = initialTiming
        setState(.transcribing, message: transcribingMessage)
        let prepStart = DispatchTime.now()
        let apiKey = settings.apiKey
        let model = settings.model
        let language = settings.languageHint
        let maxAudioBytes = settings.maxAudioBytes
        let autoPasteEnabled = settings.autoPasteEnabled
        let endPruneEnabled = settings.endPruneEnabled
        let promptWords = customWords.loadWords(limit: 80)
        let prompt = CustomWordsStore.transcriptionPrompt(from: promptWords)
        let endPrunePhraseList = endPruneEnabled ? endPrunePhrases.loadPhrases() : EndPrunePhrasesStore.defaultPhrases
        timing.promptPreparationMilliseconds = millisecondsSince(prepStart)

        guard !apiKey.isEmpty else {
            timing.result = "missing_api_key"
            timing.totalMilliseconds = millisecondsSince(flowStart)
            logWorkflowTimingIfEnabled(timing, diagnosticsEnabled: diagnosticsEnabled)
            preserveRecordingForRetry(recordedClip)
            setError("Missing Groq API key. Open Settings.")
            return
        }

        do {
            let transcribeStart = DispatchTime.now()
            let response = try await transcriber.transcribe(
                fileURL: recordedClip.fileURL,
                apiKey: apiKey,
                model: model,
                language: language,
                prompt: prompt,
                maxAudioBytes: maxAudioBytes,
                collectMetrics: diagnosticsEnabled
            )
            timing.transcriptionMilliseconds = millisecondsSince(transcribeStart)
            if let metrics = response.metrics {
                timing.uploadPreparationMilliseconds = metrics.uploadPreparationMilliseconds
                timing.networkRoundTripMilliseconds = metrics.networkRoundTripMilliseconds
                timing.responseParseMilliseconds = metrics.responseParseMilliseconds
            }

            let postProcessingStart = DispatchTime.now()
            let filtered = filterWords.applyFilters(
                to: response.text,
                endPruneEnabled: endPruneEnabled,
                endPrunePhrases: endPrunePhraseList
            )
            let text = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
            timing.postProcessingMilliseconds = millisecondsSince(postProcessingStart)
            guard !text.isEmpty else {
                timing.result = "empty_transcript_after_filtering"
                timing.totalMilliseconds = millisecondsSince(flowStart)
                logWorkflowTimingIfEnabled(timing, diagnosticsEnabled: diagnosticsEnabled)
                preserveRecordingForRetry(recordedClip)
                setError("No speech detected (or fully removed by filters).")
                return
            }

            let clipboardStart = DispatchTime.now()
            guard clipboard.copyText(text) else {
                timing.clipboardMilliseconds = millisecondsSince(clipboardStart)
                timing.result = "clipboard_copy_failed"
                timing.totalMilliseconds = millisecondsSince(flowStart)
                logWorkflowTimingIfEnabled(timing, diagnosticsEnabled: diagnosticsEnabled)
                preserveRecordingForRetry(recordedClip)
                setError("Failed to copy transcript.")
                return
            }
            timing.clipboardMilliseconds = millisecondsSince(clipboardStart)

            if autoPasteEnabled {
                let pasteStart = DispatchTime.now()
                let canPost = ensureEventPermission(.post)
                if canPost, clipboard.pasteFromClipboard() {
                    timing.pasteMilliseconds = millisecondsSince(pasteStart)
                    timing.result = "pasted"
                    timing.totalMilliseconds = millisecondsSince(flowStart)
                    logWorkflowTimingIfEnabled(timing, diagnosticsEnabled: diagnosticsEnabled)
                    finalizeSuccessfulTranscriptDelivery(
                        text: text,
                        recordedClip: recordedClip,
                        statusMessage: "Pasted transcript (\(text.count) chars)."
                    )
                } else {
                    timing.pasteMilliseconds = millisecondsSince(pasteStart)
                    timing.result = "copied_missing_post_permission"
                    timing.totalMilliseconds = millisecondsSince(flowStart)
                    logWorkflowTimingIfEnabled(timing, diagnosticsEnabled: diagnosticsEnabled)
                    finalizeSuccessfulTranscriptDelivery(
                        text: text,
                        recordedClip: recordedClip,
                        statusMessage: "Copied transcript. Auto-paste needs Post Keyboard Events permission.",
                        transientSeconds: 8
                    )
                }
            } else {
                timing.result = "copied"
                timing.totalMilliseconds = millisecondsSince(flowStart)
                logWorkflowTimingIfEnabled(timing, diagnosticsEnabled: diagnosticsEnabled)
                finalizeSuccessfulTranscriptDelivery(
                    text: text,
                    recordedClip: recordedClip,
                    statusMessage: "Copied transcript (\(text.count) chars)."
                )
            }
        } catch {
            timing.result = "transcription_failed"
            timing.totalMilliseconds = millisecondsSince(flowStart)
            logWorkflowTimingIfEnabled(timing, diagnosticsEnabled: diagnosticsEnabled)
            preserveRecordingForRetry(recordedClip)
            setError("Transcription failed: \(error.localizedDescription)")
        }
    }

    private func abortRecordingFlow() {
        guard state == .recording else {
            return
        }
        do {
            let recordedClip = try recorder.stopRecording()
            try? FileManager.default.removeItem(at: recordedClip.fileURL)
            setIdleStatus("Recording aborted.")
        } catch {
            setError("Failed to abort recording: \(error.localizedDescription)")
        }
    }

    private func finalizeSuccessfulTranscriptDelivery(
        text: String,
        recordedClip: RecordedClip,
        statusMessage: String,
        transientSeconds: TimeInterval? = 4
    ) {
        clearPendingRetryClipIfMatching(recordedClip, deleteFile: false)
        setIdleStatus(statusMessage, transientSeconds: transientSeconds)
        let fileMeasuredDurationSeconds = recorder.recordedFileDuration(for: recordedClip.fileURL)
        dictationStats.recordSuccessfulSession(
            text: text,
            fileMeasuredDurationSeconds: fileMeasuredDurationSeconds,
            recorderReportedDurationSeconds: recordedClip.recorderReportedDurationSeconds
        )
        try? FileManager.default.removeItem(at: recordedClip.fileURL)
        refreshStatsMenu()
    }

    private func setState(_ state: State, message: String) {
        idleResetWorkItem?.cancel()
        idleResetWorkItem = nil
        optionTapRecognizer.setStopOnOptionPressEnabled(state == .recording)
        optionTapRecognizer.setEscapeInterceptionEnabled(state == .recording)
        self.state = state
        self.statusMessage = message
        refreshMenuBarStatus()
    }

    private func setIdleStatus(_ message: String, transientSeconds: TimeInterval? = 4) {
        setState(.idle, message: message)
        guard let transientSeconds else {
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .idle else {
                return
            }
            self.setState(.idle, message: self.defaultIdleMessage)
        }
        idleResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + transientSeconds, execute: work)
    }

    private func setError(_ message: String) {
        setState(.error, message: message)
        sounds.playErrorBeep()
        let work = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            if self.state == .error {
                self.setState(.idle, message: self.defaultIdleMessage)
            }
        }
        idleResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func millisecondsSince(_ start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private func logWorkflowTimingIfEnabled(_ timing: WorkflowTiming, diagnosticsEnabled: Bool) {
        guard diagnosticsEnabled else {
            return
        }
        let pasteMilliseconds = timing.pasteMilliseconds ?? -1
        logger.info(
            "Workflow timing result=\(timing.result, privacy: .public) total_ms=\(timing.totalMilliseconds, format: .fixed(precision: 1)) stop_ms=\(timing.stopRecordingMilliseconds, format: .fixed(precision: 1)) prep_ms=\(timing.promptPreparationMilliseconds, format: .fixed(precision: 1)) transcribe_ms=\(timing.transcriptionMilliseconds, format: .fixed(precision: 1)) upload_prep_ms=\(timing.uploadPreparationMilliseconds, format: .fixed(precision: 1)) network_ms=\(timing.networkRoundTripMilliseconds, format: .fixed(precision: 1)) parse_ms=\(timing.responseParseMilliseconds, format: .fixed(precision: 1)) post_ms=\(timing.postProcessingMilliseconds, format: .fixed(precision: 1)) clipboard_ms=\(timing.clipboardMilliseconds, format: .fixed(precision: 1)) paste_ms=\(pasteMilliseconds, format: .fixed(precision: 1))"
        )
    }

    private func refreshStatsMenu() {
        let summary = dictationStats.snapshot.summary(
            typingWordsPerMinute: settings.typingWordsPerMinute
        )
        menuBar.updateStats(
            summary: summary,
            target: self,
            resetAction: #selector(resetStatsFromMenu)
        )
    }

    private func refreshMenuBarStatus() {
        menuBar.updateStatus(message: statusMessage, state: menuBarStatusState)
        menuBar.updateRetryControls(
            isAvailable: pendingRetryClip != nil,
            isEnabled: pendingRetryClip != nil && (state == .idle || state == .error)
        )
    }

    private var defaultIdleMessage: String {
        if pendingRetryClip != nil {
            return "Idle: retry last recording or tap Option to record."
        }
        return "Idle: tap Option to record."
    }

    private var menuBarStatusState: MenuBarStatusState {
        switch state {
        case .idle:
            return .idle
        case .recording:
            return .recording
        case .transcribing:
            return .transcribing
        case .error:
            return .error
        }
    }

    @objc private func openSettingsFromMenu() {
        let launchAtLoginEnabled = launchAtLogin.isEnabled
        settings.launchAtLoginEnabled = launchAtLoginEnabled
        let snapshot = SettingsSnapshot(
            apiKey: settings.apiKey,
            autoPasteEnabled: settings.autoPasteEnabled,
            endPruneEnabled: settings.endPruneEnabled,
            performanceDiagnosticsEnabled: settings.performanceDiagnosticsEnabled,
            launchAtLoginEnabled: launchAtLoginEnabled,
            microphoneInputMode: settings.microphoneInputMode,
            optionKeyMode: settings.optionKeyMode,
            model: settings.model,
            languageHint: settings.languageHint ?? "",
            typingWordsPerMinute: settings.typingWordsPerMinute
        )
        menuBar.showSettings(
            snapshot: snapshot,
            onSave: { [weak self] snapshot in
                self?.applySettings(snapshot)
            },
            onOpenWordsFile: { [weak self] in
                self?.openCustomWordsFromMenu()
            },
            onOpenFilterWordsFile: { [weak self] in
                self?.openFilterWordsFromMenu()
            },
            onOpenEndPrunePhrasesFile: { [weak self] in
                self?.openEndPrunePhrasesFromMenu()
            },
            onTestPermissions: { [weak self] in
                self?.showPermissionsDialog(promptForDialogs: true)
            }
        )
    }

    private func applySettings(_ snapshot: SettingsSnapshot) {
        settings.autoPasteEnabled = snapshot.autoPasteEnabled
        settings.endPruneEnabled = snapshot.endPruneEnabled
        settings.performanceDiagnosticsEnabled = snapshot.performanceDiagnosticsEnabled
        settings.launchAtLoginEnabled = snapshot.launchAtLoginEnabled
        settings.microphoneInputMode = snapshot.microphoneInputMode
        settings.optionKeyMode = snapshot.optionKeyMode
        settings.apiKey = snapshot.apiKey
        settings.model = snapshot.model
        settings.languageHint = snapshot.languageHint
        settings.typingWordsPerMinute = snapshot.typingWordsPerMinute
        refreshStatsMenu()
        do {
            try launchAtLogin.setEnabled(
                snapshot.launchAtLoginEnabled,
                executablePath: resolvedExecutablePath()
            )
            setIdleStatus("Settings saved.")
        } catch {
            setError("Failed to update launch-at-login: \(error.localizedDescription)")
        }
    }

    @objc private func testPermissionsFromMenu() {
        showPermissionsDialog(promptForDialogs: true)
    }

    @objc private func retryLastRecordingFromMenu() {
        Task { [weak self] in
            await self?.retryLastRecordingFlow()
        }
    }

    @objc private func discardLastRecordingFromMenu() {
        guard state == .idle || state == .error else {
            return
        }
        guard clearPendingRetryClip(deleteFile: true) else {
            return
        }
        setIdleStatus("Discarded last recording.")
    }

    private func showPermissionsDialog(promptForDialogs: Bool) {
        let lines = permissions.permissionSummary(promptForDialogs: promptForDialogs)
        menuBar.showPermissionSummary(lines)
    }

    @objc private func openCustomWordsFromMenu() {
        do {
            try customWords.openWordsFile()
            setIdleStatus("Opened custom words file.")
        } catch {
            setError("Failed to open words file: \(error.localizedDescription)")
        }
    }

    @objc private func openFilterWordsFromMenu() {
        do {
            try filterWords.openWordsFile()
            setIdleStatus("Opened filter words file.")
        } catch {
            setError("Failed to open filter words file: \(error.localizedDescription)")
        }
    }

    @objc private func openEndPrunePhrasesFromMenu() {
        do {
            try endPrunePhrases.openPhrasesFile()
            setIdleStatus("Opened end prune phrases file.")
        } catch {
            setError("Failed to open end prune phrases file: \(error.localizedDescription)")
        }
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc private func resetStatsFromMenu() {
        dictationStats.reset()
        refreshStatsMenu()
        setIdleStatus("Dictation stats reset.")
    }

    private func resolvedExecutablePath() -> String {
        ExecutablePathResolver.resolve(arguments: CommandLine.arguments) ?? ""
    }

    private func ensureEventPermission(_ access: PermissionService.EventAccess) -> Bool {
        permissions.ensureEventAccess(access)
    }

    private func logSuspiciousStatsIfNeeded() {
        let snapshot = dictationStats.snapshot
        guard case let .suspicious(message) = snapshot.healthStatus else {
            return
        }
        logger.error(
            "Stats aggregate looks suspicious sessions=\(snapshot.successfulSessions, privacy: .public) words=\(snapshot.totalWords, privacy: .public) recording_s=\(snapshot.totalRecordingSeconds, format: .fixed(precision: 3)) reason=\(message, privacy: .public)"
        )
    }

    private func presentSetupGuidanceIfNeeded() {
        let missingAPIKey = settings.apiKey.isEmpty
        let missingListenPermission = !permissions.hasEventAccess(.listen)

        guard missingAPIKey || missingListenPermission else {
            setIdleStatus("Idle: tap Option to record.", transientSeconds: nil)
            return
        }

        if missingAPIKey {
            setIdleStatus("Setup required: add your Groq API key in Settings.", transientSeconds: nil)
        } else {
            setIdleStatus("Setup required: grant Input Monitoring via Test Permissions.", transientSeconds: nil)
        }

        if menuBar.showSetupGuidance(
            missingAPIKey: missingAPIKey,
            missingListenPermission: missingListenPermission
        ) {
            openSettingsFromMenu()
        }
    }

    @discardableResult
    private func clearPendingRetryClip(deleteFile: Bool) -> Bool {
        guard let pendingRetryClip else {
            return false
        }
        self.pendingRetryClip = nil
        if deleteFile {
            try? FileManager.default.removeItem(at: pendingRetryClip.fileURL)
        }
        refreshMenuBarStatus()
        return true
    }

    private func clearPendingRetryClipIfMatching(_ recordedClip: RecordedClip, deleteFile: Bool) {
        guard pendingRetryClip?.fileURL == recordedClip.fileURL else {
            return
        }
        _ = clearPendingRetryClip(deleteFile: deleteFile)
    }

    private func preserveRecordingForRetry(_ recordedClip: RecordedClip) {
        guard FileManager.default.fileExists(atPath: recordedClip.fileURL.path) else {
            return
        }
        if pendingRetryClip?.fileURL != recordedClip.fileURL {
            clearPendingRetryClip(deleteFile: true)
        }
        pendingRetryClip = recordedClip
        refreshMenuBarStatus()
    }
}
