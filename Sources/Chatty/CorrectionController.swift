import AppKit

protocol TranscriptCorrecting: Sendable {
    func correct(_ text: String, settings: CorrectionSettings) async throws -> String
}

@MainActor
final class CorrectionController {
    private let corrector: any TranscriptCorrecting
    private var worker: Task<Void, Never>?
    private var activeBatch: CorrectionBatch?
    private var failure: Error?
    private(set) var document = TranscriptCorrections()
    var settings: CorrectionSettings = .default
    var contextWidth: CGFloat = TranscriptLayout.defaultWidth
    var onChange: ((TranscriptCorrections) -> Void)?
    var onError: ((Error) -> Void)?

    init(corrector: any TranscriptCorrecting) {
        self.corrector = corrector
    }

    func update(_ snapshot: TranscriptSnapshot, finalize: Bool = false) {
        document.update(snapshot, finalize: finalize)
        if let activeBatch, !document.contains(activeBatch) {
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
        activeBatch = nil
    }

    func reset() {
        cancel()
        failure = nil
        document = TranscriptCorrections()
        onChange?(document)
    }

    private func startWorker() {
        guard worker == nil, failure == nil else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled {
                let start = TranscriptLayout.contextStart(in: self.document.stableText,
                                                          lines: self.settings.contextLines, width: self.contextWidth)
                guard let batch = self.document.nextBatch(contextStart: start) else {
                    self.activeBatch = nil
                    self.worker = nil
                    return
                }
                self.activeBatch = batch
                do {
                    let corrected = try await self.corrector.correct(batch.text, settings: self.settings)
                    try Task.checkCancellation()
                    self.document.apply(corrected, to: batch)
                    self.onChange?(self.document)
                } catch {
                    if Task.isCancelled { return }
                    self.failure = error
                    self.activeBatch = nil
                    self.worker = nil
                    self.onError?(error)
                    return
                }
            }
        }
    }
}

#if CHATTY_DEBUG_PANEL
struct FakeTranscriptCorrector: TranscriptCorrecting {
    func correct(_ text: String, settings: CorrectionSettings) async throws -> String {
        try await Task.sleep(for: .seconds(1))
        return text.uppercased()
    }
}
#endif
