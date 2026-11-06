import Foundation

/// A Keychain read can block in Security.framework. Keep it off the UI and
/// cooperative executors, share it between requests, and let callers cancel
/// their wait without waiting for Security.framework to return.
actor OpenAICredentials {
    private var key: String?
    private var loadingID: UUID?
    private var waiters: [UUID: AsyncThrowingStream<String, Error>.Continuation] = [:]

    init(apiKey: String? = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]) {
        if let apiKey {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { key = trimmed }
        }
    }

    func load() async throws -> String {
        try Task.checkCancellation()
        if let key { return key }
        let waiterID = UUID()
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        waiters[waiterID] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeWaiter(waiterID) }
        }
        if loadingID == nil {
            let id = UUID()
            loadingID = id
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let result = Result { try KeychainStore.requireAPIKey() }
                Task { await loaded(result, id: id) }
            }
        }
        for try await key in stream {
            try Task.checkCancellation()
            return key
        }
        throw CancellationError()
    }

    func use(_ key: String) {
        loadingID = nil
        complete(.success(key))
    }

    private func loaded(_ result: Result<String, Error>, id: UUID) {
        guard loadingID == id else { return }
        loadingID = nil
        complete(result)
    }

    private func complete(_ result: Result<String, Error>) {
        if case .success(let key) = result { self.key = key }
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending {
            switch result {
            case .success(let key):
                continuation.yield(key)
                continuation.finish()
            case .failure(let error): continuation.finish(throwing: error)
            }
        }
    }

    private func removeWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)
    }
}
