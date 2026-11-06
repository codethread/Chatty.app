import Foundation

protocol SentenceCorrecting: Sendable {
    func correct(_ sentence: String, settings: CorrectionSettings) async throws -> String
}

@MainActor
final class CorrectionController {
    private let corrector: any SentenceCorrecting
    private var worker: Task<Void, Never>?
    private var activeSentence: UUID?
    private var failure: Error?
    private(set) var document = SentenceCorrections()
    var settings: CorrectionSettings = .default
    var onChange: ((SentenceCorrections) -> Void)?
    var onError: ((Error) -> Void)?

    init(corrector: any SentenceCorrecting) {
        self.corrector = corrector
    }

    func update(_ snapshot: TranscriptSnapshot, finalize: Bool = false) {
        document.update(snapshot, finalize: finalize)
        if let activeSentence, !document.sentences.contains(where: { $0.id == activeSentence }) {
            cancel()
        }
        onChange?(document)
        startWorker()
    }

    func finish() async throws {
        await worker?.value
        if let failure { throw failure }
        try Task.checkCancellation()
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        activeSentence = nil
    }

    func reset() {
        cancel()
        failure = nil
        document = SentenceCorrections()
        onChange?(document)
    }

    private func startWorker() {
        guard worker == nil, failure == nil else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let sentence = self.document.sentences.first(where: { $0.correction == nil }) else {
                    self.activeSentence = nil
                    self.worker = nil
                    return
                }
                self.activeSentence = sentence.id
                do {
                    let corrected = try await self.corrector.correct(sentence.source, settings: self.settings)
                    try Task.checkCancellation()
                    self.document.apply(corrected, to: sentence.id)
                    self.onChange?(self.document)
                } catch {
                    if Task.isCancelled { return }
                    self.failure = error
                    self.activeSentence = nil
                    self.worker = nil
                    self.onError?(error)
                    return
                }
            }
        }
    }
}

#if CHATTY_DEBUG_PANEL
struct FakeSentenceCorrector: SentenceCorrecting {
    func correct(_ sentence: String, settings: CorrectionSettings) async throws -> String {
        try await Task.sleep(for: .seconds(1))
        return sentence.uppercased()
    }
}
#endif
