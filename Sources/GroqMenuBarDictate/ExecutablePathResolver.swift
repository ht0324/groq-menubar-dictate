import Foundation

enum ExecutablePathResolver {
    static func resolve(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        fileManager: FileManager = .default
    ) -> String? {
        guard let rawArg0 = arguments.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawArg0.isEmpty else {
            return nil
        }

        if rawArg0.hasPrefix("/") {
            return rawArg0
        }

        if rawArg0.contains("/") {
            let candidate = URL(fileURLWithPath: currentDirectoryPath)
                .appendingPathComponent(rawArg0)
                .standardizedFileURL
                .path
            return fileManager.isExecutableFile(atPath: candidate) ? candidate : nil
        }

        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { entry in
                entry.isEmpty ? currentDirectoryPath : String(entry)
            }
        for entry in pathEntries {
            let candidate = URL(fileURLWithPath: entry)
                .appendingPathComponent(rawArg0)
                .standardizedFileURL
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }
}
