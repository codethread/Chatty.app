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
    var onChange: ((TranscriptCorrections, NSRange?) -> Void)?
    var onError: ((Error) -> Void)?

    init(corrector: any TranscriptCorrecting) {
        self.corrector = corrector
    }

    func update(_ snapshot: TranscriptSnapshot, finalize: Bool = false) {
        document.update(snapshot, finalize: finalize)
        if let activeBatch, !document.contains(activeBatch) {
            cancel()
        }
        publishChanges()
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
        publishChanges()
    }

    func reset() {
        cancel()
        failure = nil
        document = TranscriptCorrections()
        publishChanges()
    }

    private func publishChanges() {
        onChange?(document, activeBatch?.range)
    }

    private func startWorker() {
        guard worker == nil, failure == nil else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled {
                let start = TranscriptLayout.contextStart(in: self.document.correctedText,
                                                          lines: self.settings.contextLines, width: self.contextWidth)
                guard let batch = self.document.nextBatch(contextStart: start) else {
                    self.activeBatch = nil
                    self.worker = nil
                    return
                }
                self.activeBatch = batch
                self.publishChanges()
                do {
                    let corrected = try await self.corrector.correct(batch.text, settings: self.settings)
                    try Task.checkCancellation()
                    self.document.apply(corrected, to: batch)
                    self.activeBatch = nil
                    self.publishChanges()
                } catch {
                    if Task.isCancelled { return }
                    self.failure = error
                    self.activeBatch = nil
                    self.worker = nil
                    self.publishChanges()
                    self.onError?(error)
                    return
                }
            }
        }
    }
}
