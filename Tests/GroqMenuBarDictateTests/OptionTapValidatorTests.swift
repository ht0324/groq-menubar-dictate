import XCTest
@testable import GroqMenuBarDictate

final class OptionTapValidatorTests: XCTestCase {
    private let settings = OptionTapSettings(minTapMilliseconds: 20, maxTapMilliseconds: 450, debounceMilliseconds: 250)

    func testValidTapWithinThreshold() {
        var validator = OptionTapValidator()
        XCTAssertFalse(
            validator.registerFlagsChange(
                optionIsDown: true,
                hasOtherModifiers: false,
                timestamp: 1.0,
                settings: settings
            )
        )
        XCTAssertTrue(
            validator.registerFlagsChange(
                optionIsDown: false,
                hasOtherModifiers: false,
                timestamp: 1.14,
                settings: settings
            )
        )
    }

    func testTapInvalidWhenKeyPressedWhileOptionDown() {
        var validator = OptionTapValidator()
        _ = validator.registerFlagsChange(
            optionIsDown: true,
            hasOtherModifiers: false,
            timestamp: 5.0,
            settings: settings
        )
        validator.registerNonModifierKeyDown()
        XCTAssertFalse(
            validator.registerFlagsChange(
                optionIsDown: false,
                hasOtherModifiers: false,
                timestamp: 5.12,
                settings: settings
            )
        )
    }

    func testTapInvalidWhenDurationTooLong() {
        var validator = OptionTapValidator()
        _ = validator.registerFlagsChange(
            optionIsDown: true,
            hasOtherModifiers: false,
            timestamp: 10.0,
            settings: settings
        )
        XCTAssertFalse(
            validator.registerFlagsChange(
                optionIsDown: false,
                hasOtherModifiers: false,
                timestamp: 10.8,
                settings: settings
            )
        )
    }

    func testDebounceBlocksRapidRepeat() {
        var validator = OptionTapValidator()
        _ = validator.registerFlagsChange(
            optionIsDown: true,
            hasOtherModifiers: false,
            timestamp: 20.0,
            settings: settings
        )
        XCTAssertTrue(
            validator.registerFlagsChange(
                optionIsDown: false,
                hasOtherModifiers: false,
                timestamp: 20.1,
                settings: settings
            )
        )

        _ = validator.registerFlagsChange(
            optionIsDown: true,
            hasOtherModifiers: false,
            timestamp: 20.2,
            settings: settings
        )
        XCTAssertFalse(
            validator.registerFlagsChange(
                optionIsDown: false,
                hasOtherModifiers: false,
                timestamp: 20.27,
                settings: settings
            )
        )

        _ = validator.registerFlagsChange(
            optionIsDown: true,
            hasOtherModifiers: false,
            timestamp: 20.6,
            settings: settings
        )
        XCTAssertTrue(
            validator.registerFlagsChange(
                optionIsDown: false,
                hasOtherModifiers: false,
                timestamp: 20.7,
                settings: settings
            )
        )
    }

    func testInvalidateCurrentTapSuppressesRelease() {
        var validator = OptionTapValidator()
        XCTAssertFalse(
            validator.registerFlagsChange(
                optionIsDown: true,
                hasOtherModifiers: false,
                timestamp: 30.0,
                settings: settings
            )
        )
        validator.invalidateCurrentTap()
        XCTAssertFalse(
            validator.registerFlagsChange(
                optionIsDown: false,
                hasOtherModifiers: false,
                timestamp: 30.1,
                settings: settings
            )
        )
    }
}
