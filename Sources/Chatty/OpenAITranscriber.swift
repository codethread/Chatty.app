import Foundation

struct OpenAITranscriber {
    func transcribe(file: URL) async throws -> String {
        let apiKey = KeychainStore.readAPIKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw TranscriptionError.missingAPIKey }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(file: file, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.api("OpenAI returned \(http.statusCode): \(body)")
        }
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func multipartBody(file: URL, boundary: String) throws -> Data {
        var data = Data()
        func append(_ string: String) { data.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("gpt-4o-transcribe\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n")
        append("Content-Type: audio/mp4\r\n\r\n")
        data.append(try Data(contentsOf: file))
        append("\r\n--\(boundary)--\r\n")
        return data
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

enum TranscriptionError: LocalizedError {
    case missingAPIKey
    case badResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Missing OpenAI API key. Click the menu bar icon and choose Set OpenAI API Key."
        case .badResponse: "OpenAI returned an invalid response."
        case .api(let message): message
        }
    }
}
