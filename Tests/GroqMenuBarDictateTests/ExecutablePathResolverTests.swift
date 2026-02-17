import Foundation
import XCTest
@testable import GroqMenuBarDictate

final class ExecutablePathResolverTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        tempDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("ExecutablePathResolverTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectoryURL {
            try? fileManager.removeItem(at: tempDirectoryURL)
        }
        tempDirectoryURL = nil
    }

    func testResolveFindsCommandOnPath() throws {
        let binURL = tempDirectoryURL.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: binURL, withIntermediateDirectories: true)
        let executableURL = binURL.appendingPathComponent("groq-menubar-dictate", isDirectory: false)
        try "#!/bin/sh\necho hi\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let resolved = ExecutablePathResolver.resolve(
            arguments: ["groq-menubar-dictate"],
            environment: ["PATH": binURL.path],
            currentDirectoryPath: tempDirectoryURL.path
        )

        XCTAssertEqual(resolved, executableURL.path)
    }

    func testResolveDoesNotFallBackToCurrentDirectoryForCommandNameOnly() {
        let resolved = ExecutablePathResolver.resolve(
            arguments: ["groq-menubar-dictate"],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectoryPath: tempDirectoryURL.path
        )

        XCTAssertNil(resolved)
    }
}
