import Foundation

struct OptionTapSettings {
    var minTapMilliseconds: Int
    var maxTapMilliseconds: Int
    var debounceMilliseconds: Int
}

struct OptionTapValidator {
    private(set) var optionIsDown = false
    private var optionDownTimestamp: TimeInterval?
    private var invalidTap = false
    private var lastValidTapTimestamp: TimeInterval?

    mutating func registerFlagsChange(
        optionIsDown newOptionIsDown: Bool,
        hasOtherModifiers: Bool,
        timestamp: TimeInterval,
        settings: OptionTapSettings
    ) -> Bool {
        if newOptionIsDown {
            if !optionIsDown {
                optionIsDown = true
                optionDownTimestamp = timestamp
                invalidTap = hasOtherModifiers
            } else if hasOtherModifiers {
                invalidTap = true
            }
            return false
        }

        guard optionIsDown else {
            return false
        }
        optionIsDown = false
        defer {
            optionDownTimestamp = nil
            invalidTap = false
        }

        guard !invalidTap, !hasOtherModifiers, let downTimestamp = optionDownTimestamp else {
            return false
        }

        let durationMilliseconds = (timestamp - downTimestamp) * 1000
        guard durationMilliseconds >= Double(settings.minTapMilliseconds),
              durationMilliseconds <= Double(max(settings.maxTapMilliseconds, settings.minTapMilliseconds))
        else {
            return false
        }

        if let lastValidTapTimestamp {
            let deltaMilliseconds = (timestamp - lastValidTapTimestamp) * 1000
            if deltaMilliseconds < Double(max(settings.debounceMilliseconds, 0)) {
                return false
            }
        }

        self.lastValidTapTimestamp = timestamp
        return true
    }

    mutating func registerNonModifierKeyDown() {
        if optionIsDown {
            invalidTap = true
        }
    }

    mutating func invalidateCurrentTap() {
        if optionIsDown {
            invalidTap = true
        }
    }
}
