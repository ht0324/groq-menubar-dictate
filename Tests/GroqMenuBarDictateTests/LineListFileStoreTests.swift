import XCTest
@testable import GroqMenuBarDictate

final class LineListFileStoreTests: XCTestCase {
    func testParseEntriesIgnoresCommentsDedupesCaseInsensitiveAndRespectsLimit() {
        let raw = """
        # comment
        Acme
        acme
        Widget Pro

        Launch Mode
        # another
        """

        let parsed = LineListFileStore.parseEntries(from: raw, limit: 2)

        XCTAssertEqual(parsed, ["Acme", "Widget Pro"])
    }

    func testLoadEntriesReloadsWhenFileModificationDateChanges() throws {
        let fixture = try LineListFixture(fileName: "entries.txt")
        defer { fixture.remove() }
        try "alpha\n".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        try fixture.setModificationDate(Date(timeIntervalSince1970: 100))
        let store = LineListFileStore(fileURL: fixture.fileURL, initialContents: "")

        XCTAssertEqual(store.loadEntries(limit: 10), ["alpha"])

        try "beta\n".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        try fixture.setModificationDate(Date(timeIntervalSince1970: 200))

        XCTAssertEqual(store.loadEntries(limit: 10), ["beta"])
    }

    func testLoadEntriesReturnsNoEntriesForCommentsOnlyFile() throws {
        let fixture = try LineListFixture(fileName: "entries.txt")
        defer { fixture.remove() }
        try "# comments only\n\n".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
        let store = LineListFileStore(
            fileURL: fixture.fileURL,
            initialContents: "thank you\n"
        )

        XCTAssertEqual(store.loadEntries(limit: 10), [])
    }
}

private final class LineListFixture {
    private let fileManager = FileManager.default
    let folderURL: URL
    let fileURL: URL

    init(fileName: String) throws {
        folderURL = fileManager.temporaryDirectory
            .appendingPathComponent("LineListFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        fileURL = folderURL.appendingPathComponent(fileName, isDirectory: false)
    }

    func setModificationDate(_ date: Date) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
    }

    func remove() {
        try? fileManager.removeItem(at: folderURL)
    }
}
