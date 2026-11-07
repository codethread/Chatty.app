#if DEBUG || CHATTY_DEBUG_PANEL
import Foundation
import Network

struct LocalHTTPRequest: Sendable {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
    var path: String { String(target.split(separator: "?", maxSplits: 1)[0]) }
}

struct LocalHTTPResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    var disconnect = false
    var onSent: (@Sendable () async -> Void)?

    static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> Self {
        Self(status: status, body: try JSONEncoder().encode(value))
    }
}

/// Test-only HTTP/1.1 listener. Binds to loopback on an OS-assigned port and
/// closes each connection after one Content-Length-framed request/response.
actor LocalHTTPServer {
    typealias Handler = @Sendable (LocalHTTPRequest) async -> LocalHTTPResponse
    private var listener: NWListener?
    private var connections: [UUID: (NWConnection, Task<Void, Never>)] = [:]

    func start(handler: @escaping Handler) async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let ready = AsyncThrowingStream<URL, Error>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.continuation.yield(URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!)
                ready.continuation.finish()
            case .failed(let error): ready.continuation.finish(throwing: error)
            case .cancelled: ready.continuation.finish()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection, handler: handler) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        for try await url in ready.stream { return url }
        throw CancellationError()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (connection, task) in connections.values {
            task.cancel()
            connection.cancel()
        }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection, handler: @escaping Handler) {
        let id = UUID()
        connection.start(queue: .global(qos: .userInitiated))
        let task = Task {
            do {
                let request = try await Self.read(connection)
                let response = await handler(request)
                if !response.disconnect { try await Self.send(response, to: connection) }
                await response.onSent?()
            } catch {
                if !Task.isCancelled {
                    let response = try! LocalHTTPResponse.json(["error": error.localizedDescription], status: 400)
                    try? await Self.send(response, to: connection)
                }
            }
            connection.cancel()
            connections.removeValue(forKey: id)
        }
        connections[id] = (connection, task)
    }

    private static func read(_ connection: NWConnection) async throws -> LocalHTTPRequest {
        let separator = Data("\r\n\r\n".utf8)
        var data = Data()
        var headerRange: Range<Data.Index>?
        while headerRange == nil {
            data.append(try await receive(connection))
            headerRange = data.range(of: separator)
            guard (headerRange?.lowerBound ?? data.count) <= 64 * 1024 else { throw HTTPError.invalid("Headers exceed 64 KiB") }
        }
        let headerEnd = headerRange!.upperBound
        guard let header = String(data: data[..<headerRange!.lowerBound], encoding: .utf8) else {
            throw HTTPError.invalid("Headers are not UTF-8")
        }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" else { throw HTTPError.invalid("Expected HTTP/1.1 request") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw HTTPError.invalid("Malformed header") }
            headers[String(pair[0]).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw HTTPError.invalid("Use Content-Length, not chunked transfer") }
        guard let length = Int(headers["content-length"] ?? "0"), (0...64 * 1024 * 1024).contains(length) else {
            throw HTTPError.invalid("Invalid Content-Length (maximum 64 MiB)")
        }
        while data.count - headerEnd < length { data.append(try await receive(connection)) }
        return LocalHTTPRequest(method: String(first[0]), target: String(first[1]), headers: headers,
                                body: Data(data[headerEnd..<(headerEnd + length)]))
    }

    private static func receive(_ connection: NWConnection) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: HTTPError.invalid("Connection closed before the request completed")) }
                }
            }
        } onCancel: { connection.cancel() }
    }

    private static func send(_ response: LocalHTTPResponse, to connection: NWConnection) async throws {
        var headers = response.headers
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        let head = "HTTP/1.1 \(response.status) Debug\r\n" + headers.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private enum HTTPError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case .invalid(let message): message } }
    }
}
#endif
