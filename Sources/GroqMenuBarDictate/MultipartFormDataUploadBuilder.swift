import Foundation

struct MultipartFormDataField {
    let name: String
    let value: String
}

struct MultipartFormDataFilePart {
    let fieldName: String
    let fileURL: URL
    let fileName: String
    let mimeType: String
}

struct MultipartFormDataUploadFile {
    let fileURL: URL
    let contentLength: Int64
}

struct MultipartFormDataUploadBuilder {
    private static let copyChunkSize = 64 * 1024

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func makeUploadFile(
        boundary: String,
        fields: [MultipartFormDataField],
        filePart: MultipartFormDataFilePart
    ) throws -> MultipartFormDataUploadFile {
        let bodyFileURL = fileManager.temporaryDirectory
            .appendingPathComponent("groq-multipart-\(UUID().uuidString)", isDirectory: false)

        guard fileManager.createFile(atPath: bodyFileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var bytesWritten: Int64 = 0
        do {
            let output = try FileHandle(forWritingTo: bodyFileURL)
            defer {
                try? output.close()
            }

            for field in fields {
                try writeField(field, boundary: boundary, to: output, bytesWritten: &bytesWritten)
            }

            try writeUTF8("--\(boundary)\r\n", to: output, bytesWritten: &bytesWritten)
            try writeUTF8(
                "Content-Disposition: form-data; name=\"\(filePart.fieldName)\"; filename=\"\(filePart.fileName)\"\r\n",
                to: output,
                bytesWritten: &bytesWritten
            )
            try writeUTF8("Content-Type: \(filePart.mimeType)\r\n\r\n", to: output, bytesWritten: &bytesWritten)
            try appendFile(at: filePart.fileURL, to: output, bytesWritten: &bytesWritten)
            try writeUTF8("\r\n", to: output, bytesWritten: &bytesWritten)
            try writeUTF8("--\(boundary)--\r\n", to: output, bytesWritten: &bytesWritten)
        } catch {
            try? fileManager.removeItem(at: bodyFileURL)
            throw error
        }

        return MultipartFormDataUploadFile(fileURL: bodyFileURL, contentLength: bytesWritten)
    }

    private func writeField(
        _ field: MultipartFormDataField,
        boundary: String,
        to output: FileHandle,
        bytesWritten: inout Int64
    ) throws {
        try writeUTF8("--\(boundary)\r\n", to: output, bytesWritten: &bytesWritten)
        try writeUTF8("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n", to: output, bytesWritten: &bytesWritten)
        try writeUTF8("\(field.value)\r\n", to: output, bytesWritten: &bytesWritten)
    }

    private func writeUTF8(
        _ string: String,
        to output: FileHandle,
        bytesWritten: inout Int64
    ) throws {
        let data = Data(string.utf8)
        try output.write(contentsOf: data)
        bytesWritten += Int64(data.count)
    }

    private func appendFile(
        at fileURL: URL,
        to output: FileHandle,
        bytesWritten: inout Int64
    ) throws {
        let input = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? input.close()
        }

        while let chunk = try input.read(upToCount: Self.copyChunkSize), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
            bytesWritten += Int64(chunk.count)
        }
    }
}
