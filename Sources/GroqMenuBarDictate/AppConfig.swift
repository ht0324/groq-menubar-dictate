import Foundation

enum AppConfig {
    static let serviceName = "groq-menubar-dictate"
    static let bundleIdentifier = "com.huntae.groq-menubar-dictate"
    static let defaultModel = "whisper-large-v3-turbo"
    static let defaultGroqEndpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    static let appSupportFolderName = "groq-menubar-dictate"
}

enum MicrophoneInputMode: String, CaseIterable {
    case automatic
    case macBookInternal
    case cableCreation

    var title: String {
        switch self {
        case .automatic:
            return "Automatic (system default)"
        case .macBookInternal:
            return "Always use this Mac's built-in microphone"
        case .cableCreation:
            return "Cable Creation USB input"
        }
    }
}

enum OptionKeyMode: String, CaseIterable {
    case any
    case left
    case right

    var title: String {
        switch self {
        case .any:
            return "Either Option key"
        case .left:
            return "Left Option only"
        case .right:
            return "Right Option only"
        }
    }
}

final class SettingsStore {
    private enum Key {
        static let apiKey = "settings.apiKey"
        static let autoPasteEnabled = "settings.autoPasteEnabled"
        static let endPruneEnabled = "settings.endPruneEnabled"
        static let performanceDiagnosticsEnabled = "settings.performanceDiagnosticsEnabled"
        static let launchAtLoginEnabled = "settings.launchAtLoginEnabled"
        static let audioActivityTriggerEnabled = "settings.audioActivityTriggerEnabled"
        static let audioTriggerStartThresholdDBFS = "settings.audioTriggerStartThresholdDBFS"
        static let audioTriggerStopThresholdDBFS = "settings.audioTriggerStopThresholdDBFS"
        static let audioTriggerStopHoldSeconds = "settings.audioTriggerStopHoldSeconds"
        static let audioTriggerPreRollSeconds = "settings.audioTriggerPreRollSeconds"
        static let audioTriggerRawDumpEnabled = "settings.audioTriggerRawDumpEnabled"
        static let microphoneInputMode = "settings.microphoneInputMode"
        static let optionKeyMode = "settings.optionKeyMode"
        static let model = "settings.model"
        static let languageHint = "settings.languageHint"
        static let typingWordsPerMinute = "settings.typingWordsPerMinute"
        static let tapMinMs = "settings.tap.minMs"
        static let tapMaxMs = "settings.tap.maxMs"
        static let tapDebounceMs = "settings.tap.debounceMs"
        static let maxAudioMB = "settings.maxAudioMB"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var apiKey: String {
        get {
            defaults.string(forKey: Key.apiKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        set {
            defaults.set(
                newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: Key.apiKey
            )
        }
    }

    var autoPasteEnabled: Bool {
        get {
            if defaults.object(forKey: Key.autoPasteEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Key.autoPasteEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.autoPasteEnabled)
        }
    }

    var endPruneEnabled: Bool {
        get {
            if defaults.object(forKey: Key.endPruneEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Key.endPruneEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.endPruneEnabled)
        }
    }

    var performanceDiagnosticsEnabled: Bool {
        get {
            defaults.bool(forKey: Key.performanceDiagnosticsEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.performanceDiagnosticsEnabled)
        }
    }

    var launchAtLoginEnabled: Bool {
        get {
            if defaults.object(forKey: Key.launchAtLoginEnabled) == nil {
                return false
            }
            return defaults.bool(forKey: Key.launchAtLoginEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.launchAtLoginEnabled)
        }
    }

    var audioActivityTriggerEnabled: Bool {
        get {
            if defaults.object(forKey: Key.audioActivityTriggerEnabled) == nil {
                return false
            }
            return defaults.bool(forKey: Key.audioActivityTriggerEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.audioActivityTriggerEnabled)
        }
    }

    /// Detector tuning with no settings UI; override for calibration via e.g.
    /// defaults write com.huntae.groq-menubar-dictate settings.audioTriggerStopThresholdDBFS -float -78
    var audioActivityTriggerConfiguration: AudioActivityTriggerConfiguration {
        var configuration = AudioActivityTriggerConfiguration()
        configuration.startThresholdDBFS = doubleValue(
            forKey: Key.audioTriggerStartThresholdDBFS,
            defaultValue: configuration.startThresholdDBFS,
            clampedTo: -120...0
        )
        // Cap at the start threshold so a bad override can't break the
        // detector's hysteresis (stop must not exceed start).
        configuration.stopThresholdDBFS = min(
            doubleValue(
                forKey: Key.audioTriggerStopThresholdDBFS,
                defaultValue: configuration.stopThresholdDBFS,
                clampedTo: -120...0
            ),
            configuration.startThresholdDBFS
        )
        configuration.stopHoldSeconds = doubleValue(
            forKey: Key.audioTriggerStopHoldSeconds,
            defaultValue: configuration.stopHoldSeconds,
            clampedTo: 0.05...5
        )
        configuration.preRollSeconds = doubleValue(
            forKey: Key.audioTriggerPreRollSeconds,
            defaultValue: configuration.preRollSeconds,
            clampedTo: 0...5
        )
        return configuration
    }

    var audioTriggerRawDumpEnabled: Bool {
        get {
            defaults.bool(forKey: Key.audioTriggerRawDumpEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.audioTriggerRawDumpEnabled)
        }
    }

    private func doubleValue(
        forKey key: String,
        defaultValue: Double,
        clampedTo range: ClosedRange<Double>
    ) -> Double {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        let raw = defaults.double(forKey: key)
        guard raw.isFinite else {
            return defaultValue
        }
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    var microphoneInputMode: MicrophoneInputMode {
        get {
            guard let raw = defaults.string(forKey: Key.microphoneInputMode),
                  let mode = MicrophoneInputMode(rawValue: raw)
            else {
                return .automatic
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.microphoneInputMode)
        }
    }

    var optionKeyMode: OptionKeyMode {
        get {
            guard let raw = defaults.string(forKey: Key.optionKeyMode),
                  let mode = OptionKeyMode(rawValue: raw)
            else {
                return .any
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.optionKeyMode)
        }
    }

    var model: String {
        get {
            let raw = defaults.string(forKey: Key.model)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw?.isEmpty == false ? raw! : AppConfig.defaultModel
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? AppConfig.defaultModel : trimmed, forKey: Key.model)
        }
    }

    var languageHint: String? {
        get {
            let raw = defaults.string(forKey: Key.languageHint)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let raw, !raw.isEmpty else {
                return nil
            }
            return raw
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            defaults.set(trimmed.isEmpty ? nil : trimmed, forKey: Key.languageHint)
        }
    }

    var typingWordsPerMinute: Int {
        get {
            guard defaults.object(forKey: Key.typingWordsPerMinute) != nil else {
                return 0
            }
            return max(0, defaults.integer(forKey: Key.typingWordsPerMinute))
        }
        set {
            defaults.set(max(0, newValue), forKey: Key.typingWordsPerMinute)
        }
    }

    var tapMinMilliseconds: Int {
        get {
            let raw = defaults.integer(forKey: Key.tapMinMs)
            return raw > 0 ? raw : 20
        }
        set {
            defaults.set(max(1, newValue), forKey: Key.tapMinMs)
        }
    }

    var tapMaxMilliseconds: Int {
        get {
            let raw = defaults.integer(forKey: Key.tapMaxMs)
            return raw > 0 ? raw : 450
        }
        set {
            defaults.set(max(1, newValue), forKey: Key.tapMaxMs)
        }
    }

    var tapDebounceMilliseconds: Int {
        get {
            guard defaults.object(forKey: Key.tapDebounceMs) != nil else {
                return 250
            }
            return max(0, defaults.integer(forKey: Key.tapDebounceMs))
        }
        set {
            defaults.set(max(0, newValue), forKey: Key.tapDebounceMs)
        }
    }

    var maxAudioMB: Int {
        get {
            let raw = defaults.integer(forKey: Key.maxAudioMB)
            return raw > 0 ? raw : 20
        }
        set {
            defaults.set(max(1, newValue), forKey: Key.maxAudioMB)
        }
    }

    var maxAudioBytes: Int {
        maxAudioMB * 1024 * 1024
    }

    var tapSettings: OptionTapSettings {
        OptionTapSettings(
            minTapMilliseconds: tapMinMilliseconds,
            maxTapMilliseconds: max(tapMaxMilliseconds, tapMinMilliseconds),
            debounceMilliseconds: tapDebounceMilliseconds
        )
    }
}
