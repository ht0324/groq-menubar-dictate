import Foundation

struct TranscriptResult {
    let text: String
    let model: String?
}

struct TranscriptionMetrics {
    let uploadPreparationMilliseconds: Double
    let networkRoundTripMilliseconds: Double
    let responseParseMilliseconds: Double
}

struct TranscriptionResponse {
    let transcript: TranscriptResult
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

    init(
        endpoint: URL = AppConfig.defaultGroqEndpoint,
        urlSession: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.fileManager = fileManager
    }

    func transcribe(
        fileURL: URL,
        apiKey: String,
        model: String,
        language: String?,
        prompt: String?,
        maxAudioBytes: Int,
        timeout: TimeInterval = 30,
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
        let audioData: Data
        do {
            audioData = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw GroqTranscriptionError.fileReadFailed
        }
        guard !audioData.isEmpty else {
            throw GroqTranscriptionError.missingAudio
        }

        let body = makeMultipartBody(
            boundary: boundary,
            fileData: audioData,
            fileName: fileURL.lastPathComponent,
            mimeType: mimeType(for: fileURL),
            model: model,
            language: language,
            prompt: prompt
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = body
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let uploadPreparationMilliseconds = millisecondsSince(uploadPreparationStart)

        let networkStart = collectMetrics ? DispatchTime.now() : nil
        let (data, response) = try await urlSession.data(for: request)
        let networkRoundTripMilliseconds = millisecondsSince(networkStart)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GroqTranscriptionError.malformedResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let message = readableBodyString(from: data)
            throw GroqTranscriptionError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        let parseStart = collectMetrics ? DispatchTime.now() : nil
        let transcript = try parseTranscriptResponse(data)
        let responseParseMilliseconds = millisecondsSince(parseStart)

        let metrics: TranscriptionMetrics?
        if collectMetrics {
            metrics = TranscriptionMetrics(
                uploadPreparationMilliseconds: uploadPreparationMilliseconds,
                networkRoundTripMilliseconds: networkRoundTripMilliseconds,
                responseParseMilliseconds: responseParseMilliseconds
            )
        } else {
            metrics = nil
        }

        return TranscriptionResponse(transcript: transcript, metrics: metrics)
    }

    private func makeMultipartBody(
        boundary: String,
        fileData: Data,
        fileName: String,
        mimeType: String,
        model: String,
        language: String?,
        prompt: String?
    ) -> Data {
        var body = Data()
        body.reserveCapacity(fileData.count + 1024 + model.utf8.count + (language?.utf8.count ?? 0) + (prompt?.utf8.count ?? 0))

        func writeUTF8(_ string: String) {
            body.append(Data(string.utf8))
        }

        func writeField(name: String, value: String) {
            writeUTF8("--\(boundary)\r\n")
            writeUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            writeUTF8("\(value)\r\n")
        }

        writeField(name: "model", value: model)
        writeField(name: "response_format", value: "json")
        if let language, !language.isEmpty {
            writeField(name: "language", value: language)
        }
        if let prompt, !prompt.isEmpty {
            writeField(name: "prompt", value: prompt)
        }

        writeUTF8("--\(boundary)\r\n")
        writeUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        writeUTF8("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        writeUTF8("\r\n")
        writeUTF8("--\(boundary)--\r\n")
        return body
    }

    private func audioFileSize(for fileURL: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw GroqTranscriptionError.fileReadFailed
        }
        return size.intValue
    }

    private func parseTranscriptResponse(_ data: Data) throws -> TranscriptResult {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dict = object as? [String: Any]
        {
            let text = (dict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let model = (dict["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return TranscriptResult(text: text, model: model?.isEmpty == false ? model : nil)
        }

        let fallback = readableBodyString(from: data)
        if !fallback.isEmpty {
            return TranscriptResult(text: fallback, model: nil)
        }
        throw GroqTranscriptionError.malformedResponse
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
}
