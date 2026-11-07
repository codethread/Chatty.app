import Foundation

@MainActor
final class RecordingTranscriptionController {
    struct State: Codable, Equatable, Sendable {
        enum Phase: String, Codable { case transcribing, complete, cancelled, failed }
        let phase: Phase
        let error: String?
    }
    private struct Run {
        let id: UUID
        let task: Task<Void, Never>
        let overlay: OverlayPresentation.Session
        let paste: Bool
    }
    typealias Transcribe = @Sendable (URL, String?) async throws -> String
    var transcribe: Transcribe
    private let store: RecordingStore
    private let presentation: OverlayPresentation
    private let dismissAfterSuccess: @Sendable () async throws -> Void
    private var runs: [UUID: Run] = [:]
    private var overlays: [UUID: OverlayPresentation.Session] = [:]
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private(set) var states: [UUID: State] = [:]
    var onChange: (() -> Void)?
    var onCopy: ((String) -> Void)?
    var onPaste: (() -> Void)?
    var onError: ((String) -> Void)?
    var activeIDs: Set<UUID> { Set(runs.keys) }

    init(store: RecordingStore, presentation: OverlayPresentation, transcribe: @escaping Transcribe,
         dismissAfterSuccess: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        self.store = store; self.presentation = presentation; self.transcribe = transcribe
        self.dismissAfterSuccess = dismissAfterSuccess
    }

    func start(_ recording: Recording, prompt: String?, paste: Bool = false) {
        guard runs[recording.id] == nil else { return }
        let runID = UUID()
        let overlay = presentation.session(for: .recording(recording.id))
        overlay.begin()
        overlay.showProcessing(canCancel: true, canRetry: true, message: "Transcribing saved recording…")
        overlays[recording.id] = overlay
        let transcribe = self.transcribe
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await transcribe(store.audioURL(for: recording), prompt)
                try Task.checkCancellation()
                guard runs[recording.id]?.id == runID else { return }
                try store.updateTranscript(for: recording.id, transcript: text)
                runs[recording.id] = nil
                states[recording.id] = State(phase: .complete, error: nil)
                if overlay.isCurrent {
                    onCopy?(text)
                    if paste { onPaste?() }
                    overlay.showSuccess(message: "Copied to clipboard")
                }
                changed()
                try await dismissAfterSuccess()
                overlay.close()
                if overlays[recording.id] === overlay { overlays[recording.id] = nil }
                changed()
            } catch {
                guard runs[recording.id]?.id == runID else { return }
                runs[recording.id] = nil
                if Task.isCancelled || error is CancellationError {
                    states[recording.id] = State(phase: .cancelled, error: nil)
                    overlay.close()
                } else {
                    var message = error.localizedDescription
                    do { try store.updateError(for: recording.id, message: message) }
                    catch { message += "\nCould not save recording history: \(error.localizedDescription)" }
                    states[recording.id] = State(phase: .failed, error: message)
                    overlay.showError(message, canRetry: true)
                    // Background failures remain in history without replacing another operation's UI.
                    if overlay.isCurrent { onError?(message) }
                }
                changed()
            }
        }
        runs[recording.id] = Run(id: runID, task: task, overlay: overlay, paste: paste)
        states[recording.id] = State(phase: .transcribing, error: nil)
        changed()
    }

    func cancel(_ id: UUID) {
        if let run = runs.removeValue(forKey: id) {
            run.task.cancel()
            states[id] = State(phase: .cancelled, error: nil)
        }
        overlays.removeValue(forKey: id)?.close()
        changed()
    }

    func retry(_ recording: Recording, prompt: String?) {
        let paste = runs[recording.id]?.paste ?? false
        cancel(recording.id)
        start(recording, prompt: prompt, paste: paste)
    }

    func cancelAll() {
        for id in Array(overlays.keys) { cancel(id) }
        states.removeAll()
        changed()
    }

    func copy(_ recording: Recording) throws {
        guard let text = recording.transcript, !text.isEmpty else { throw RecordingActionError.noTranscript }
        onCopy?(text)
        let overlay = presentation.session(for: .recording(recording.id))
        overlay.begin()
        overlays[recording.id] = overlay
        overlay.showSuccess(message: "Copied to clipboard")
        Task { [dismissAfterSuccess] in
            try? await dismissAfterSuccess()
            overlay.close()
            if overlays[recording.id] === overlay { overlays[recording.id] = nil }
            changed()
        }
        changed()
    }

    func clearError(_ id: UUID) throws {
        try store.clearError(for: id)
        states[id] = nil
        changed()
    }

    func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation; continuation.yield(())
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.observers.removeValue(forKey: id) }
            }
        }
    }
    private func changed() {
        onChange?()
        for observer in observers.values { observer.yield(()) }
    }
}

private enum RecordingActionError: LocalizedError {
    case noTranscript
    var errorDescription: String? { "This recording has no transcript to copy." }
}
