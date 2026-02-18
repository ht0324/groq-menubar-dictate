import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

final class OptionTapRecognizer: @unchecked Sendable {
    typealias SettingsProvider = () -> OptionTapSettings
    typealias OptionKeyModeProvider = () -> OptionKeyMode

    private let settingsProvider: SettingsProvider
    private let optionKeyModeProvider: OptionKeyModeProvider
    private let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .shift, .capsLock, .function]
    private var validator = OptionTapValidator()
    private var leftOptionDown = false
    private var rightOptionDown = false

    private var globalFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localFlagsMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var escapeEventTap: CFMachPort?
    private var escapeEventTapRunLoopSource: CFRunLoopSource?
    private let stateQueue = DispatchQueue(label: "com.huntae.groq-menubar-dictate.option-tap-recognizer.state")
    private let eventQueue = DispatchQueue(label: "com.huntae.groq-menubar-dictate.option-tap-recognizer.events")
    private var escapeInterceptionEnabled = false
    private var stopOnOptionPressEnabled = false
    private var keyDownMonitoringActive = false

    var onValidTap: (() -> Void)?
    var onStopRequested: (() -> Void)?
    var onEscapeKeyDown: (() -> Void)?

    init(
        settingsProvider: @escaping SettingsProvider,
        optionKeyModeProvider: @escaping OptionKeyModeProvider
    ) {
        self.settingsProvider = settingsProvider
        self.optionKeyModeProvider = optionKeyModeProvider
    }

    deinit {
        stop()
    }

    func start() {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { [self] in
                self.start()
            }
            return
        }

        guard globalFlagsMonitor == nil,
              localFlagsMonitor == nil
        else {
            return
        }
        installFlagsMonitorsIfNeeded()
        removeKeyDownMonitorsIfNeeded()

        eventQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.validator = OptionTapValidator()
            self.leftOptionDown = false
            self.rightOptionDown = false
            self.stopOnOptionPressEnabled = false
            self.keyDownMonitoringActive = false
        }
    }

    func stop() {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { [self] in
                self.stop()
            }
            return
        }
        removeFlagsMonitorsIfNeeded()
        removeKeyDownMonitorsIfNeeded()
        removeEscapeEventTap()
        stateQueue.sync {
            escapeInterceptionEnabled = false
        }
        eventQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.validator = OptionTapValidator()
            self.leftOptionDown = false
            self.rightOptionDown = false
            self.stopOnOptionPressEnabled = false
            self.keyDownMonitoringActive = false
        }
    }

    func setEscapeInterceptionEnabled(_ enabled: Bool) {
        stateQueue.sync {
            escapeInterceptionEnabled = enabled
        }
        if Thread.isMainThread {
            if enabled {
                self.installEscapeEventTapIfNeeded()
            } else {
                self.removeEscapeEventTap()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                if enabled {
                    self.installEscapeEventTapIfNeeded()
                } else {
                    self.removeEscapeEventTap()
                }
            }
        }
    }

    func setStopOnOptionPressEnabled(_ enabled: Bool) {
        eventQueue.async { [weak self] in
            self?.stopOnOptionPressEnabled = enabled
        }
    }

    private func installFlagsMonitorsIfNeeded() {
        if globalFlagsMonitor == nil {
            globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(event)
            }
        }
        if localFlagsMonitor == nil {
            localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(event)
                return event
            }
        }
    }

    private func removeFlagsMonitorsIfNeeded() {
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
    }

    private func installKeyDownMonitorsIfNeeded() {
        if globalKeyDownMonitor == nil {
            globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyDown(event)
            }
        }
        if localKeyDownMonitor == nil {
            localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyDown(event)
                return event
            }
        }
    }

    private func removeKeyDownMonitorsIfNeeded() {
        if let globalKeyDownMonitor {
            NSEvent.removeMonitor(globalKeyDownMonitor)
            self.globalKeyDownMonitor = nil
        }
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let optionIsDown = flags.contains(.option)
        let hasOtherModifiers = !flags.intersection(disallowedModifiers).isEmpty
        let timestamp = event.timestamp
        let keyCode = event.keyCode
        eventQueue.async { [weak self] in
            self?.processFlagsChange(
                flagsContainOption: optionIsDown,
                keyCode: keyCode,
                hasOtherModifiers: hasOtherModifiers,
                timestamp: timestamp
            )
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        _ = event
        eventQueue.async { [weak self] in
            self?.processKeyDown()
        }
    }

    private func installEscapeEventTapIfNeeded() {
        guard escapeEventTap == nil else {
            return
        }
        let eventMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.escapeEventTapCallback,
            userInfo: userInfo
        ) else {
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        escapeEventTap = tap
        escapeEventTapRunLoopSource = source
    }

    private func removeEscapeEventTap() {
        if let source = escapeEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            escapeEventTapRunLoopSource = nil
        }
        if let tap = escapeEventTap {
            CFMachPortInvalidate(tap)
            escapeEventTap = nil
        }
    }

    private func shouldInterceptEscape() -> Bool {
        stateQueue.sync {
            escapeInterceptionEnabled
        }
    }

    private static let escapeEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let recognizer = Unmanaged<OptionTapRecognizer>.fromOpaque(userInfo).takeUnretainedValue()
        return recognizer.handleEscapeEventTap(type: type, event: event)
    }

    private func handleEscapeEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let escapeEventTap {
                CGEvent.tapEnable(tap: escapeEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(kVK_Escape), shouldInterceptEscape() else {
            return Unmanaged.passUnretained(event)
        }

        if Thread.isMainThread {
            onEscapeKeyDown?()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onEscapeKeyDown?()
            }
        }
        return nil
    }

    private func processFlagsChange(
        flagsContainOption: Bool,
        keyCode: UInt16,
        hasOtherModifiers: Bool,
        timestamp: TimeInterval
    ) {
        let mode = currentOptionKeyMode()
        let wasOptionDown = optionIsDown(for: mode)
        updateOptionSideState(flagsContainOption: flagsContainOption, keyCode: keyCode)
        let optionIsDown = optionIsDown(for: mode)
        let effectiveHasOtherModifiers = hasOtherModifiers || hasUnselectedOptionDown(for: mode)
        let settings = currentTapSettings()
        let isValidTap = validator.registerFlagsChange(
            optionIsDown: optionIsDown,
            hasOtherModifiers: effectiveHasOtherModifiers,
            timestamp: timestamp,
            settings: settings
        )

        if optionIsDown, !wasOptionDown {
            setKeyDownMonitoringActive(true)
            if stopOnOptionPressEnabled, !effectiveHasOtherModifiers {
                validator.invalidateCurrentTap()
                DispatchQueue.main.async { [weak self] in
                    self?.onStopRequested?()
                }
            }
        } else if !optionIsDown, wasOptionDown {
            setKeyDownMonitoringActive(false)
        }

        if isValidTap {
            DispatchQueue.main.async { [weak self] in
                self?.onValidTap?()
            }
        }
    }

    private func processKeyDown() {
        validator.registerNonModifierKeyDown()
    }

    private func currentTapSettings() -> OptionTapSettings {
        if Thread.isMainThread {
            return settingsProvider()
        }
        return DispatchQueue.main.sync { [self] in
            self.settingsProvider()
        }
    }

    private func currentOptionKeyMode() -> OptionKeyMode {
        if Thread.isMainThread {
            return optionKeyModeProvider()
        }
        return DispatchQueue.main.sync { [self] in
            self.optionKeyModeProvider()
        }
    }

    private func updateOptionSideState(flagsContainOption: Bool, keyCode: UInt16) {
        switch keyCode {
        case UInt16(kVK_Option):
            if rightOptionDown {
                leftOptionDown.toggle()
            } else {
                leftOptionDown = flagsContainOption
            }
        case UInt16(kVK_RightOption):
            if leftOptionDown {
                rightOptionDown.toggle()
            } else {
                rightOptionDown = flagsContainOption
            }
        default:
            break
        }

        if !flagsContainOption {
            leftOptionDown = false
            rightOptionDown = false
        }
    }

    private func optionIsDown(for mode: OptionKeyMode) -> Bool {
        switch mode {
        case .any:
            return leftOptionDown || rightOptionDown
        case .left:
            return leftOptionDown
        case .right:
            return rightOptionDown
        }
    }

    private func hasUnselectedOptionDown(for mode: OptionKeyMode) -> Bool {
        switch mode {
        case .any:
            return false
        case .left:
            return rightOptionDown
        case .right:
            return leftOptionDown
        }
    }

    private func setKeyDownMonitoringActive(_ enabled: Bool) {
        guard keyDownMonitoringActive != enabled else {
            return
        }
        keyDownMonitoringActive = enabled
        if Thread.isMainThread {
            if enabled {
                self.installKeyDownMonitorsIfNeeded()
            } else {
                self.removeKeyDownMonitorsIfNeeded()
            }
        } else {
            DispatchQueue.main.sync { [self] in
                if enabled {
                    self.installKeyDownMonitorsIfNeeded()
                } else {
                    self.removeKeyDownMonitorsIfNeeded()
                }
            }
        }
    }
}
