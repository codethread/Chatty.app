#if CHATTY_DEBUG_PANEL
import Foundation

@MainActor
final class DebugSentenceCorrector: SentenceCorrecting {
    enum Backend: Int, CaseIterable {
        case openAI, fake, pi
        var title: String {
            switch self {
            case .openAI: "OpenAI REST · gpt-5.4-mini · Fast"
            case .fake: "Fake · uppercase after 1 second"
            case .pi: "Pi · gpt-5.4-mini"
            }
        }
    }

    var backend: Backend = .openAI
    var onDiagnosticsChange: (() -> Void)?
    private(set) var diagnostics = "Requests use the configured cleanup prompt and word dictionary. Credentials are never logged.\n"
    private(set) var lastStage = "Ready"
    private var activeRequests: [UUID: ContinuousClock.Instant] = [:]
    private let credentials: OpenAICredentials
    private lazy var direct = OpenAISentenceCorrector(credentials: credentials) { [weak self] event in
        await self?.record(event)
    }

    init(credentials: OpenAICredentials) { self.credentials = credentials }

    var activity: String {
        guard let start = activeRequests.values.min() else { return lastStage }
        return "\(lastStage) · \(start.duration(to: .now).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1)))) elapsed"
    }

    func clearDiagnostics() {
        diagnostics = ""
        onDiagnosticsChange?()
    }

    func correct(_ sentence: String, settings: CorrectionSettings) async throws -> String {
        let selected = backend
        let corrector: any SentenceCorrecting
        switch selected {
        case .openAI: return try await direct.correct(sentence, settings: settings)
        case .fake: corrector = FakeSentenceCorrector()
        case .pi: corrector = PiSentenceCorrector()
        }
        let id = UUID()
        let start = ContinuousClock.now
        func event(_ stage: CorrectionRequestEvent.Stage) -> CorrectionRequestEvent {
            .init(id: id, model: selected.title, sentence: sentence, elapsed: start.duration(to: .now), stage: stage)
        }
        record(event(.sending))
        do {
            let result = try await corrector.correct(sentence, settings: settings)
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
            detail = "Loading credentials · \(event.model)\nInput: \(event.sentence)"
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
