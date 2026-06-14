import Foundation

enum LaunchAtLoginError: LocalizedError {
    case missingExecutablePath
    case launchctlFailed(args: [String], output: String)

    var errorDescription: String? {
        switch self {
        case .missingExecutablePath:
            return "Could not resolve app executable path."
        case let .launchctlFailed(args, output):
            return "launchctl failed (\(args.joined(separator: " "))): \(output)"
        }
    }
}

@MainActor
final class LaunchAtLoginService {
    typealias LaunchctlRunner = (_ args: [String], _ allowFailure: Bool) throws -> Void

    private struct LaunchAgentConfiguration {
        let executablePath: String
        let standardOutPath: String?
        let standardErrorPath: String?
    }

    let label = "com.huntae.groq-menubar-dictate"
    private let fileManager: FileManager
    private let customPlistURL: URL?
    private let launchctlRunner: LaunchctlRunner?

    init(
        fileManager: FileManager = .default,
        plistURL: URL? = nil,
        launchctlRunner: LaunchctlRunner? = nil
    ) {
        self.fileManager = fileManager
        self.customPlistURL = plistURL
        self.launchctlRunner = launchctlRunner
    }

    var plistURL: URL {
        if let customPlistURL {
            return customPlistURL
        }
        let base = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        return base.appendingPathComponent("\(label).plist", isDirectory: false)
    }

    var isEnabled: Bool {
        fileManager.fileExists(atPath: plistURL.path)
    }

    func setEnabled(_ enabled: Bool, executablePath: String) throws {
        guard needsUpdate(enabled: enabled, executablePath: executablePath) else {
            return
        }

        if enabled {
            try enable(executablePath: executablePath)
        } else {
            try disable()
        }
    }

    func needsUpdate(enabled: Bool, executablePath: String) -> Bool {
        if enabled {
            guard isEnabled else {
                return true
            }
            let resolvedExecutablePath = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolvedExecutablePath.isEmpty else {
                return true
            }
            guard let configuration = configuredLaunchAgent else {
                return true
            }
            return configuration.executablePath != resolvedExecutablePath ||
                configuration.standardOutPath != desiredStandardOutPath ||
                configuration.standardErrorPath != desiredStandardErrorPath
        }

        return isEnabled
    }

    private var configuredLaunchAgent: LaunchAgentConfiguration? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let arguments = dictionary["ProgramArguments"] as? [String],
              let executablePath = arguments.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !executablePath.isEmpty
        else {
            return nil
        }
        return LaunchAgentConfiguration(
            executablePath: executablePath,
            standardOutPath: dictionary["StandardOutPath"] as? String,
            standardErrorPath: dictionary["StandardErrorPath"] as? String
        )
    }

    private var launchLogDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
    }

    private var desiredStandardOutPath: String {
        launchLogDirectory
            .appendingPathComponent("groq-menubar-dictate.launchd.out.log")
            .path
    }

    private var desiredStandardErrorPath: String {
        launchLogDirectory
            .appendingPathComponent("groq-menubar-dictate.launchd.err.log")
            .path
    }

    private func enable(executablePath: String) throws {
        let resolvedExecutablePath = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedExecutablePath.isEmpty else {
            throw LaunchAtLoginError.missingExecutablePath
        }

        let folder = plistURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        // ~/Library/Logs is the conventional, user-private home for app logs
        // and reliably exists, so launchd can redirect here without a world-
        // readable /tmp file or an extra directory to create.
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [resolvedExecutablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": ["Aqua"],
            "WorkingDirectory": (resolvedExecutablePath as NSString).deletingLastPathComponent,
            "StandardOutPath": desiredStandardOutPath,
            "StandardErrorPath": desiredStandardErrorPath,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        let domain = "gui/\(getuid())"
        try runLaunchctl(args: ["bootout", domain, plistURL.path], allowFailure: true)
        try runLaunchctl(args: ["bootstrap", domain, plistURL.path], allowFailure: false)
    }

    private func disable() throws {
        let domain = "gui/\(getuid())"
        try runLaunchctl(args: ["bootout", domain, plistURL.path], allowFailure: true)
        if fileManager.fileExists(atPath: plistURL.path) {
            try fileManager.removeItem(at: plistURL)
        }
    }

    private func runLaunchctl(args: [String], allowFailure: Bool) throws {
        if let launchctlRunner {
            try launchctlRunner(args, allowFailure)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 || allowFailure else {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown launchctl error"
            throw LaunchAtLoginError.launchctlFailed(args: args, output: output)
        }
    }
}
