import Foundation

struct CorrectionRequestEvent: Sendable {
    enum Stage: Sendable {
        case credentials
        case sending
        case completed(status: Int, requestID: String?, serviceTier: String?, text: String)
        case failed(String, requestID: String?)
        case cancelled
    }

    let id: UUID
    let model: String
    let input: String
    let elapsed: Duration
    let stage: Stage
}

final class OpenAITranscriptCorrector: TranscriptCorrecting {
    static let model = "gpt-5.4-mini"
    private let credentials: OpenAICredentials
    private let session: URLSession
    private let onEvent: (@Sendable (CorrectionRequestEvent) async -> Void)?

    init(credentials: OpenAICredentials, onEvent: (@Sendable (CorrectionRequestEvent) async -> Void)? = nil) {
        self.credentials = credentials
        self.onEvent = onEvent
        session = URLSession(configuration: .ephemeral)
    }

    deinit { session.invalidateAndCancel() }

    func correct(_ text: String, settings: CorrectionSettings) async throws -> String {
        let id = UUID()
        let started = ContinuousClock.now
        var requestID: String?
        func report(_ stage: CorrectionRequestEvent.Stage) async {
            await onEvent?(CorrectionRequestEvent(id: id, model: Self.model, input: text,
                                                 elapsed: started.duration(to: .now), stage: stage))
        }
        do {
            try Task.checkCancellation()
            await report(.credentials)
            let key = try await credentials.load()
            try Task.checkCancellation()
            let request = try Self.request(text, settings: settings, apiKey: key)
            await report(.sending)
            // URLSession's async API cancels this request with its calling Task.
            // The shared session remains available for subsequent batches.
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw OpenAICorrectionError.invalidResponse }
            requestID = http.value(forHTTPHeaderField: "x-request-id")
            let result = try Self.response(from: data, statusCode: http.statusCode)
            await report(.completed(status: http.statusCode,
                                    requestID: requestID, serviceTier: result.serviceTier, text: result.text))
            return result.text
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                await report(.cancelled)
                throw CancellationError()
            }
            await report(.failed(error.localizedDescription, requestID: requestID))
            throw error
        }
    }

    static func request(_ text: String, settings: CorrectionSettings, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(
            model: model, instructions: settings.instructions, input: text,
            reasoning: .init(effort: "none"), text: .init(verbosity: "low"),
            store: false, service_tier: "priority"
        ))
        return request
    }

    struct CorrectionResponse: Sendable {
        let text: String
        let serviceTier: String?
    }

    static func response(from data: Data, statusCode: Int) throws -> CorrectionResponse {
        guard (200..<300).contains(statusCode) else {
            let details = try? JSONDecoder().decode(APIError.self, from: data)
            let message = (details?.error.message ?? "Unexpected error response.")
                .replacingOccurrences(of: #"\bsk-[A-Za-z0-9_*.-]+"#, with: "[redacted]", options: .regularExpression)
            throw OpenAICorrectionError.api(statusCode, message)
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.status == "completed" else {
            throw OpenAICorrectionError.incomplete(response.incomplete_details?.reason ?? response.status)
        }
        let content = response.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
        if let refusal = content.first(where: { $0.type == "refusal" }) {
            throw OpenAICorrectionError.refused(refusal.refusal ?? "The model declined to edit this transcript.")
        }
        let text = content.filter { $0.type == "output_text" }.compactMap(\.text)
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenAICorrectionError.emptyResponse }
        return CorrectionResponse(text: text, serviceTier: response.service_tier)
    }

    private struct Request: Encodable {
        struct Reasoning: Encodable { let effort: String }
        struct Text: Encodable { let verbosity: String }
        let model: String
        let instructions: String
        let input: String
        let reasoning: Reasoning
        let text: Text
        let store: Bool
        let service_tier: String
    }

    private struct Response: Decodable {
        struct Details: Decodable { let reason: String }
        struct Output: Decodable {
            struct Content: Decodable {
                let type: String
                let text: String?
                let refusal: String?
            }
            let type: String
            let content: [Content]?
        }
        let status: String
        let output: [Output]
        let incomplete_details: Details?
        let service_tier: String?
    }

    private struct APIError: Decodable {
        struct Details: Decodable { let message: String }
        let error: Details
    }
}

private enum OpenAICorrectionError: LocalizedError {
    case invalidResponse, api(Int, String), incomplete(String), refused(String), emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "OpenAI returned an invalid HTTP response."
        case .api(let status, let details): "OpenAI HTTP \(status): \(details)"
        case .incomplete(let reason): "OpenAI transcript cleanup was incomplete (\(reason))."
        case .refused(let reason): "OpenAI transcript cleanup refused: \(reason)"
        case .emptyResponse: "OpenAI transcript cleanup returned no text."
        }
    }
}
