import AppKit

/// Gives each operation an overlay lease. A late reply or delayed close can only
/// affect the presentation belonging to that operation.
@MainActor
final class OverlayPresentation {
    enum Owner: Equatable { case dictation, recording(UUID), message }
    private let target: any DictationPresenting
    private var activeID: UUID?
    private(set) var owner: Owner?

    init(_ target: any DictationPresenting) { self.target = target }
    func session(for owner: Owner) -> Session { Session(presentation: self, owner: owner) }

    @MainActor
    final class Session: DictationPresenting {
        private let presentation: OverlayPresentation
        private let owner: Owner
        private var id = UUID()
        var isCurrent: Bool { presentation.activeID == id }
        var transcriptWidth: CGFloat { presentation.target.transcriptWidth }

        fileprivate init(presentation: OverlayPresentation, owner: Owner) {
            self.presentation = presentation
            self.owner = owner
        }
        func begin() {
            id = UUID()
            presentation.activeID = id
            presentation.owner = owner
        }
        func showPreparing() { if isCurrent { presentation.target.showPreparing() } }
        func showRecording() { if isCurrent { presentation.target.showRecording() } }
        func updateCorrections(_ document: TranscriptCorrections, activeRange: NSRange?) {
            if isCurrent { presentation.target.updateCorrections(document, activeRange: activeRange) }
        }
        func updateLevel(_ level: Float) { if isCurrent { presentation.target.updateLevel(level) } }
        func updateFileSize(_ bytes: Int64) { if isCurrent { presentation.target.updateFileSize(bytes) } }
        func showProcessing(canCancel: Bool, canRetry: Bool, message: String) {
            if isCurrent { presentation.target.showProcessing(canCancel: canCancel, canRetry: canRetry, message: message) }
        }
        func showSuccess(message: String) { if isCurrent { presentation.target.showSuccess(message: message) } }
        func showError(_ message: String, canRetry: Bool) {
            if isCurrent { presentation.target.showError(message, canRetry: canRetry) }
        }
        func close() {
            if isCurrent {
                presentation.target.close()
                presentation.activeID = nil
                presentation.owner = nil
            }
        }
    }
}
