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
    private let sounds = SoundCuePlayer()
    private let logger = Logger(subsystem: "com.huntae.groq-menubar-dictate", category: "workflow")

    private lazy var optionTapRecognizer = OptionTapRecognizer(settingsProvider: { [weak self] in
        self?.settings.tapSettings ?? OptionTapSettings(minTapMilliseconds: 20, maxTapMilliseconds: 450, debounceMilliseconds: 250)
    })

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")

    private var state: State = .idle {
        didSet {
            refreshStatusItemAppearance()
        }
    }
    private var statusMessage = "Idle: tap Option to record."
    private var idleResetWorkItem: DispatchWorkItem?
    private var settingsWindowController: SettingsWindowController?

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
        setupStatusItem()
        setupMenu()
        optionTapRecognizer.onValidTap = { [weak self] in
            self?.handleOptionTap()
        }
        optionTapRecognizer.onEscapeKeyDown = { [weak self] in
            self?.handleEscapeKey()
        }
    }

    func start() {
        do {
            try customWords.ensureSeedFileExists()
            try filterWords.ensureFileExists()
            try endPrunePhrases.ensureFileExists()
        } catch {
            setError("Failed to prepare word files: \(error.localizedDescription)")
        }

        optionTapRecognizer.start()
        setIdleStatus("Idle: tap Option to record.", transientSeconds: nil)
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else {
            return
        }
        button.title = ""
        button.imagePosition = .imageOnly
        button.toolTip = statusMessage
    }

    private func setupMenu() {
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        menu.addItem(
            NSMenuItem(
                title: "Open Settings",
                action: #selector(openSettingsFromMenu),
                keyEquivalent: ","
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Test Permissions",
                action: #selector(testPermissionsFromMenu),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Open Custom Words File",
                action: #selector(openCustomWordsFromMenu),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Open Filter Words File",
                action: #selector(openFilterWordsFromMenu),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Open End Prune Phrases File",
                action: #selector(openEndPrunePhrasesFromMenu),
                keyEquivalent: ""
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit",
                action: #selector(quitFromMenu),
                keyEquivalent: "q"
            )
        )
        for item in menu.items {
            item.target = self
        }
        statusItem.menu = menu
        refreshStatusLine()
        refreshStatusItemAppearance()
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
            try recorder.startRecording()
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

        let fileURL: URL
        let stopRecordingStart = DispatchTime.now()
        do {
            fileURL = try recorder.stopRecording()
            timing.stopRecordingMilliseconds = millisecondsSince(stopRecordingStart)
        } catch {
            timing.result = "stop_recording_failed"
            timing.totalMilliseconds = millisecondsSince(flowStart)
            logWorkflowTimingIfEnabled(timing, diagnosticsEnabled: diagnosticsEnabled)
            setError("Failed to stop recording: \(error.localizedDescription)")
            return
        }

        setState(.transcribing, message: "Transcribing...")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let prepStart = DispatchTime.now()
        let apiKey = settings.apiKey
        let model = settings.model
        let language = settings.languageHint
        let maxAudioBytes = settings.maxAudioBytes
        let autoPasteEnabled = settings.autoPasteEnabled
        let endPruneEnabled = settings.endPruneEnabled
        let promptWords = customWords.loadWords(limit: 80)
        let prompt = CustomWordsStore.transcriptionPrompt(from: promptWords)
        let filterWordsList = filterWords.loadWords()
        let endPrunePhraseList = endPruneEnabled ? endPrunePhrases.loadPhrases() : EndPrunePhrasesStore.defaultPhrases
        timing.promptPreparationMilliseconds = millisecondsSince(prepStart)

        guard !apiKey.isEmpty else {
            timing.result = "missing_api_key"
            timing.totalMilliseconds = millisecondsSince(flowStart)
            logWorkflowTimingIfEnabled(timing, diagnosticsEnabled: diagnosticsEnabled)
            setError("Missing Groq API key. Open Settings.")
            return
        }

        do {
            let transcribeStart = DispatchTime.now()
            let response = try await transcriber.transcribe(
                fileURL: fileURL,
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
                to: response.transcript.text,
                words: filterWordsList,
                endPruneEnabled: endPruneEnabled,
                endPrunePhrases: endPrunePhraseList
            )
            let text = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
            timing.postProcessingMilliseconds = millisecondsSince(postProcessingStart)
            guard !text.isEmpty else {
                timing.result = "empty_transcript_after_filtering"
                timing.totalMilliseconds = millisecondsSince(flowStart)
                logWorkflowTimingIfEnabled(timing, diagnosticsEnabled: diagnosticsEnabled)
                setError("No speech detected (or fully removed by filters).")
                return
            }

            let clipboardStart = DispatchTime.now()
            guard clipboard.copyText(text) else {
                timing.clipboardMilliseconds = millisecondsSince(clipboardStart)
                timing.result = "clipboard_copy_failed"
                timing.totalMilliseconds = millisecondsSince(flowStart)
                logWorkflowTimingIfEnabled(timing, diagnosticsEnabled: diagnosticsEnabled)
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
                    setIdleStatus("Pasted transcript (\(text.count) chars).")
                } else {
                    timing.pasteMilliseconds = millisecondsSince(pasteStart)
                    timing.result = "copied_missing_post_permission"
                    timing.totalMilliseconds = millisecondsSince(flowStart)
                    logWorkflowTimingIfEnabled(timing, diagnosticsEnabled: diagnosticsEnabled)
                    setIdleStatus(
                        "Copied transcript. Auto-paste needs Post Keyboard Events permission.",
                        transientSeconds: 8
                    )
                }
            } else {
                timing.result = "copied"
                timing.totalMilliseconds = millisecondsSince(flowStart)
                logWorkflowTimingIfEnabled(timing, diagnosticsEnabled: diagnosticsEnabled)
                setIdleStatus("Copied transcript (\(text.count) chars).")
            }
        } catch {
            timing.result = "transcription_failed"
            timing.totalMilliseconds = millisecondsSince(flowStart)
            logWorkflowTimingIfEnabled(timing, diagnosticsEnabled: diagnosticsEnabled)
            setError("Transcription failed: \(error.localizedDescription)")
        }
    }

    private func abortRecordingFlow() {
        guard state == .recording else {
            return
        }
        do {
            let fileURL = try recorder.stopRecording()
            try? FileManager.default.removeItem(at: fileURL)
            setIdleStatus("Recording aborted.")
        } catch {
            setError("Failed to abort recording: \(error.localizedDescription)")
        }
    }

    private func setState(_ state: State, message: String) {
        idleResetWorkItem?.cancel()
        idleResetWorkItem = nil
        optionTapRecognizer.setEscapeInterceptionEnabled(state == .recording)
        self.state = state
        self.statusMessage = message
        refreshStatusLine()
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
            self.setState(.idle, message: "Idle: tap Option to record.")
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
                self.setState(.idle, message: "Idle: tap Option to record.")
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

    private func refreshStatusLine() {
        statusMenuItem.title = statusMessage
        statusItem.button?.toolTip = statusMessage
    }

    private func refreshStatusItemAppearance() {
        guard let button = statusItem.button else {
            return
        }

        switch state {
        case .idle:
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Idle")
            button.contentTintColor = nil
        case .recording:
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            button.contentTintColor = .systemRed
        case .transcribing:
            button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Transcribing")
            button.contentTintColor = nil
        case .error:
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")
            button.contentTintColor = .systemOrange
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
            model: settings.model,
            languageHint: settings.languageHint ?? ""
        )
        let controller = SettingsWindowController(
            snapshot: snapshot,
            onSave: { [weak self] snapshot in
                self?.applySettings(snapshot)
            },
            onOpenWordsFile: { [weak self] in
                self?.openCustomWordsFromMenu()
            },
            onOpenEndPrunePhrasesFile: { [weak self] in
                self?.openEndPrunePhrasesFromMenu()
            },
            onTestPermissions: { [weak self] in
                self?.showPermissionsDialog(promptForDialogs: true)
            }
        )
        settingsWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func applySettings(_ snapshot: SettingsSnapshot) {
        settings.autoPasteEnabled = snapshot.autoPasteEnabled
        settings.endPruneEnabled = snapshot.endPruneEnabled
        settings.performanceDiagnosticsEnabled = snapshot.performanceDiagnosticsEnabled
        settings.launchAtLoginEnabled = snapshot.launchAtLoginEnabled
        settings.apiKey = snapshot.apiKey
        settings.model = snapshot.model
        settings.languageHint = snapshot.languageHint
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

    private func showPermissionsDialog(promptForDialogs: Bool) {
        let lines = permissions.permissionSummary(promptForDialogs: promptForDialogs)
        let alert = NSAlert()
        alert.messageText = "Permission Status"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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

    private func resolvedExecutablePath() -> String {
        ExecutablePathResolver.resolve(arguments: CommandLine.arguments) ?? ""
    }

    private func ensureEventPermission(_ access: PermissionService.EventAccess) -> Bool {
        permissions.ensureEventAccess(access)
    }
}
