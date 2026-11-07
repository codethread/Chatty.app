import Foundation

struct OpenAITranscriber: Sendable {
    private let credentials: OpenAICredentials
    private let endpoint: URL

    init(credentials: OpenAICredentials = OpenAICredentials(),
         endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!) {
        self.credentials = credentials
        self.endpoint = endpoint
    }

    func transcribe(file: URL, prompt: String?) async throws -> String {
        let apiKey = try await credentials.load()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(file: file, prompt: prompt, boundary: boundary)

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = (String(data: data, encoding: .utf8) ?? "")
                .replacingOccurrences(of: #"\bsk-[A-Za-z0-9_*.-]+"#, with: "[redacted]", options: .regularExpression)
            throw TranscriptionError.api("OpenAI returned \(http.statusCode): \(body)")
        }
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.badResponse }
        return text
    }

    private func multipartBody(file: URL, prompt: String?, boundary: String) throws -> Data {
        var data = Data()
        func append(_ string: String) { data.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("gpt-4o-transcribe\r\n")

        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            append(prompt)
            append("\r\n")
        }

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
