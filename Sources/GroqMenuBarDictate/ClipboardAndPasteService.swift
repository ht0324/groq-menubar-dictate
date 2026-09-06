import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation
import OSLog

@MainActor
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

    /// Prepare during transcription, without reading the clipboard or posting keys.
    func preparePaste() -> PreparedPaste? {
        for (stateID, tap) in [
            (CGEventSourceStateID.combinedSessionState, CGEventTapLocation.cgSessionEventTap),
            (.hidSystemState, .cghidEventTap),
        ] {
            if let paste = PreparedPaste(stateID: stateID, tap: tap) {
                return paste
            }
        }
        logger.error("Failed to prepare Cmd+V: could not create event source/events.")
        return nil
    }
}

@MainActor
struct PreparedPaste {
    private let events: [CGEvent]
    private let tap: CGEventTapLocation

    init?(stateID: CGEventSourceStateID, tap: CGEventTapLocation) {
        guard let source = CGEventSource(stateID: stateID) else {
            return nil
        }
        let keys: [(Int, Bool, CGEventFlags)] = [
            (kVK_Command, true, []),
            (kVK_ANSI_V, true, .maskCommand),
            (kVK_ANSI_V, false, .maskCommand),
            (kVK_Command, false, []),
        ]
        var events: [CGEvent] = []
        for (key, isDown, flags) in keys {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: isDown) else {
                return nil
            }
            event.flags = flags
            events.append(event)
        }
        self.events = events
        self.tap = tap
    }

    /// Refresh timestamps: these events may have waited through a network request.
    /// Posting does not acknowledge insertion by the destination application.
    func post(
        postEvent: (CGEvent, CGEventTapLocation) -> Void = { $0.post(tap: $1) },
        pause: (useconds_t) -> Void = { usleep($0) },
        timestamp: () -> CGEventTimestamp = { DispatchTime.now().uptimeNanoseconds }
    ) {
        for (index, event) in events.enumerated() {
            event.timestamp = timestamp()
            postEvent(event, tap)
            if index < events.count - 1 {
                pause(2_000)
            }
        }
    }
}
