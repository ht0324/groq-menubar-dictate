import AppKit
import Foundation

enum MenuBarStatusState {
    case idle
    case recording
    case transcribing
    case error
}

struct MenuBarActions {
    let openSettings: Selector
    let testPermissions: Selector
    let openCustomWords: Selector
    let openFilterWords: Selector
    let openEndPrunePhrases: Selector
    let quit: Selector
}

@MainActor
final class MenuBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
    private let statsMenu = NSMenu(title: "Stats")
    private let statsMenuItem = NSMenuItem(title: "Stats", action: nil, keyEquivalent: "")

    private var settingsWindowController: SettingsWindowController?

    func configure(target: AnyObject, actions: MenuBarActions) {
        configureStatusItem()
        configureMenu(target: target, actions: actions)
    }

    func updateStatus(message: String, state: MenuBarStatusState) {
        statusMenuItem.title = message
        statusItem.button?.toolTip = message
        updateStatusItemAppearance(for: state)
    }

    func updateStats(
        summary: DictationStatsSummary,
        target: AnyObject,
        resetAction: Selector
    ) {
        statsMenu.removeAllItems()
        statsMenu.autoenablesItems = false

        if case let .suspicious(message) = summary.healthStatus {
            statsMenu.addItem(disabledMenuItem(title: "Stats Warning"))
            statsMenu.addItem(disabledMenuItem(title: message))
            statsMenu.addItem(.separator())
        }
        statsMenu.addItem(disabledMenuItem(title: "Typing Speed: \(formatTypingSpeed(summary.typingWordsPerMinute))"))

        if summary.snapshot.isEmpty {
            statsMenu.addItem(disabledMenuItem(title: "No dictations yet"))
        } else {
            statsMenu.addItem(disabledMenuItem(title: "Sessions: \(summary.snapshot.successfulSessions.formatted())"))
            statsMenu.addItem(disabledMenuItem(title: "Words Dictated: \(summary.snapshot.totalWords.formatted())"))
            statsMenu.addItem(disabledMenuItem(title: "Recording Time: \(formatDuration(summary.snapshot.totalRecordingSeconds))"))
            statsMenu.addItem(disabledMenuItem(title: "Typing Time: \(formatOptionalDuration(summary.estimatedTypingSeconds))"))
            statsMenu.addItem(disabledMenuItem(title: "Time Saved: \(formatSignedOptionalDuration(summary.savedSeconds))"))
        }

        statsMenu.addItem(.separator())
        let resetItem = NSMenuItem(title: "Reset Stats...", action: resetAction, keyEquivalent: "")
        resetItem.target = target
        resetItem.isEnabled = !summary.snapshot.isEmpty
        statsMenu.addItem(resetItem)
    }

    func showSettings(
        snapshot: SettingsSnapshot,
        onSave: @escaping (SettingsSnapshot) -> Void,
        onOpenWordsFile: @escaping () -> Void,
        onOpenEndPrunePhrasesFile: @escaping () -> Void,
        onTestPermissions: @escaping () -> Void
    ) {
        let controller = SettingsWindowController(
            snapshot: snapshot,
            onSave: onSave,
            onOpenWordsFile: onOpenWordsFile,
            onOpenEndPrunePhrasesFile: onOpenEndPrunePhrasesFile,
            onTestPermissions: onTestPermissions
        )
        settingsWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func showPermissionSummary(_ lines: [String]) {
        let alert = NSAlert()
        alert.messageText = "Permission Status"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func showSetupGuidance(missingAPIKey: Bool, missingListenPermission: Bool) -> Bool {
        let steps = [
            "Groq MenuBar Dictate runs from the menu bar.",
            missingAPIKey ? "Paste your Groq API key in Settings." : nil,
            missingListenPermission ? "Click Test Permissions in Settings to grant Input Monitoring for the Option-key hotkey." : nil,
            "Grant microphone access the first time you record."
        ]
            .compactMap { $0 }
            .joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = "Finish Setup"
        alert.informativeText = steps
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }
        button.title = ""
        button.imagePosition = .imageOnly
    }

    private func configureMenu(target: AnyObject, actions: MenuBarActions) {
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        menu.addItem(menuItem(title: "Open Settings", action: actions.openSettings, keyEquivalent: ","))
        menu.addItem(menuItem(title: "Test Permissions", action: actions.testPermissions))
        statsMenuItem.submenu = statsMenu
        menu.addItem(statsMenuItem)
        menu.addItem(menuItem(title: "Open Custom Words File", action: actions.openCustomWords))
        menu.addItem(menuItem(title: "Open Filter Words File", action: actions.openFilterWords))
        menu.addItem(menuItem(title: "Open End Prune Phrases File", action: actions.openEndPrunePhrases))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit", action: actions.quit, keyEquivalent: "q"))

        for item in menu.items {
            item.target = target
        }
        statusItem.menu = menu
    }

    private func menuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    }

    private func updateStatusItemAppearance(for state: MenuBarStatusState) {
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

    private func disabledMenuItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func formatTypingSpeed(_ wordsPerMinute: Int) -> String {
        wordsPerMinute > 0 ? "\(wordsPerMinute.formatted()) WPM" : "Off"
    }

    private func formatOptionalDuration(_ seconds: TimeInterval?) -> String {
        guard let seconds else {
            return "--"
        }
        return formatDuration(seconds)
    }

    private func formatSignedOptionalDuration(_ seconds: TimeInterval?) -> String {
        guard let seconds else {
            return "--"
        }
        let sign = seconds < 0 ? "-" : ""
        return "\(sign)\(formatDuration(abs(seconds)))"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = [.dropLeading, .dropMiddle]
        return formatter.string(from: max(0, seconds)) ?? "0s"
    }
}
