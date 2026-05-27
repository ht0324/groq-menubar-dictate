import Foundation

struct AppVersionInfo: Equatable {
    let shortVersion: String
    let build: String
    let commit: String?
    let isDirty: Bool
    let stampedDisplayVersion: String?

    static var current: AppVersionInfo {
        AppVersionInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    init(infoDictionary: [String: Any]) {
        shortVersion = Self.stringValue(for: "CFBundleShortVersionString", in: infoDictionary) ?? "source"
        build = Self.stringValue(for: "CFBundleVersion", in: infoDictionary) ?? "dev"
        commit = Self.stringValue(for: "GMDGitCommit", in: infoDictionary)
        isDirty = Self.boolValue(for: "GMDGitDirty", in: infoDictionary)
        stampedDisplayVersion = Self.stringValue(for: "GMDVersionDisplay", in: infoDictionary)
    }

    var menuTitle: String {
        "Version \(displayText)"
    }

    var displayText: String {
        if let stampedDisplayVersion {
            return stampedDisplayVersion
        }

        if shortVersion == "source", build == "dev" {
            return "source run"
        }

        var text = "\(shortVersion) (\(build))"
        if let commit {
            text += " \(String(commit.prefix(10)))"
            if isDirty {
                text += " dirty"
            }
        }
        return text
    }

    private static func stringValue(for key: String, in infoDictionary: [String: Any]) -> String? {
        guard let value = infoDictionary[key] as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func boolValue(for key: String, in infoDictionary: [String: Any]) -> Bool {
        switch infoDictionary[key] {
        case let value as Bool:
            return value
        case let value as String:
            return ["1", "true", "yes"].contains(value.lowercased())
        default:
            return false
        }
    }
}
