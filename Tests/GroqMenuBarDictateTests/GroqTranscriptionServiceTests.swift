import Foundation
import XCTest
@testable import GroqMenuBarDictate

final class GroqTranscriptionServiceTests: XCTestCase {
    func testTranscribeRequestsPlainTextAndParsesTextResponse() async throws {
        let fileManager = FileManager.default
        let tempFolder = fileManager.temporaryDirectory
            .appendingPathComponent("GroqTranscriptionServiceTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempFolder) }

        let audioURL = tempFolder.appendingPathComponent("sample.m4a", isDirectory: false)
        try Data([0, 1, 2, 3]).write(to: audioURL)

        let requestCapture = RequestCapture()
        URLProtocolStub.handlerStore.setHandler { request in
            requestCapture.record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/plain"]
            )!
            return (response, Data("  hello world  ".utf8))
        }
        defer { URLProtocolStub.handlerStore.setHandler(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let service = GroqTranscriptionService(
            endpoint: URL(string: "https://example.test/audio/transcriptions")!,
            urlSession: URLSession(configuration: configuration)
        )

        let response = try await service.transcribe(
            fileURL: audioURL,
            apiKey: "test-key",
            model: "whisper-large-v3-turbo",
            language: "en",
            prompt: "Use exact spelling for Groq.",
            maxAudioBytes: 1024
        )

        XCTAssertEqual(response.text, "hello world")
        let request = try XCTUnwrap(requestCapture.recordedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/plain")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let contentLength = try XCTUnwrap(Int(try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Length"))))
        XCTAssertGreaterThan(contentLength, 4)
        XCTAssertTrue(
            try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
                .hasPrefix("multipart/form-data; boundary=Boundary-")
        )
    }

    func testMultipartBuilderWritesFieldsAndFileToUploadFile() throws {
        let fileManager = FileManager.default
        let tempFolder = fileManager.temporaryDirectory
            .appendingPathComponent("MultipartFormDataUploadBuilderTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempFolder) }

        let audioURL = tempFolder.appendingPathComponent("sample.m4a", isDirectory: false)
        try Data("audio-bytes".utf8).write(to: audioURL)

        let uploadFile = try MultipartFormDataUploadBuilder(fileManager: fileManager).makeUploadFile(
            boundary: "Boundary-Test",
            fields: [
                MultipartFormDataField(name: "model", value: "whisper-large-v3-turbo"),
                MultipartFormDataField(name: "response_format", value: "text"),
            ],
            filePart: MultipartFormDataFilePart(
                fieldName: "file",
                fileURL: audioURL,
                fileName: "sample.m4a",
                mimeType: "audio/m4a"
            )
        )

        let body = try String(contentsOf: uploadFile.fileURL, encoding: .utf8)
        XCTAssertEqual(Int64(body.utf8.count), uploadFile.contentLength)
        XCTAssertTrue(body.contains("name=\"model\""))
        XCTAssertTrue(body.contains("whisper-large-v3-turbo"))
        XCTAssertTrue(body.contains("name=\"response_format\""))
        XCTAssertTrue(body.contains("text"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"sample.m4a\""))
        XCTAssertTrue(body.contains("Content-Type: audio/m4a"))
        XCTAssertTrue(body.contains("audio-bytes"))
        XCTAssertTrue(body.hasSuffix("--Boundary-Test--\r\n"))
    }
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    var recordedRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        self.request = request
    }
}

private final class URLProtocolHandlerStore: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private let lock = NSLock()
    private var handler: Handler?

    func setHandler(_ handler: Handler?) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let currentHandler: Handler?
        lock.lock()
        currentHandler = handler
        lock.unlock()

        guard let currentHandler else {
            throw NSError(domain: "GroqTranscriptionServiceTests", code: 1)
        }
        return try currentHandler(request)
    }
}

private final class URLProtocolStub: URLProtocol {
    static let handlerStore = URLProtocolHandlerStore()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let (response, data) = try Self.handlerStore.handle(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
