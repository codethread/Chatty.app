import AppKit

@MainActor
protocol DictationPresenting: AnyObject {
    func begin()
    var transcriptWidth: CGFloat { get }
    func showPreparing()
    func showRecording()
    func updateCorrections(_ document: TranscriptCorrections, activeRange: NSRange?)
    func updateLevel(_ level: Float)
    func updateFileSize(_ bytes: Int64)
    func showProcessing(canCancel: Bool, canRetry: Bool, message: String)
    func showSuccess(message: String)
    func showError(_ message: String, canRetry: Bool)
    func close()
}

extension DictationPresenting {
    func begin() {}
    func showProcessing(canCancel: Bool = false, canRetry: Bool = false, message: String = "Finishing transcription…") {
        showProcessing(canCancel: canCancel, canRetry: canRetry, message: message)
    }

    func showError(_ message: String) { showError(message, canRetry: false) }
}
