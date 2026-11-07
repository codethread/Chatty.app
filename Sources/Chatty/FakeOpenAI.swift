#if DEBUG || CHATTY_DEBUG_PANEL
import CryptoKit
import Foundation

/// Exercises the production URLSession, request encoder and response parser.
/// No credentials, requests or audio leave the loopback interface.
actor FakeOpenAI {
    static let apiKey = "chatty-local-fake"
    enum Behavior: String, Codable, CaseIterable, Sendable {
        case success, hold, unauthorized, rateLimited, serverError, malformed, empty, refused, incomplete, disconnect
    }
    struct Receipt: Codable, Sendable {
        let id: String
        let path: String
        let input: String?
        let instructions: String?
        let model: String
        let payload: String?
        let audioBytes: Int?
        let audioSHA256: String?
        let prompt: String?
        let behavior: Behavior
    }
    private let server = LocalHTTPServer()
    private(set) var receipts: [Receipt] = []
    private var behavior: Behavior = .success
    private var audioText = "Saved audio transcription"
    private var correctionText: String?
    private var held: [CheckedContinuation<Void, Never>] = []
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    func start() async throws -> URL {
        try await server.start { [weak self] request in
            guard let self else { return LocalHTTPResponse(status: 503) }
            return await self.respond(to: request)
        }
    }

    func configure(behavior: Behavior, audioText: String? = nil, correctionText: String? = nil) {
        self.behavior = behavior
        if let audioText { self.audioText = audioText }
        self.correctionText = correctionText
    }

    func currentBehavior() -> Behavior { behavior }

    func release() {
        let pending = held
        held.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func reset() {
        release()
        receipts.removeAll()
        behavior = .success
        correctionText = nil
    }

    func stop() async { release(); await server.stop() }

    func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.yield(())
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    func waitForRequests(_ count: Int) async throws -> [Receipt] {
        if receipts.count >= count { return receipts }
        let id = UUID()
        let changes = AsyncStream<Void>.makeStream()
        observers[id] = changes.continuation
        defer { observers.removeValue(forKey: id) }
        for await _ in changes.stream {
            try Task.checkCancellation()
            if receipts.count >= count { return receipts }
        }
        throw CancellationError()
    }

    static func screamingSnake(_ text: String) -> String {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.map { $0.uppercased() }.joined(separator: "_")
    }

    private func respond(to request: LocalHTTPRequest) async -> LocalHTTPResponse {
        let id = "fake-\(UUID().uuidString)"
        do {
            guard request.method == "POST" else { throw InvalidRequest(message: "Expected POST") }
            guard request.headers["authorization"] == "Bearer \(Self.apiKey)" else {
                return errorResponse(401, "Use the local fake credential")
            }
            let selected = behavior
            let output: String
            if request.path == "/v1/responses" {
                let payload = try JSONDecoder().decode(ResponsePayload.self, from: request.body)
                guard !payload.model.isEmpty, !payload.instructions.isEmpty,
                      payload.reasoning.effort == "none", payload.text.verbosity == "low",
                      payload.text.format.type == "json_schema", payload.text.format.strict,
                      payload.store == false, payload.service_tier == "priority" else {
                    throw InvalidRequest(message: "Invalid Chatty Responses payload")
                }
                receipts.append(Receipt(id: id, path: request.path, input: payload.input,
                                        instructions: payload.instructions, model: payload.model,
                                        payload: String(decoding: request.body, as: UTF8.self),
                                        audioBytes: nil, audioSHA256: nil, prompt: nil, behavior: selected))
                output = correctionText ?? Self.screamingSnake(payload.input)
            } else if request.path == "/v1/audio/transcriptions" {
                let fields = try Self.multipart(request)
                guard let audio = fields["file"], !audio.isEmpty, let model = fields["model"] else {
                    throw InvalidRequest(message: "Missing multipart audio or model")
                }
                receipts.append(Receipt(id: id, path: request.path, input: nil, instructions: nil,
                                        model: String(decoding: model, as: UTF8.self), payload: nil,
                                        audioBytes: audio.count,
                                        audioSHA256: SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined(),
                                        prompt: fields["prompt"].map { String(decoding: $0, as: UTF8.self) }, behavior: selected))
                output = Self.screamingSnake(audioText)
            } else { return errorResponse(404, "Unknown fake OpenAI endpoint") }
            for observer in observers.values { observer.yield(()) }
            if selected == .hold { await withCheckedContinuation { held.append($0) } }
            var response: LocalHTTPResponse
            switch selected {
            case .unauthorized: response = errorResponse(401, "Injected authentication failure")
            case .rateLimited: response = errorResponse(429, "Injected rate limit")
            case .serverError: response = errorResponse(500, "Injected server failure")
            case .disconnect: response = LocalHTTPResponse(disconnect: true)
            case .malformed: response = LocalHTTPResponse(body: Data("not JSON".utf8))
            case .empty:
                if request.path == "/v1/responses" {
                    response = LocalHTTPResponse(body: Data(#"{"status":"completed","output":[]}"#.utf8))
                } else { response = try completion("", path: request.path) }
            case .refused:
                response = LocalHTTPResponse(body: Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"Injected refusal"}]}]}"#.utf8))
            case .incomplete:
                response = LocalHTTPResponse(body: Data(#"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#.utf8))
            case .success, .hold: response = try completion(output, path: request.path)
            }
            response.headers["x-request-id"] = id
            return response
        } catch {
            return errorResponse(400, error.localizedDescription)
        }
    }

    private func completion(_ text: String, path: String) throws -> LocalHTTPResponse {
        if path == "/v1/audio/transcriptions" { return try .json(["text": text]) }
        let edited = String(decoding: try JSONEncoder().encode(TranscriptEdit(text: text)), as: UTF8.self)
        let payload: [String: Any] = ["status": "completed", "service_tier": "priority",
                                    "output": [["type": "message", "content": [["type": "output_text", "text": edited]]]]]
        return LocalHTTPResponse(body: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
    }

    private func errorResponse(_ status: Int, _ message: String) -> LocalHTTPResponse {
        try! .json(["error": ["message": message]], status: status)
    }

    private struct ResponsePayload: Decodable {
        struct Reasoning: Decodable { let effort: String }
        struct Text: Decodable {
            struct Format: Decodable { let type: String; let strict: Bool }
            let verbosity: String
            let format: Format
        }
        let model: String
        let instructions: String
        let input: String
        let reasoning: Reasoning
        let text: Text
        let store: Bool
        let service_tier: String
    }

    private static func multipart(_ request: LocalHTTPRequest) throws -> [String: Data] {
        guard let contentType = request.headers["content-type"],
              let boundary = contentType.components(separatedBy: "boundary=").last,
              contentType.hasPrefix("multipart/form-data;"), !boundary.isEmpty else {
            throw InvalidRequest(message: "Missing multipart boundary")
        }
        let marker = Data("--\(boundary)".utf8)
        let separator = Data("\r\n\r\n".utf8)
        var cursor = request.body.startIndex
        var fields: [String: Data] = [:]
        while let start = request.body.range(of: marker, in: cursor..<request.body.endIndex) {
            let headerStart = start.upperBound + 2
            guard headerStart < request.body.endIndex,
                  let split = request.body.range(of: separator, in: headerStart..<request.body.endIndex),
                  let next = request.body.range(of: marker, in: split.upperBound..<request.body.endIndex) else { break }
            let header = String(decoding: request.body[headerStart..<split.lowerBound], as: UTF8.self)
            guard let nameStart = header.range(of: "name=\""),
                  let nameEnd = header[nameStart.upperBound...].firstIndex(of: "\"") else {
                throw InvalidRequest(message: "Missing multipart field name")
            }
            fields[String(header[nameStart.upperBound..<nameEnd])] = Data(request.body[split.upperBound..<(next.lowerBound - 2)])
            cursor = next.lowerBound
        }
        return fields
    }

    private struct InvalidRequest: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
#endif
