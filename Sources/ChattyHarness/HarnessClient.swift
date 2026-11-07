import Darwin
import Foundation

/// Native control client shared by the developer CLI and XCUITest observations.
/// UI tests use commands for fixture/fault setup; XCUI drives user actions.
@MainActor
public final class HarnessClient {
    private struct Connection: Decodable {
        let url: URL
        let token: String
        let pid: Int32
        let directory: URL
    }
    private let connection: Connection
    public var directory: URL { connection.directory }

    public init(controlFile: URL) throws {
        connection = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: controlFile))
        guard kill(connection.pid, 0) == 0 else {
            throw HarnessError("The debug app is not running. Launch it with scripts/run-debug.sh.")
        }
    }

    public func request(_ path: String, payload: [String: Any]? = nil, timeout: TimeInterval = 20) async throws -> Data {
        let url = URL(string: path, relativeTo: connection.url)!.absoluteURL
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(connection.token, forHTTPHeaderField: "X-Chatty-Debug-Token")
        if let payload {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(APIError.self, from: data).error) ?? "No error detail"
            throw HarnessError("HTTP \(status): \(message)", status: status)
        }
        return data
    }

    @discardableResult
    public func command(_ action: String, _ fields: [String: Any] = [:]) async throws -> Data {
        var payload = fields; payload["action"] = action
        return try await request("/command", payload: payload)
    }
    public func state() async throws -> HarnessState { try await decode(HarnessState.self, path: "/state") }
    public func wait(_ condition: [String: Any]) async throws -> HarnessState {
        let timeout = (condition["timeoutSeconds"] as? Int) ?? 15
        return try JSONDecoder().decode(HarnessState.self, from: await request("/wait", payload: condition, timeout: TimeInterval(max(20, timeout + 5))))
    }
    public func decode<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        try JSONDecoder().decode(type, from: await request(path))
    }
    private struct APIError: Decodable { let error: String }
}

public struct HarnessError: LocalizedError {
    public let message: String
    public let status: Int?
    public init(_ message: String, status: Int? = nil) { self.message = message; self.status = status }
    public var errorDescription: String? { message }
}

public struct HarnessState: Decodable {
    public struct Transcript: Decodable { public let committedText: String; public let partialText: String }
    public struct Recording: Decodable {
        public let id: String
        public let audioFilename: String
        public let transcript: String?
        public let transcriptionError: String?
    }
    public struct Overlay: Decodable {
        public struct Span: Decodable { public let kind: String; public let location: Int; public let length: Int }
        public let visible: Bool
        public let status: String
        public let text: String
        public let height: Double
        public let documentHeight: Double
        public let viewportHeight: Double
        public let scrollY: Double
        public let spans: [Span]
        public let canCancel: Bool
        public let canRetry: Bool
    }
    public struct Settings: Decodable, Equatable {
        public let prompt: String
        public let dictionary: [String: String]
        public let contextLines: Int
    }
    public struct Model: Decodable { public let phase: String; public let message: String; public let progress: Double? }
    public struct History: Decodable { public let phase: String; public let error: String? }
    public let phase: String
    public let failure: String?
    public let raw: Transcript
    public let corrected: String
    public let pending: String
    public let tail: String
    public let text: String
    public let copied: [String]
    public let completed: [String]
    public let pasteTarget: String
    public let overlay: Overlay
    public let recordingCount: Int
    public let latestRecording: Recording?
    public let storageError: String?
    public let requestCount: Int
    public let settings: Settings
    public let globalShortcuts: Bool
    public let history: [String: History]
    public let platform: [String: String]
    public let speechEngine: String
    public let model: Model
    public let recognitionEngine: String?
    public let clipboardNeedsRestore: Bool
    public let clipboardRestored: Bool
    public let systemPasteDispatches: Int
}

public struct HarnessRequestPage: Decodable {
    public struct Summary: Decodable { public let id: String; public let path: String; public let model: String; public let behavior: String }
    public let requests: [Summary]
    public let total: Int
    public let nextOffset: Int?
}
public struct HarnessReceipt: Decodable {
    public let id: String
    public let path: String
    public let input: String?
    public let instructions: String?
    public let model: String
    public let audioBytes: Int?
    public let audioSHA256: String?
    public let prompt: String?
}
