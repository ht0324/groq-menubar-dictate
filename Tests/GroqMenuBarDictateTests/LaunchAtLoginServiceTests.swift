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
        let executablePath = "/Applications/Groq MenuBar Dictate.app/Contents/MacOS/groq-menubar-dictate"
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
        try writeLaunchAgentPlist(executablePath: "/Applications/Old.app/Contents/MacOS/groq-menubar-dictate")
        var launchctlCalls: [[String]] = []
        let service = LaunchAtLoginService(plistURL: plistURL) { args, _ in
            launchctlCalls.append(args)
        }

        try service.setEnabled(
            true,
            executablePath: "/Applications/Groq MenuBar Dictate.app/Contents/MacOS/groq-menubar-dictate"
        )

        XCTAssertEqual(launchctlCalls.map(\.first), ["bootout", "bootstrap"])
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

    private func writeLaunchAgentPlist(executablePath: String) throws {
        let plist: [String: Any] = [
            "Label": "com.huntae.groq-menubar-dictate",
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
    }
}
