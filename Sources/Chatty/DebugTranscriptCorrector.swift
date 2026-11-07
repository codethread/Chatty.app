#if CHATTY_DEBUG_PANEL
import Foundation

@MainActor
final class DebugTranscriptCorrector: TranscriptCorrecting {
    enum Backend: Int, CaseIterable {
        case fake, transcriptionOnly, openAI, pi
        var title: String {
            switch self {
            case .transcriptionOnly: "Transcription only · no cleanup"
            case .openAI: "OpenAI REST · gpt-5.4-mini · Fast"
            case .fake: "Local HTTP fake · SCREAMING_SNAKE_CASE"
            case .pi: "Pi · gpt-5.4-mini"
            }
        }
    }

    var backend: Backend = .fake
    var onDiagnosticsChange: (() -> Void)?
    private(set) var diagnostics = "Requests use the configured cleanup prompt and word dictionary. Credentials are never logged.\n"
    private(set) var lastStage = "Ready"
    private var activeRequests: [UUID: ContinuousClock.Instant] = [:]
    private let credentials: OpenAICredentials
    private var fake: OpenAITranscriptCorrector?
    private lazy var direct = OpenAITranscriptCorrector(credentials: credentials) { [weak self] event in
        await self?.record(event)
    }

    init(credentials: OpenAICredentials) { self.credentials = credentials }

    func connectFake(to baseURL: URL) {
        fake = OpenAITranscriptCorrector(credentials: OpenAICredentials(apiKey: FakeOpenAI.apiKey),
                                         endpoint: baseURL.appendingPathComponent("v1/responses")) { [weak self] event in
            await self?.record(event)
        }
    }

    func log(_ text: String) { diagnostics += text + "\n"; onDiagnosticsChange?() }

    var activity: String {
        guard let start = activeRequests.values.min() else { return lastStage }
        return "\(lastStage) · \(start.duration(to: .now).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1)))) elapsed"
    }

    func clearDiagnostics() {
        diagnostics = ""
        onDiagnosticsChange?()
    }

    func correct(_ text: String, settings: CorrectionSettings) async throws -> String {
        let selected = backend
        let corrector: any TranscriptCorrecting
        switch selected {
        case .transcriptionOnly: return text
        case .openAI: return try await direct.correct(text, settings: settings)
        case .fake:
            guard let fake else { throw DebugInputError.injected("The local HTTP fake is not ready") }
            return try await fake.correct(text, settings: settings)
        case .pi: corrector = PiTranscriptCorrector()
        }
        let id = UUID()
        let start = ContinuousClock.now
        func event(_ stage: CorrectionRequestEvent.Stage) -> CorrectionRequestEvent {
            .init(id: id, model: selected.title, input: text, elapsed: start.duration(to: .now), stage: stage)
        }
        record(event(.sending))
        do {
            let result = try await corrector.correct(text, settings: settings)
            try Task.checkCancellation()
            record(event(.completed(status: 0, requestID: nil, serviceTier: nil, text: result)))
            return result
        } catch {
            record(event(Task.isCancelled ? .cancelled : .failed(error.localizedDescription, requestID: nil)))
            throw error
        }
    }

    private func record(_ event: CorrectionRequestEvent) {
        let tag = String(event.id.uuidString.prefix(6))
        let time = event.elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated))
        var detail: String
        switch event.stage {
        case .credentials:
            activeRequests[event.id] = .now
            lastStage = "Loading API key"
            detail = "Loading credentials · \(event.model)\nInput: \(event.input)"
        case .sending:
            if activeRequests[event.id] == nil { activeRequests[event.id] = .now }
            lastStage = "Waiting for \(event.model)"
            detail = "Sending request · \(event.model)"
        case .completed(let status, let requestID, let serviceTier, let text):
            activeRequests.removeValue(forKey: event.id)
            lastStage = "Completed in \(time)"
            detail = "\(status == 0 ? "Completed" : "HTTP \(status)")\(serviceTier.map { " · tier \($0)" } ?? "")\(requestID.map { " · \($0)" } ?? "")\nOutput: \(text)"
        case .failed(let message, let requestID):
            activeRequests.removeValue(forKey: event.id)
            lastStage = "Failed in \(time)"
            detail = "Failed: \(message)\(requestID.map { " · \($0)" } ?? "")"
        case .cancelled:
            activeRequests.removeValue(forKey: event.id)
            lastStage = "Cancelled in \(time)"
            detail = "Cancelled"
        }
        diagnostics += "[\(tag) +\(time)] \(detail)\n"
        onDiagnosticsChange?()
    }
}
#endif
