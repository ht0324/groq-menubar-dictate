import Foundation
import XCTest
@testable import GroqMenuBarDictate

final class LaunchAtLoginServiceTests: XCTestCase {
    private var tempFolder: URL!
    private var plistURL: URL!

    override func setUpWithError() throws {
        tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchAtLoginServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        plistURL = tempFolder.appendingPathComponent("com.huntae.groq-menubar-dictate.plist")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempFolder)
        tempFolder = nil
        plistURL = nil
    }

    @MainActor
    func testSetEnabledSkipsLaunchctlWhenExistingPlistAlreadyMatches() throws {
        let executablePath = "/Applications/Bolt.app/Contents/MacOS/Bolt"
        try writeLaunchAgentPlist(executablePath: executablePath)
        var launchctlCalls: [[String]] = []
        let service = LaunchAtLoginService(plistURL: plistURL) { args, _ in
            launchctlCalls.append(args)
        }

        try service.setEnabled(true, executablePath: executablePath)

        XCTAssertTrue(launchctlCalls.isEmpty)
    }

    @MainActor
    func testSetEnabledRewritesLaunchctlWhenExecutablePathChanges() throws {
        try writeLaunchAgentPlist(executablePath: "/Applications/Old.app/Contents/MacOS/Bolt")
        var launchctlCalls: [[String]] = []
        let service = LaunchAtLoginService(plistURL: plistURL) { args, _ in
            launchctlCalls.append(args)
        }

        try service.setEnabled(
            true,
            executablePath: "/Applications/Bolt.app/Contents/MacOS/Bolt"
        )

        XCTAssertEqual(launchctlCalls.map(\.first), ["bootout", "bootstrap"])
    }

    @MainActor
    func testSetEnabledRewritesLaunchctlWhenLogPathsAreLegacyTmpPaths() throws {
        let executablePath = "/Applications/Bolt.app/Contents/MacOS/Bolt"
        try writeLaunchAgentPlist(
            executablePath: executablePath,
            standardOutPath: "/tmp/groq-menubar-dictate.launchd.out.log",
            standardErrorPath: "/tmp/groq-menubar-dictate.launchd.err.log"
        )
        var launchctlCalls: [[String]] = []
        let service = LaunchAtLoginService(plistURL: plistURL) { args, _ in
            launchctlCalls.append(args)
        }

        try service.setEnabled(true, executablePath: executablePath)

        XCTAssertEqual(launchctlCalls.map(\.first), ["bootout", "bootstrap"])
        let plist = try readLaunchAgentPlist()
        XCTAssertEqual(plist["StandardOutPath"] as? String, desiredStandardOutPath)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, desiredStandardErrorPath)
    }

    @MainActor
    func testSetDisabledSkipsLaunchctlWhenPlistIsMissing() throws {
        var launchctlCalls: [[String]] = []
        let service = LaunchAtLoginService(plistURL: plistURL) { args, _ in
            launchctlCalls.append(args)
        }

        try service.setEnabled(false, executablePath: "/unused")

        XCTAssertTrue(launchctlCalls.isEmpty)
    }

    private var desiredStandardOutPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent("groq-menubar-dictate.launchd.out.log")
            .path
    }

    private var desiredStandardErrorPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent("groq-menubar-dictate.launchd.err.log")
            .path
    }

    private func writeLaunchAgentPlist(
        executablePath: String,
        standardOutPath: String? = nil,
        standardErrorPath: String? = nil
    ) throws {
        let plist: [String: Any] = [
            "Label": "com.huntae.groq-menubar-dictate",
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "StandardOutPath": standardOutPath ?? desiredStandardOutPath,
            "StandardErrorPath": standardErrorPath ?? desiredStandardErrorPath,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
    }

    private func readLaunchAgentPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = plist as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return dictionary
    }
}
