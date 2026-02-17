import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation
import OSLog

final class ClipboardAndPasteService {
    private let logger = Logger(subsystem: "com.huntae.groq-menubar-dictate", category: "paste")

    func copyText(_ text: String) -> Bool {
        guard !text.isEmpty else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func pasteFromClipboard() -> Bool {
        if postCommandV(stateID: .combinedSessionState, tap: .cgSessionEventTap) {
            logger.info("Posted Cmd+V using cgSessionEventTap/combinedSessionState.")
            return true
        }

        if postCommandV(stateID: .hidSystemState, tap: .cghidEventTap) {
            logger.info("Posted Cmd+V using cghidEventTap/hidSystemState.")
            return true
        }

        logger.error("Failed to post Cmd+V: could not create event source/events.")
        return false
    }

    private func postCommandV(stateID: CGEventSourceStateID, tap: CGEventTapLocation) -> Bool {
        guard let source = CGEventSource(stateID: stateID) else {
            logger.error("CGEventSource creation failed for stateID \(stateID.rawValue).")
            return false
        }
        guard let commandDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_Command),
            keyDown: true
        ),
            let commandUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_Command),
                keyDown: false
            )
        else {
            logger.error("Failed creating Cmd key events.")
            return false
        }

        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: true
        ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: false
            )
        else {
            logger.error("Failed creating V key events.")
            return false
        }

        commandDown.flags = []
        commandUp.flags = []
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        commandDown.post(tap: tap)
        usleep(2_000)
        keyDown.post(tap: tap)
        usleep(2_000)
        keyUp.post(tap: tap)
        usleep(2_000)
        commandUp.post(tap: tap)
        return true
    }
}
