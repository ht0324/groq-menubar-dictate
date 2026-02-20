import Carbon.HIToolbox
import XCTest
@testable import GroqMenuBarDictate

final class OptionTapRecognizerTests: XCTestCase {
    private let settings = OptionTapSettings(minTapMilliseconds: 20, maxTapMilliseconds: 450, debounceMilliseconds: 250)

    func testLeftModeAcceptsLeftTapAndRejectsRightTap() {
        let keyState = StubOptionKeyStateProvider()
        let recognizer = makeRecognizer(mode: .left, keyState: keyState)

        var validTapCount = 0
        recognizer.onValidTap = {
            validTapCount += 1
        }

        keyState.leftDown = true
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: true,
            keyCode: UInt16(kVK_Option),
            hasOtherModifiers: false,
            timestamp: 10.0
        )
        keyState.leftDown = false
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: false,
            keyCode: UInt16(kVK_Option),
            hasOtherModifiers: false,
            timestamp: 10.12
        )
        flushMainQueue()
        XCTAssertEqual(validTapCount, 1)

        keyState.rightDown = true
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: true,
            keyCode: UInt16(kVK_RightOption),
            hasOtherModifiers: false,
            timestamp: 11.0
        )
        keyState.rightDown = false
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: false,
            keyCode: UInt16(kVK_RightOption),
            hasOtherModifiers: false,
            timestamp: 11.12
        )
        flushMainQueue()
        XCTAssertEqual(validTapCount, 1)
    }

    func testRightModeAcceptsRightTapAndRejectsLeftTap() {
        let keyState = StubOptionKeyStateProvider()
        let recognizer = makeRecognizer(mode: .right, keyState: keyState)

        var validTapCount = 0
        recognizer.onValidTap = {
            validTapCount += 1
        }

        keyState.rightDown = true
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: true,
            keyCode: UInt16(kVK_RightOption),
            hasOtherModifiers: false,
            timestamp: 20.0
        )
        keyState.rightDown = false
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: false,
            keyCode: UInt16(kVK_RightOption),
            hasOtherModifiers: false,
            timestamp: 20.1
        )
        flushMainQueue()
        XCTAssertEqual(validTapCount, 1)

        keyState.leftDown = true
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: true,
            keyCode: UInt16(kVK_Option),
            hasOtherModifiers: false,
            timestamp: 21.0
        )
        keyState.leftDown = false
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: false,
            keyCode: UInt16(kVK_Option),
            hasOtherModifiers: false,
            timestamp: 21.1
        )
        flushMainQueue()
        XCTAssertEqual(validTapCount, 1)
    }

    func testAnyModeAcceptsBothLeftAndRightTap() {
        let keyState = StubOptionKeyStateProvider()
        let recognizer = makeRecognizer(mode: .any, keyState: keyState)

        var validTapCount = 0
        recognizer.onValidTap = {
            validTapCount += 1
        }

        keyState.leftDown = true
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: true,
            keyCode: UInt16(kVK_Option),
            hasOtherModifiers: false,
            timestamp: 30.0
        )
        keyState.leftDown = false
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: false,
            keyCode: UInt16(kVK_Option),
            hasOtherModifiers: false,
            timestamp: 30.12
        )

        keyState.rightDown = true
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: true,
            keyCode: UInt16(kVK_RightOption),
            hasOtherModifiers: false,
            timestamp: 31.0
        )
        keyState.rightDown = false
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: false,
            keyCode: UInt16(kVK_RightOption),
            hasOtherModifiers: false,
            timestamp: 31.12
        )

        flushMainQueue()
        XCTAssertEqual(validTapCount, 2)
    }

    func testStopOnOptionPressTriggersImmediatelyWhenEnabled() {
        let keyState = StubOptionKeyStateProvider()
        let recognizer = makeRecognizer(mode: .any, keyState: keyState)
        recognizer.setStopOnOptionPressEnabled(true)

        let stopExpectation = expectation(description: "stop requested")
        recognizer.onStopRequested = {
            stopExpectation.fulfill()
        }

        keyState.leftDown = true
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: true,
            keyCode: UInt16(kVK_Option),
            hasOtherModifiers: false,
            timestamp: 40.0
        )

        wait(for: [stopExpectation], timeout: 1.0)
    }

    func testReconcilesOptionSideStateAfterMissedReleaseEvent() {
        let keyState = StubOptionKeyStateProvider()
        let recognizer = makeRecognizer(mode: .left, keyState: keyState)

        keyState.leftDown = true
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: true,
            keyCode: UInt16(kVK_Option),
            hasOtherModifiers: false,
            timestamp: 50.0
        )
        var sideState = recognizer.optionSideStateForTesting()
        XCTAssertTrue(sideState.left)
        XCTAssertFalse(sideState.right)

        keyState.leftDown = false
        keyState.rightDown = true
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: true,
            keyCode: UInt16(kVK_RightOption),
            hasOtherModifiers: false,
            timestamp: 50.08
        )

        sideState = recognizer.optionSideStateForTesting()
        XCTAssertFalse(sideState.left)
        XCTAssertTrue(sideState.right)

        keyState.rightDown = false
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: false,
            keyCode: UInt16(kVK_RightOption),
            hasOtherModifiers: false,
            timestamp: 50.12
        )

        sideState = recognizer.optionSideStateForTesting()
        XCTAssertFalse(sideState.left)
        XCTAssertFalse(sideState.right)
    }

    func testRightModeIgnoresLeftTapWhenProviderMisreportsAnyOptionAsRight() {
        let keyState = RightBiasedOptionKeyStateProvider()
        let recognizer = OptionTapRecognizer(
            settingsProvider: { [settings] in settings },
            optionKeyModeProvider: { .right },
            optionKeyStateProvider: keyState.value(for:),
            eventMonitoringEnabled: false
        )

        var validTapCount = 0
        recognizer.onValidTap = {
            validTapCount += 1
        }

        keyState.optionIsDown = true
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: true,
            keyCode: UInt16(kVK_Option),
            hasOtherModifiers: false,
            timestamp: 60.0
        )
        keyState.optionIsDown = false
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: false,
            keyCode: UInt16(kVK_Option),
            hasOtherModifiers: false,
            timestamp: 60.12
        )
        flushMainQueue()
        XCTAssertEqual(validTapCount, 0)

        keyState.optionIsDown = true
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: true,
            keyCode: UInt16(kVK_RightOption),
            hasOtherModifiers: false,
            timestamp: 61.0
        )
        keyState.optionIsDown = false
        recognizer.processFlagsChangeForTesting(
            flagsContainOption: false,
            keyCode: UInt16(kVK_RightOption),
            hasOtherModifiers: false,
            timestamp: 61.12
        )
        flushMainQueue()
        XCTAssertEqual(validTapCount, 1)
    }

    private func makeRecognizer(mode: OptionKeyMode, keyState: StubOptionKeyStateProvider) -> OptionTapRecognizer {
        OptionTapRecognizer(
            settingsProvider: { [settings] in settings },
            optionKeyModeProvider: { mode },
            optionKeyStateProvider: keyState.value(for:),
            eventMonitoringEnabled: false
        )
    }

    private func flushMainQueue() {
        let expectation = expectation(description: "flush main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
}

private final class StubOptionKeyStateProvider {
    var leftDown = false
    var rightDown = false

    func value(for keyCode: CGKeyCode) -> Bool {
        switch keyCode {
        case CGKeyCode(kVK_Option):
            return leftDown
        case CGKeyCode(kVK_RightOption):
            return rightDown
        default:
            return false
        }
    }
}

private final class RightBiasedOptionKeyStateProvider {
    var optionIsDown = false

    func value(for keyCode: CGKeyCode) -> Bool {
        guard optionIsDown else {
            return false
        }
        switch keyCode {
        case CGKeyCode(kVK_Option):
            return false
        case CGKeyCode(kVK_RightOption):
            return true
        default:
            return false
        }
    }
}
