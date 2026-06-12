import Foundation

struct AppVersionInfo: Equatable {
    let shortVersion: String

    static var current: AppVersionInfo {
        AppVersionInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    init(infoDictionary: [String: Any]) {
        shortVersion = Self.stringValue(for: "CFBundleShortVersionString", in: infoDictionary) ?? "source"
    }

    var menuTitle: String {
        "Version \(displayText)"
    }

    var displayText: String {
        if shortVersion == "source" {
            return "source run"
        }

        return shortVersion
    }

    private static func stringValue(for key: String, in infoDictionary: [String: Any]) -> String? {
        guard let value = infoDictionary[key] as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
