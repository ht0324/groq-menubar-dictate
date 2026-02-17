import AppKit
import Foundation

struct SettingsSnapshot {
    var apiKey: String
    var autoPasteEnabled: Bool
    var endPruneEnabled: Bool
    var performanceDiagnosticsEnabled: Bool
    var launchAtLoginEnabled: Bool
    var model: String
    var languageHint: String
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
    private let onOpenEndPrunePhrasesFile: () -> Void
    private let onTestPermissions: () -> Void

    private let apiKeyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let languageField = NSTextField()
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let autoPasteCheckbox = NSButton(checkboxWithTitle: "Auto-paste after copy", target: nil, action: nil)
    private let endPruneCheckbox = NSButton(checkboxWithTitle: "Prune transcript ending phrases", target: nil, action: nil)
    private let diagnosticsCheckbox = NSButton(checkboxWithTitle: "Enable performance diagnostics", target: nil, action: nil)

    init(
        snapshot: SettingsSnapshot,
        onSave: @escaping (SettingsSnapshot) -> Void,
        onOpenWordsFile: @escaping () -> Void,
        onOpenEndPrunePhrasesFile: @escaping () -> Void,
        onTestPermissions: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onOpenWordsFile = onOpenWordsFile
        self.onOpenEndPrunePhrasesFile = onOpenEndPrunePhrasesFile
        self.onTestPermissions = onTestPermissions

        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Groq Dictation Settings"
        super.init(window: window)
        setupUI(snapshot: snapshot)
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
        languageField.stringValue = snapshot.languageHint
        launchAtLoginCheckbox.state = snapshot.launchAtLoginEnabled ? .on : .off
        autoPasteCheckbox.state = snapshot.autoPasteEnabled ? .on : .off
        endPruneCheckbox.state = snapshot.endPruneEnabled ? .on : .off
        diagnosticsCheckbox.state = snapshot.performanceDiagnosticsEnabled ? .on : .off

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Option-key-only dictation (no clicking needed)")
        title.font = NSFont.boldSystemFont(ofSize: 13)

        let hint = NSTextField(labelWithString: "Tap Option once to start recording, tap Option again to stop and transcribe.")
        hint.textColor = .secondaryLabelColor

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(hint)
        stack.addArrangedSubview(makeLabeledRow(label: "Groq API key", control: apiKeyField))
        stack.addArrangedSubview(makeLabeledRow(label: "Model", control: modelField))
        stack.addArrangedSubview(makeLabeledRow(label: "Language hint (optional)", control: languageField))
        stack.addArrangedSubview(launchAtLoginCheckbox)
        stack.addArrangedSubview(autoPasteCheckbox)
        stack.addArrangedSubview(endPruneCheckbox)
        stack.addArrangedSubview(diagnosticsCheckbox)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let openWordsButton = NSButton(title: "Open Custom Words File", target: self, action: #selector(openWordsTapped))
        let openEndPrunePhrasesButton = NSButton(title: "Open End Prune Phrases File", target: self, action: #selector(openEndPrunePhrasesTapped))
        let testPermissionsButton = NSButton(title: "Test Permissions", target: self, action: #selector(testPermissionsTapped))
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelColor = .systemBlue

        buttonRow.addArrangedSubview(openWordsButton)
        buttonRow.addArrangedSubview(openEndPrunePhrasesButton)
        buttonRow.addArrangedSubview(testPermissionsButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(saveButton)

        stack.addArrangedSubview(buttonRow)
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    private func makeLabeledRow(label: String, control: NSControl) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        control.translatesAutoresizingMaskIntoConstraints = false
        control.heightAnchor.constraint(equalToConstant: 24).isActive = true
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true

        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.spacing = 10
        row.distribution = .fill
        return row
    }

    @objc private func openWordsTapped() {
        onOpenWordsFile()
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
        let snapshot = SettingsSnapshot(
            apiKey: apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            autoPasteEnabled: autoPasteCheckbox.state == .on,
            endPruneEnabled: endPruneCheckbox.state == .on,
            performanceDiagnosticsEnabled: diagnosticsCheckbox.state == .on,
            launchAtLoginEnabled: launchAtLoginCheckbox.state == .on,
            model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            languageHint: languageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        onSave(snapshot)
        close()
    }
}
