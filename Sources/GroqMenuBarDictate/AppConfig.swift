import Foundation

enum AppConfig {
    static let serviceName = "groq-menubar-dictate"
    static let defaultModel = "whisper-large-v3-turbo"
    static let defaultGroqEndpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    static let appSupportFolderName = "groq-menubar-dictate"
}

final class SettingsStore {
    private enum Key {
        static let apiKey = "settings.apiKey"
        static let autoPasteEnabled = "settings.autoPasteEnabled"
        static let endPruneEnabled = "settings.endPruneEnabled"
        static let performanceDiagnosticsEnabled = "settings.performanceDiagnosticsEnabled"
        static let launchAtLoginEnabled = "settings.launchAtLoginEnabled"
        static let model = "settings.model"
        static let languageHint = "settings.languageHint"
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
