import Foundation

struct TranscriptionMetrics {
    let audioFileSizeBytes: Int
    let uploadBodySizeBytes: Int64
    let uploadPreparationMilliseconds: Double
    let networkRoundTripMilliseconds: Double
    let responseParseMilliseconds: Double
    let urlSessionTaskMetrics: TranscriptionURLSessionTaskMetrics?
}

struct TranscriptionURLSessionTaskMetrics: Sendable {
    let taskIntervalMilliseconds: Double
    let fetchToResponseEndMilliseconds: Double?
    let domainLookupMilliseconds: Double?
    let tcpConnectionMilliseconds: Double?
    let tlsHandshakeMilliseconds: Double?
    let requestUploadMilliseconds: Double?
    let timeToFirstByteAfterUploadMilliseconds: Double?
    let responseDownloadMilliseconds: Double?
    let networkProtocolName: String?
    let isReusedConnection: Bool?
}

struct TranscriptionResponse {
    let text: String
    let metrics: TranscriptionMetrics?
}

enum GroqTranscriptionError: LocalizedError {
    case fileReadFailed
    case missingAudio
    case audioTooLarge(maxBytes: Int)
    case requestFailed(statusCode: Int, message: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .fileReadFailed:
            return "Failed to read recorded audio."
        case .missingAudio:
            return "No audio was found."
        case let .audioTooLarge(maxBytes):
            return "Audio exceeds max size (\(maxBytes) bytes)."
        case let .requestFailed(statusCode, message):
            return "Groq request failed (\(statusCode)): \(message)"
        case .malformedResponse:
            return "Unexpected transcription response."
        }
    }
}

actor GroqTranscriptionService {
    private let endpoint: URL
    private let urlSession: URLSession
    private let fileManager: FileManager
    private let multipartBuilder: MultipartFormDataUploadBuilder
    private var prewarmTask: Task<Void, Never>?

    init(
        endpoint: URL = AppConfig.defaultGroqEndpoint,
        urlSession: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.fileManager = fileManager
        self.multipartBuilder = MultipartFormDataUploadBuilder(fileManager: fileManager)
    }

    /// Opens a connection to the transcription host so the DNS + TCP + TLS
    /// handshake overlaps with recording instead of delaying the upload.
    func prewarmConnection(timeout: TimeInterval = 5) {
        guard prewarmTask == nil else {
            return
        }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: true) else {
            return
        }
        components.path = "/"
        components.query = nil
        guard let prewarmURL = components.url else {
            return
        }

        var request = URLRequest(url: prewarmURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        prewarmTask = Task { [urlSession] in
            _ = try? await urlSession.data(for: request)
            self.clearPrewarmTask()
        }
    }

    private func clearPrewarmTask() {
        prewarmTask = nil
    }

    func transcribe(
        fileURL: URL,
        apiKey: String,
        model: String,
        language: String?,
        prompt: String?,
        maxAudioBytes: Int,
        timeout: TimeInterval = 20,
        collectMetrics: Bool = false
    ) async throws -> TranscriptionResponse {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw GroqTranscriptionError.missingAudio
        }

        let fileSizeBytes: Int
        do {
            fileSizeBytes = try audioFileSize(for: fileURL)
        } catch {
            throw GroqTranscriptionError.fileReadFailed
        }

        guard fileSizeBytes > 0 else {
            throw GroqTranscriptionError.missingAudio
        }
        guard fileSizeBytes <= maxAudioBytes else {
            throw GroqTranscriptionError.audioTooLarge(maxBytes: maxAudioBytes)
        }

        let uploadPreparationStart = collectMetrics ? DispatchTime.now() : nil
        let boundary = "Boundary-\(UUID().uuidString)"
        let fields = transcriptionFields(
            model: model,
            language: language,
            prompt: prompt
        )
        let filePart = MultipartFormDataFilePart(
            fieldName: "file",
            fileURL: fileURL,
            fileName: fileURL.lastPathComponent,
            mimeType: mimeType(for: fileURL)
        )
        let multipartBodyFile: MultipartFormDataUploadFile
        do {
            multipartBodyFile = try multipartBuilder.makeUploadFile(
                boundary: boundary,
                fields: fields,
                filePart: filePart
            )
        } catch {
            throw GroqTranscriptionError.fileReadFailed
        }
        defer {
            try? fileManager.removeItem(at: multipartBodyFile.fileURL)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(multipartBodyFile.contentLength), forHTTPHeaderField: "Content-Length")

        let uploadPreparationMilliseconds = millisecondsSince(uploadPreparationStart)

        let taskMetricsCollector = collectMetrics ? URLSessionTaskMetricsCollector() : nil
        let networkStart = collectMetrics ? DispatchTime.now() : nil
        let (data, response) = try await urlSession.upload(
            for: request,
            fromFile: multipartBodyFile.fileURL,
            delegate: taskMetricsCollector
        )
        let networkRoundTripMilliseconds = millisecondsSince(networkStart)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GroqTranscriptionError.malformedResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let message = readableBodyString(from: data)
            throw GroqTranscriptionError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        let parseStart = collectMetrics ? DispatchTime.now() : nil
        let text = try parseTranscriptResponse(data)
        let responseParseMilliseconds = millisecondsSince(parseStart)

        let metrics: TranscriptionMetrics?
        if collectMetrics {
            metrics = TranscriptionMetrics(
                audioFileSizeBytes: fileSizeBytes,
                uploadBodySizeBytes: multipartBodyFile.contentLength,
                uploadPreparationMilliseconds: uploadPreparationMilliseconds,
                networkRoundTripMilliseconds: networkRoundTripMilliseconds,
                responseParseMilliseconds: responseParseMilliseconds,
                urlSessionTaskMetrics: Self.makeTaskMetrics(from: taskMetricsCollector?.metrics)
            )
        } else {
            metrics = nil
        }

        return TranscriptionResponse(text: text, metrics: metrics)
    }

    private func transcriptionFields(
        model: String,
        language: String?,
        prompt: String?
    ) -> [MultipartFormDataField] {
        var fields = [
            MultipartFormDataField(name: "model", value: model),
            MultipartFormDataField(name: "response_format", value: "text"),
        ]
        if let language, !language.isEmpty {
            fields.append(MultipartFormDataField(name: "language", value: language))
        }
        if let prompt, !prompt.isEmpty {
            fields.append(MultipartFormDataField(name: "prompt", value: prompt))
        }
        return fields
    }

    private func audioFileSize(for fileURL: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw GroqTranscriptionError.fileReadFailed
        }
        return size.intValue
    }

    private func parseTranscriptResponse(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            throw GroqTranscriptionError.malformedResponse
        }
        return text
    }

    private func readableBodyString(from data: Data) -> String {
        let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if body.isEmpty {
            return "No response body."
        }
        if body.count > 500 {
            let index = body.index(body.startIndex, offsetBy: 500)
            return "\(body[..<index])..."
        }
        return body
    }

    private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "m4a":
            return "audio/m4a"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        case "ogg":
            return "audio/ogg"
        case "webm":
            return "audio/webm"
        default:
            return "application/octet-stream"
        }
    }

    private func millisecondsSince(_ start: DispatchTime?) -> Double {
        guard let start else {
            return 0
        }
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private static func makeTaskMetrics(from metrics: URLSessionTaskMetrics?) -> TranscriptionURLSessionTaskMetrics? {
        guard let metrics else {
            return nil
        }
        let transaction = metrics.transactionMetrics.last { $0.responseEndDate != nil }
            ?? metrics.transactionMetrics.last

        return TranscriptionURLSessionTaskMetrics(
            taskIntervalMilliseconds: metrics.taskInterval.duration * 1_000,
            fetchToResponseEndMilliseconds: milliseconds(from: transaction?.fetchStartDate, to: transaction?.responseEndDate),
            domainLookupMilliseconds: milliseconds(from: transaction?.domainLookupStartDate, to: transaction?.domainLookupEndDate),
            tcpConnectionMilliseconds: milliseconds(from: transaction?.connectStartDate, to: transaction?.connectEndDate),
            tlsHandshakeMilliseconds: milliseconds(from: transaction?.secureConnectionStartDate, to: transaction?.secureConnectionEndDate),
            requestUploadMilliseconds: milliseconds(from: transaction?.requestStartDate, to: transaction?.requestEndDate),
            timeToFirstByteAfterUploadMilliseconds: milliseconds(from: transaction?.requestEndDate, to: transaction?.responseStartDate),
            responseDownloadMilliseconds: milliseconds(from: transaction?.responseStartDate, to: transaction?.responseEndDate),
            networkProtocolName: transaction?.networkProtocolName,
            isReusedConnection: transaction?.isReusedConnection
        )
    }

    private static func milliseconds(from start: Date?, to end: Date?) -> Double? {
        guard let start, let end else {
            return nil
        }
        return max(0, end.timeIntervalSince(start) * 1_000)
    }
}

private final class URLSessionTaskMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var collectedMetrics: URLSessionTaskMetrics?

    var metrics: URLSessionTaskMetrics? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return collectedMetrics
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        collectedMetrics = metrics
        lock.unlock()
    }
}
