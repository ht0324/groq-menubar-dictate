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

    private enum RecordingSource {
        case manual
        case audioTrigger
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
    private let audioCapture = AudioActivityCaptureService()
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
    private var recordingSource: RecordingSource?
    private var isStartingRecording = false
    private var statusMessage = "Idle: tap Option to record."
    private var idleResetWorkItem: DispatchWorkItem?
    private var pendingRetryClip: RecordedClip?
    private var connectionKeepWarmTask: Task<Void, Never>?
    /// Utterances the ting captured while a previous clip was still
    /// transcribing; drained FIFO so nothing dictated back-to-back is lost.
    private var pendingTriggerClips: [RecordedClip] = []

    /// Shorter than typical server/client keep-alive idle timeouts so the
    /// prewarmed connection survives recordings longer than one ping.
    private static let connectionKeepWarmInterval: TimeInterval = 45

    override init() {
        super.init()
        menuBar.configure(
            target: self,
            actions: MenuBarActions(
                retryLastRecording: #selector(retryLastRecordingFromMenu),
                discardLastRecording: #selector(discardLastRecordingFromMenu),
                toggleAudioTrigger: #selector(toggleAudioTriggerFromMenu),
                openSettings: #selector(openSettingsFromMenu),
                testPermissions: #selector(testPermissionsFromMenu),
                quit: #selector(quitFromMenu)
            )
        )
        menuBar.updateAudioTriggerToggle(isOn: settings.audioActivityTriggerEnabled)
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
        audioCapture.onCaptureStarted = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleTriggerCaptureStarted()
            }
        }
        audioCapture.onCaptureFinished = { [weak self] clip in
            Task { @MainActor [weak self] in
                self?.handleTriggerCaptureFinished(clip)
            }
        }
        audioCapture.onCaptureCancelled = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleTriggerCaptureCancelled()
            }
        }
        audioCapture.onDeviceConnectionChanged = { [weak self] connected in
            Task { @MainActor [weak self] in
                self?.handleTriggerDeviceConnectionChanged(connected)
            }
        }
        audioCapture.onMonitorError = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.setError(message)
            }
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
        Task { [weak self] in
            await self?.updateAudioActivityTriggerMonitor()
        }
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
            requestStopOfActiveRecording()
        case .transcribing:
            return
        }
    }

    private func handleStopRequest() {
        guard state == .recording else {
            return
        }
        requestStopOfActiveRecording()
    }

    private func requestStopOfActiveRecording() {
        if recordingSource == .audioTrigger {
            // Finalization and transcription arrive via onCaptureFinished.
            audioCapture.finishActiveCapture()
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

    private func handleTriggerCaptureStarted() {
        switch state {
        case .idle, .error:
            recordingSource = .audioTrigger
            clearPendingRetryClip(deleteFile: true)
            setState(.recording, message: "Recording from ting... release the handle to transcribe.")
            sounds.playPing()
        case .recording:
            if recordingSource == .manual {
                // Never let line noise interfere with a manual session.
                audioCapture.cancelActiveCapture()
            }
        case .transcribing:
            // Keep capturing silently; the finished clip is queued and
            // transcribed as soon as the current one completes.
            return
        }
    }

    private func handleTriggerCaptureFinished(_ clip: RecordedClip) {
        if state == .recording, recordingSource == .audioTrigger {
            recordingSource = nil
            // Claim the transcription slot synchronously so nothing else can
            // start a parallel transcription before the task below runs.
            setState(.transcribing, message: "Transcribing...")
            Task { [weak self] in
                await self?.transcribeRecordedClip(
                    clip,
                    diagnosticsEnabled: self?.settings.performanceDiagnosticsEnabled ?? false,
                    flowStart: DispatchTime.now(),
                    initialTiming: WorkflowTiming(),
                    transcribingMessage: "Transcribing...",
                    suppressEmptyTranscriptError: true
                )
            }
            return
        }

        pendingTriggerClips.append(clip)
        drainPendingTriggerClipsIfIdle()
    }

    private func handleTriggerCaptureCancelled() {
        guard state == .recording, recordingSource == .audioTrigger else {
            return
        }
        recordingSource = nil
        setIdleStatus("Recording aborted.")
    }

    private func handleTriggerDeviceConnectionChanged(_ connected: Bool) {
        guard settings.audioActivityTriggerEnabled else {
            return
        }
        if connected {
            setIdleStatusIfIdle("ting connected — auto-record armed.")
        } else {
            setIdleStatusIfIdle("ting disconnected — auto-record paused.")
        }
    }

    private func drainPendingTriggerClipsIfIdle() {
        guard state == .idle || state == .error, !pendingTriggerClips.isEmpty else {
            return
        }
        let clip = pendingTriggerClips.removeFirst()
        // Claim the slot synchronously: a second clip finishing in the window
        // before the task starts must queue, not transcribe in parallel.
        setState(.transcribing, message: "Transcribing queued dictation...")
        Task { [weak self] in
            await self?.transcribeRecordedClip(
                clip,
                diagnosticsEnabled: self?.settings.performanceDiagnosticsEnabled ?? false,
                flowStart: DispatchTime.now(),
                initialTiming: WorkflowTiming(),
                transcribingMessage: "Transcribing queued dictation...",
                suppressEmptyTranscriptError: true
            )
        }
    }

    private func startRecordingFlow() async {
        guard state == .idle || state == .error, !isStartingRecording else {
            return
        }
        // Guards against a second tap arriving while the microphone permission
        // request below suspends this flow with state still .idle.
        isStartingRecording = true
        defer {
            isStartingRecording = false
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
            recordingSource = .manual
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
        guard state == .recording, recordingSource == .manual else {
            return
        }
        recordingSource = nil

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
        transcribingMessage: String,
        suppressEmptyTranscriptError: Bool = false
    ) async {
        defer {
            drainPendingTriggerClipsIfIdle()
        }
        var timing = initialTiming
        // Stat the file only when diagnostics are on; on the success path the
        // transcription service reports the size again through its metrics.
        if diagnosticsEnabled {
            timing.audioFileSizeBytes = audioFileSizeBytes(for: recordedClip.fileURL)
        }
        timing.recordingDurationSeconds = recordedClip.recorderReportedDurationSeconds
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
                timing.apply(metrics)
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
                if suppressEmptyTranscriptError {
                    // Expected for ting handle clunks captured without
                    // speech; don't beep or pollute the retry slot.
                    try? FileManager.default.removeItem(at: recordedClip.fileURL)
                    setIdleStatus("No speech detected.")
                } else {
                    preserveRecordingForRetry(recordedClip)
                    setError("No speech detected (or fully removed by filters).")
                }
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
        if recordingSource == .audioTrigger {
            // State cleanup happens via onCaptureCancelled.
            audioCapture.cancelActiveCapture()
            return
        }
        recordingSource = nil
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

        // The transcript is already delivered, so finish bookkeeping off the
        // critical path: measure the clip duration on a background task (an
        // AVAudioPlayer header decode) and persist stats back on the main actor.
        let fileURL = recordedClip.fileURL
        let recorderReportedDurationSeconds = recordedClip.recorderReportedDurationSeconds
        let persistHistory = settings.performanceDiagnosticsEnabled
        Task { [weak self] in
            let fileMeasuredDurationSeconds = await Task.detached {
                AudioRecorderService.fileDuration(at: fileURL)
            }.value
            guard let self else {
                return
            }
            self.dictationStats.recordSuccessfulSession(
                text: text,
                fileMeasuredDurationSeconds: fileMeasuredDurationSeconds,
                recorderReportedDurationSeconds: recorderReportedDurationSeconds,
                persistHistory: persistHistory
            )
            try? FileManager.default.removeItem(at: fileURL)
            self.refreshStatsMenu()
        }
    }

    private func setState(_ state: State, message: String) {
        idleResetWorkItem?.cancel()
        idleResetWorkItem = nil
        optionTapRecognizer.setStopOnOptionPressEnabled(state == .recording)
        optionTapRecognizer.setEscapeInterceptionEnabled(state == .recording)
        setConnectionKeepWarmEnabled(state == .recording)
        self.state = state
        self.statusMessage = message
        refreshMenuBarStatus()
    }

    private func setConnectionKeepWarmEnabled(_ enabled: Bool) {
        guard enabled else {
            connectionKeepWarmTask?.cancel()
            connectionKeepWarmTask = nil
            return
        }
        guard connectionKeepWarmTask == nil else {
            return
        }
        connectionKeepWarmTask = Task { [transcriber] in
            while !Task.isCancelled {
                await transcriber.prewarmConnection()
                try? await Task.sleep(nanoseconds: UInt64(Self.connectionKeepWarmInterval * 1_000_000_000))
            }
        }
    }

    private func setIdleStatusIfIdle(_ message: String) {
        guard state == .idle || state == .error else {
            return
        }
        setIdleStatus(message)
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

    private func audioFileSizeBytes(for fileURL: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    private func logWorkflowTimingIfEnabled(_ timing: WorkflowTiming, diagnosticsEnabled: Bool) {
        guard diagnosticsEnabled else {
            return
        }
        timing.log(to: logger)
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
            audioActivityTriggerEnabled: settings.audioActivityTriggerEnabled,
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
        settings.audioActivityTriggerEnabled = snapshot.audioActivityTriggerEnabled
        settings.microphoneInputMode = snapshot.microphoneInputMode
        settings.optionKeyMode = snapshot.optionKeyMode
        settings.apiKey = snapshot.apiKey
        settings.model = snapshot.model
        settings.languageHint = snapshot.languageHint
        settings.typingWordsPerMinute = snapshot.typingWordsPerMinute
        refreshStatsMenu()
        Task { [weak self] in
            await self?.updateAudioActivityTriggerMonitor()
        }
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

    private func updateAudioActivityTriggerMonitor() async {
        menuBar.updateAudioTriggerToggle(isOn: settings.audioActivityTriggerEnabled)
        guard settings.audioActivityTriggerEnabled else {
            audioCapture.setEnabled(false)
            return
        }

        // requestAccess reports the true grant state (immediately when already
        // authorized); the synchronous status snapshot can read stale at cold
        // launch. Never persist-disable the setting here — a transient false
        // negative would silently turn the feature off across restarts.
        guard await permissions.requestMicrophoneAccess() else {
            audioCapture.setEnabled(false)
            setError("Microphone permission denied; ting auto-record is paused until access is granted.")
            return
        }

        audioCapture.setEnabled(
            true,
            configuration: settings.audioActivityTriggerConfiguration,
            levelLoggingEnabled: settings.performanceDiagnosticsEnabled,
            rawDumpEnabled: settings.audioTriggerRawDumpEnabled
        )
        if !audioCapture.isDeviceConnected {
            setIdleStatusIfIdle("Auto-record armed — waiting for ting (\(AppConfig.tingInputDeviceName) input).")
        }
    }

    @objc private func toggleAudioTriggerFromMenu() {
        settings.audioActivityTriggerEnabled.toggle()
        let enabled = settings.audioActivityTriggerEnabled
        Task { [weak self] in
            await self?.updateAudioActivityTriggerMonitor()
            guard let self else {
                return
            }
            if enabled {
                self.setIdleStatusIfIdle(
                    self.audioCapture.isDeviceConnected
                        ? "ting auto-record on."
                        : "ting auto-record on — waiting for the adapter."
                )
            } else {
                self.setIdleStatusIfIdle("ting auto-record off.")
            }
        }
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
