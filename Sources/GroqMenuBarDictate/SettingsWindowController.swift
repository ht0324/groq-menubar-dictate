import AppKit
import Foundation

struct SettingsSnapshot {
    var apiKey: String
    var autoPasteEnabled: Bool
    var endPruneEnabled: Bool
    var performanceDiagnosticsEnabled: Bool
    var launchAtLoginEnabled: Bool
    var microphoneInputMode: MicrophoneInputMode
    var optionKeyMode: OptionKeyMode
    var model: String
    var languageHint: String
    var typingWordsPerMinute: Int
}

private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }

        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifierFlags == .command,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        let selector: Selector?
        switch key {
        case "x":
            selector = #selector(NSText.cut(_:))
        case "c":
            selector = #selector(NSText.copy(_:))
        case "v":
            selector = #selector(NSText.paste(_:))
        case "a":
            selector = #selector(NSText.selectAll(_:))
        default:
            selector = nil
        }

        guard let selector else {
            return super.performKeyEquivalent(with: event)
        }

        if NSApp.sendAction(selector, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class SettingsWindowController: NSWindowController {
    private let onSave: (SettingsSnapshot) -> Void
    private let onOpenWordsFile: () -> Void
    private let onOpenFilterWordsFile: () -> Void
    private let onOpenEndPrunePhrasesFile: () -> Void
    private let onTestPermissions: () -> Void

    private let apiKeyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let languageField = NSTextField()
    private let typingSpeedField = NSTextField()
    private let optionKeyModePopup = NSPopUpButton()
    private let microphoneInputModePopup = NSPopUpButton()
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let autoPasteCheckbox = NSButton(checkboxWithTitle: "Auto-paste after copy", target: nil, action: nil)
    private let endPruneCheckbox = NSButton(checkboxWithTitle: "Prune transcript ending phrases", target: nil, action: nil)
    private let diagnosticsCheckbox = NSButton(checkboxWithTitle: "Enable performance diagnostics", target: nil, action: nil)

    init(
        snapshot: SettingsSnapshot,
        onSave: @escaping (SettingsSnapshot) -> Void,
        onOpenWordsFile: @escaping () -> Void,
        onOpenFilterWordsFile: @escaping () -> Void,
        onOpenEndPrunePhrasesFile: @escaping () -> Void,
        onTestPermissions: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onOpenWordsFile = onOpenWordsFile
        self.onOpenFilterWordsFile = onOpenFilterWordsFile
        self.onOpenEndPrunePhrasesFile = onOpenEndPrunePhrasesFile
        self.onTestPermissions = onTestPermissions

        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 660),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Groq Dictation Settings"
        super.init(window: window)
        setupUI(snapshot: snapshot)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(snapshot: SettingsSnapshot) {
        guard let contentView = window?.contentView else {
            return
        }

        apiKeyField.stringValue = snapshot.apiKey
        modelField.stringValue = snapshot.model
        modelField.placeholderString = "whisper-large-v3-turbo"
        languageField.stringValue = snapshot.languageHint
        languageField.placeholderString = "en, ko, ja..."
        typingSpeedField.placeholderString = "Optional"
        typingSpeedField.stringValue = snapshot.typingWordsPerMinute > 0 ? String(snapshot.typingWordsPerMinute) : ""
        optionKeyModePopup.removeAllItems()
        for mode in OptionKeyMode.allCases {
            optionKeyModePopup.addItem(withTitle: mode.title)
            optionKeyModePopup.lastItem?.representedObject = mode.rawValue
        }
        if let matchingItem = optionKeyModePopup.itemArray.first(where: {
            ($0.representedObject as? String) == snapshot.optionKeyMode.rawValue
        }) {
            optionKeyModePopup.select(matchingItem)
        }
        microphoneInputModePopup.removeAllItems()
        for mode in MicrophoneInputMode.allCases {
            microphoneInputModePopup.addItem(withTitle: mode.title)
            microphoneInputModePopup.lastItem?.representedObject = mode.rawValue
        }
        if let matchingItem = microphoneInputModePopup.itemArray.first(where: {
            ($0.representedObject as? String) == snapshot.microphoneInputMode.rawValue
        }) {
            microphoneInputModePopup.select(matchingItem)
        }
        launchAtLoginCheckbox.state = snapshot.launchAtLoginEnabled ? .on : .off
        autoPasteCheckbox.state = snapshot.autoPasteEnabled ? .on : .off
        endPruneCheckbox.state = snapshot.endPruneEnabled ? .on : .off
        diagnosticsCheckbox.state = snapshot.performanceDiagnosticsEnabled ? .on : .off

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Groq Dictation Settings")
        title.alignment = .left
        title.font = NSFont.boldSystemFont(ofSize: 17)

        let hint = NSTextField(
            wrappingLabelWithString: "Tap Option once to start recording and again to stop. Grant Microphone and Input Monitoring once during setup."
        )
        hint.alignment = .left
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.widthAnchor.constraint(equalToConstant: 580).isActive = true

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(hint)

        let testPermissionsButton = NSButton(title: "Test Permissions", target: self, action: #selector(testPermissionsTapped))
        stack.addArrangedSubview(makeSection(
            title: "Account",
            arrangedSubviews: [
                makeLabeledRow(label: "Groq API key", control: apiKeyField),
                makeLabeledRow(label: "Permissions", control: testPermissionsButton, controlWidth: 160),
            ]
        ))

        let openWordsButton = NSButton(title: "Open Custom Words File", target: self, action: #selector(openWordsTapped))
        let openFilterWordsButton = NSButton(title: "Open Filter Words File", target: self, action: #selector(openFilterWordsTapped))
        let openEndPrunePhrasesButton = NSButton(title: "Open End Prune Phrases File", target: self, action: #selector(openEndPrunePhrasesTapped))
        stack.addArrangedSubview(makeSection(
            title: "Transcription",
            arrangedSubviews: [
                makeLabeledRow(label: "Model", control: modelField),
                makeLabeledRow(label: "Language hint", control: languageField),
                makeLabeledRow(label: "Custom words", control: openWordsButton, controlWidth: 210),
                makeLabeledRow(label: "Filter words", control: openFilterWordsButton, controlWidth: 210),
                makeLabeledRow(label: "Ending phrases", control: openEndPrunePhrasesButton, controlWidth: 240),
            ]
        ))

        stack.addArrangedSubview(makeSection(
            title: "Input",
            arrangedSubviews: [
                makeLabeledRow(label: "Option key", control: optionKeyModePopup, controlWidth: 340),
                makeLabeledRow(label: "Microphone", control: microphoneInputModePopup, controlWidth: 400),
            ]
        ))

        stack.addArrangedSubview(makeSection(
            title: "Behavior",
            arrangedSubviews: [
                makeCheckboxRow(launchAtLoginCheckbox),
                makeCheckboxRow(autoPasteCheckbox),
                makeCheckboxRow(endPruneCheckbox),
            ]
        ))

        let typingHint = NSTextField(
            wrappingLabelWithString: "Used only for the cumulative time-saved estimate. Leave blank or 0 to disable."
        )
        typingHint.alignment = .left
        typingHint.textColor = .secondaryLabelColor
        typingHint.maximumNumberOfLines = 0
        stack.addArrangedSubview(makeSection(
            title: "Stats & Diagnostics",
            arrangedSubviews: [
                makeLabeledRow(label: "Typing speed", control: typingSpeedField, controlWidth: 120),
                makeIndentedHelpRow(typingHint),
                makeCheckboxRow(diagnosticsCheckbox),
            ]
        ))

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelColor = .systemBlue

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(buttonSpacer)
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(saveButton)

        stack.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalToConstant: 580).isActive = true
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    private func makeSection(title: String, arrangedSubviews: [NSView]) -> NSView {
        let titleView = NSTextField(labelWithString: title)
        titleView.alignment = .left
        titleView.font = NSFont.boldSystemFont(ofSize: 12)
        titleView.textColor = .secondaryLabelColor

        let sectionStack = NSStackView()
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 8
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        sectionStack.addArrangedSubview(titleView)
        for view in arrangedSubviews {
            sectionStack.addArrangedSubview(view)
        }
        return sectionStack
    }

    private func makeLabeledRow(label: String, control: NSControl, controlWidth: CGFloat = 420) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.alignment = .right
        labelView.setContentHuggingPriority(.required, for: .horizontal)
        labelView.widthAnchor.constraint(equalToConstant: 128).isActive = true

        control.translatesAutoresizingMaskIntoConstraints = false
        control.heightAnchor.constraint(equalToConstant: 24).isActive = true
        control.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true

        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.distribution = .fill
        return row
    }

    private func makeCheckboxRow(_ checkbox: NSButton) -> NSView {
        makeLabeledRow(label: "", control: checkbox, controlWidth: 260)
    }

    private func makeIndentedHelpRow(_ helpView: NSTextField) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: 128).isActive = true
        helpView.translatesAutoresizingMaskIntoConstraints = false
        helpView.widthAnchor.constraint(equalToConstant: 420).isActive = true

        let row = NSStackView(views: [spacer, helpView])
        row.orientation = .horizontal
        row.spacing = 12
        row.distribution = .fill
        return row
    }

    @objc private func openWordsTapped() {
        onOpenWordsFile()
    }

    @objc private func openFilterWordsTapped() {
        onOpenFilterWordsFile()
    }

    @objc private func openEndPrunePhrasesTapped() {
        onOpenEndPrunePhrasesFile()
    }

    @objc private func testPermissionsTapped() {
        onTestPermissions()
    }

    @objc private func cancelTapped() {
        close()
    }

    @objc private func saveTapped() {
        let selectedOptionKeyMode = optionKeyModePopup.selectedItem?
            .representedObject
            .flatMap { $0 as? String }
            .flatMap(OptionKeyMode.init(rawValue:)) ?? .any

        let selectedInputMode = microphoneInputModePopup.selectedItem?
            .representedObject
            .flatMap { $0 as? String }
            .flatMap(MicrophoneInputMode.init(rawValue:)) ?? .automatic

        let typingWordsPerMinute = max(
            0,
            Int(typingSpeedField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        )

        let snapshot = SettingsSnapshot(
            apiKey: apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            autoPasteEnabled: autoPasteCheckbox.state == .on,
            endPruneEnabled: endPruneCheckbox.state == .on,
            performanceDiagnosticsEnabled: diagnosticsCheckbox.state == .on,
            launchAtLoginEnabled: launchAtLoginCheckbox.state == .on,
            microphoneInputMode: selectedInputMode,
            optionKeyMode: selectedOptionKeyMode,
            model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            languageHint: languageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            typingWordsPerMinute: typingWordsPerMinute
        )
        onSave(snapshot)
        close()
    }
}
