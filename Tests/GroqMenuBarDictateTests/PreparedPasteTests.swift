import ApplicationServices
import Carbon.HIToolbox
import XCTest
@testable import GroqMenuBarDictate

final class PreparedPasteTests: XCTestCase {
    @MainActor
    func testPreparedPastePreservesKeyOrderModifiersAndSpacing() async throws {
        let paste = try XCTUnwrap(PreparedPaste(stateID: .combinedSessionState, tap: .cgSessionEventTap))
        var keys: [Int64] = []
        var types: [CGEventType] = []
        var flags: [CGEventFlags] = []
        var steps: [String] = []
        paste.post(postEvent: { event, tap in
            XCTAssertEqual(tap, .cgSessionEventTap)
            keys.append(event.getIntegerValueField(.keyboardEventKeycode))
            types.append(event.type)
            flags.append(event.flags)
            steps.append("post")
        }, pause: { duration in
            XCTAssertEqual(duration, 2_000)
            steps.append("pause")
        })

        XCTAssertEqual(keys, [kVK_Command, kVK_ANSI_V, kVK_ANSI_V, kVK_Command].map(Int64.init))
        XCTAssertEqual(types.map(\.rawValue), [CGEventType.flagsChanged, .keyDown, .keyUp, .flagsChanged].map(\.rawValue))
        XCTAssertEqual(flags, [[], .maskCommand, .maskCommand, []])
        XCTAssertEqual(steps, ["post", "pause", "post", "pause", "post", "pause", "post"])
    }

    @MainActor
    func testPreparedEventsUsePostingTimeInsteadOfPreparationTime() async throws {
        let paste = try XCTUnwrap(PreparedPaste(stateID: .hidSystemState, tap: .cghidEventTap))
        var now: CGEventTimestamp = 100_000_000
        var timestamps: [CGEventTimestamp] = []
        paste.post(postEvent: { event, tap in
            XCTAssertEqual(tap, .cghidEventTap)
            timestamps.append(event.timestamp)
        }, pause: { _ in }, timestamp: {
            now += 2_000_000
            return now
        })
        XCTAssertEqual(timestamps, [102_000_000, 104_000_000, 106_000_000, 108_000_000])
    }
}
