import Foundation

@MainActor
final class DictationController {
    enum Phase: Equatable {
        case idle, preparing, listening, finishing, complete, failed(String)
    }

    private let input: any DictationInputService
    private let overlay: any DictationPresenting
    private let recordings: RecordingStore
    private let corrections: CorrectionController
    private var sessionID: UUID?
    private var destination: (id: UUID, url: URL)?
    private var indexedRecordingID: UUID?
    private var streamTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    private(set) var phase: Phase = .idle
    private(set) var transcript = TranscriptSnapshot.empty
    var correctionState: TranscriptCorrections { corrections.document }
    var onStateChange: (() -> Void)?
    var onActivityChange: ((Bool) -> Void)?
    var onCopy: ((String) -> Void)?
    var onComplete: ((String) -> Void)?
    var onError: ((String) -> Void)?

    var isActive: Bool {
        switch phase {
        case .preparing, .listening, .finishing: true
        case .idle, .complete, .failed: false
        }
    }

    init(input: any DictationInputService, corrections: CorrectionController, overlay: any DictationPresenting, recordings: RecordingStore) {
        self.input = input
        self.corrections = corrections
        self.overlay = overlay
        self.recordings = recordings
        corrections.onChange = { [weak self] document, activeRange in
            guard let self else { return }
            self.overlay.updateCorrections(document, activeRange: activeRange)
            self.corrections.contextWidth = self.overlay.transcriptWidth
            self.notifyChange()
        }
        corrections.onError = { [weak self] error in
            guard let self, let id = self.sessionID else { return }
            Task { await self.fail(error, session: id) }
        }
    }

    func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.yield(())
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.observers.removeValue(forKey: id) }
            }
        }
    }

    func toggle() async {
        switch phase {
        case .listening: await stop()
        case .preparing: await cancel()
        case .finishing: break
        case .idle, .complete, .failed: await start()
        }
    }

    func start() async {
        guard !isActive else { return }
        let id = UUID()
        sessionID = id
        destination = nil
        indexedRecordingID = nil
        transcript = .empty
        overlay.begin()
        corrections.reset()
        setPhase(.preparing)
        overlay.showPreparing()
        do {
            let destination = try recordings.makeRecordingURL()
            self.destination = destination
            let events = try await input.start(recordingURL: destination.url)
            guard sessionID == id else { return }
            setPhase(.listening)
            overlay.showRecording()
            streamTask = Task { [weak self] in
                do {
                    for try await event in events {
                        guard let self, self.sessionID == id, !Task.isCancelled else { return }
                        self.receive(event)
                    }
                } catch {
                    await self?.fail(error, session: id)
                }
            }
        } catch {
            await fail(error, session: id)
        }
    }

    func stop() async {
        if phase == .preparing {
            await cancel()
            return
        }
        guard phase == .listening, let id = sessionID else { return }
        setPhase(.finishing)
        overlay.showProcessing(canCancel: true)
        let completingStream = streamTask
        do {
            let audioURL = try await input.stop()
            await completingStream?.value
            guard sessionID == id else { return }
            guard !transcript.text.isEmpty else { throw DictationError.noSpeech }
            corrections.update(transcript, finalize: true)
            overlay.showProcessing(canCancel: true, message: "Tidying transcript…")
            try await corrections.finish()
            guard sessionID == id else { return }
            let correctedText = corrections.document.text
            if let audioURL, let destination {
                let recording = try recordings.addRecording(id: destination.id, audioURL: audioURL)
                indexedRecordingID = recording.id
                try recordings.updateTranscript(for: recording.id, transcript: correctedText)
            }
            sessionID = nil
            destination = nil
            streamTask = nil
            if !correctedText.isEmpty { onCopy?(correctedText) }
            clearTranscript()
            setPhase(.complete)
            if !correctedText.isEmpty { onComplete?(correctedText) }
        } catch {
            await fail(error, session: id)
        }
    }

    func cancel() async {
        let shouldCancelInput = sessionID != nil
        let cancellationID = UUID()
        sessionID = cancellationID
        let visibleText = corrections.document.text
        if !visibleText.isEmpty { onCopy?(visibleText) }
        streamTask?.cancel()
        streamTask = nil
        clearTranscript()
        setPhase(.finishing)
        do {
            if shouldCancelInput { try await input.cancel() }
            guard sessionID == cancellationID else { return }
            sessionID = nil
            destination = nil
            setPhase(.idle)
        } catch {
            guard sessionID == cancellationID else { return }
            await fail(error, session: cancellationID)
        }
    }

    private func clearTranscript() {
        overlay.close()
        transcript = .empty
        corrections.reset()
    }

    private func receive(_ event: DictationEvent) {
        switch event {
        case .transcript(let snapshot):
            transcript = snapshot
            corrections.update(snapshot)
        case .level(let level): overlay.updateLevel(level); notifyChange()
        case .fileSize(let bytes): overlay.updateFileSize(bytes); notifyChange()
        }
    }

    private func fail(_ error: Error, session id: UUID) async {
        guard sessionID == id else { return }
        let failureID = UUID()
        sessionID = failureID
        corrections.cancel()
        setPhase(.finishing)
        // Stop joins the service's shutdown even after its stream has failed.
        // The original failure remains the one shown to the user.
        _ = try? await input.stop()
        guard sessionID == failureID else { return }
        var message = error.localizedDescription
        if let destination, FileManager.default.fileExists(atPath: destination.url.path) {
            do {
                if indexedRecordingID != destination.id {
                    _ = try recordings.addRecording(id: destination.id, audioURL: destination.url)
                }
                try recordings.updateError(for: destination.id, message: message)
            } catch {
                message += "\nCould not save recording history: \(error.localizedDescription)"
            }
        }
        destination = nil
        sessionID = nil
        streamTask = nil
        setPhase(.failed(message))
        overlay.begin()
        overlay.showError(message)
        onError?(message)
    }

    private func setPhase(_ phase: Phase) {
        let wasActive = isActive
        self.phase = phase
        if wasActive != isActive { onActivityChange?(isActive) }
        notifyChange()
    }

    private func notifyChange() {
        onStateChange?()
        for observer in observers.values { observer.yield(()) }
    }
}

private enum DictationError: LocalizedError {
    case noSpeech
    var errorDescription: String? { "No speech was recognized. The recording has not been pasted." }
}
