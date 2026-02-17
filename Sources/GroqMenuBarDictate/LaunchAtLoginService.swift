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
    let label = "com.huntae.groq-menubar-dictate"
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var plistURL: URL {
        let base = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        return base.appendingPathComponent("\(label).plist", isDirectory: false)
    }

    var isEnabled: Bool {
        fileManager.fileExists(atPath: plistURL.path)
    }

    func setEnabled(_ enabled: Bool, executablePath: String) throws {
        if enabled {
            try enable(executablePath: executablePath)
        } else {
            try disable()
        }
    }

    private func enable(executablePath: String) throws {
        let resolvedExecutablePath = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedExecutablePath.isEmpty else {
            throw LaunchAtLoginError.missingExecutablePath
        }

        let folder = plistURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [resolvedExecutablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": ["Aqua"],
            "WorkingDirectory": (resolvedExecutablePath as NSString).deletingLastPathComponent,
            "StandardOutPath": "/tmp/groq-menubar-dictate.launchd.out.log",
            "StandardErrorPath": "/tmp/groq-menubar-dictate.launchd.err.log",
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
