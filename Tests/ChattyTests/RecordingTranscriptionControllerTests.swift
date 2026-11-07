import Foundation
import Testing
@testable import Chatty

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RecordingTranscriptionControllerTests {
    @Test func uploadsSavedBytesPersistsCopiesAndPastesThenCanCopyAgain() async throws {
        try await withHistory { fixture in
            await fixture.fake.configure(behavior: .success, audioText: "Saved recording words.")
            fixture.controller.start(fixture.recording, prompt: "Chatty vocabulary", paste: true)
            try await fixture.wait(.complete)
            let saved = try #require(fixture.store.load().first)
            #expect(saved.transcript == "SAVED_RECORDING_WORDS")
            #expect(saved.transcriptionError == nil)
            #expect(fixture.copies == ["SAVED_RECORDING_WORDS"])
            #expect(fixture.pastes == 1)
            let request = try #require(await fixture.fake.receipts.first)
            #expect(request.prompt == "Chatty vocabulary")
            #expect(request.audioBytes == (try Data(contentsOf: fixture.store.audioURL(for: saved))).count)
            try fixture.controller.copy(saved)
            #expect(fixture.copies == ["SAVED_RECORDING_WORDS", "SAVED_RECORDING_WORDS"])
        }
    }

    @Test func failureIsPersistedAndRetryClearsIt() async throws {
        try await withHistory { fixture in
            await fixture.fake.configure(behavior: .rateLimited)
            fixture.controller.start(fixture.recording, prompt: nil)
            try await fixture.wait(.failed)
            #expect(try fixture.store.load().first?.transcriptionError != nil)
            #expect(fixture.copies.isEmpty)
            #expect(fixture.errors.count == 1)
            try fixture.controller.clearError(fixture.recording.id)
            #expect(try fixture.store.load().first?.transcriptionError == nil)
            await fixture.fake.configure(behavior: .success, audioText: "Recovered recording.")
            fixture.controller.retry(fixture.recording, prompt: nil)
            try await fixture.wait(.complete)
            #expect(try fixture.store.load().first?.transcript == "RECOVERED_RECORDING")
            #expect(try fixture.store.load().first?.transcriptionError == nil)
        }
    }

    @Test func cancelledHeldUploadCannotOverwriteRetry() async throws {
        try await withHistory { fixture in
            await fixture.fake.configure(behavior: .hold, audioText: "Stale recording.")
            fixture.controller.start(fixture.recording, prompt: nil)
            _ = try await fixture.fake.waitForRequests(1)
            fixture.controller.cancel(fixture.recording.id)
            #expect(fixture.controller.states[fixture.recording.id]?.phase == .cancelled)
            await fixture.fake.configure(behavior: .success, audioText: "New reply.")
            fixture.controller.retry(fixture.recording, prompt: nil)
            await fixture.fake.release()
            try await fixture.wait(.complete)
            #expect(try fixture.store.load().first?.transcript == "NEW_REPLY")
            #expect(fixture.copies == ["NEW_REPLY"])
            #expect(fixture.errors.isEmpty)
        }
    }

    @Test func backgroundReplyAndDelayedDismissCannotTouchNewDictation() async throws {
        try await withHistory { fixture in
            await fixture.fake.configure(behavior: .hold, audioText: "Background result.")
            fixture.controller.start(fixture.recording, prompt: nil)
            _ = try await fixture.fake.waitForRequests(1)
            let dictation = fixture.presentation.session(for: .dictation)
            dictation.begin(); dictation.showRecording()
            await fixture.fake.release()
            try await fixture.wait(.complete)
            #expect(fixture.copies.isEmpty)
            #expect(fixture.probe.visible)
            #expect(fixture.presentation.owner == .dictation)
            var changes = fixture.controller.changes().makeAsyncIterator()
            _ = await changes.next()
            await fixture.dismissal.open()
            _ = await changes.next()
            #expect(fixture.probe.visible)
            #expect(try fixture.store.load().first?.transcript == "BACKGROUND_RESULT")
        }
    }
}

@MainActor
private final class HistoryFixture {
    let store: RecordingStore
    let recording: Recording
    let fake: FakeOpenAI
    let probe = PresentationProbe()
    let presentation: OverlayPresentation
    let controller: RecordingTranscriptionController
    let dismissal = DebugGate()
    var copies: [String] = []
    var pastes = 0
    var errors: [String] = []
    init(store: RecordingStore, recording: Recording, fake: FakeOpenAI, endpoint: URL) {
        self.store = store; self.recording = recording; self.fake = fake
        presentation = OverlayPresentation(probe)
        let transcriber = OpenAITranscriber(credentials: OpenAICredentials(apiKey: FakeOpenAI.apiKey), endpoint: endpoint)
        let dismissal = self.dismissal
        controller = RecordingTranscriptionController(store: store, presentation: presentation,
            transcribe: { file, prompt in try await transcriber.transcribe(file: file, prompt: prompt) },
            dismissAfterSuccess: { await dismissal.wait() })
        controller.onCopy = { [weak self] in self?.copies.append($0) }
        controller.onPaste = { [weak self] in self?.pastes += 1 }
        controller.onError = { [weak self] in self?.errors.append($0) }
    }
    func wait(_ phase: RecordingTranscriptionController.State.Phase) async throws {
        for await _ in controller.changes() {
            try Task.checkCancellation()
            if controller.states[recording.id]?.phase == phase { return }
        }
        throw CancellationError()
    }
}

@MainActor
private func withHistory(_ body: @MainActor (HistoryFixture) async throws -> Void) async throws {
    try await withFake { fake, url in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChattyHistoryTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RecordingStore(directory: directory)
        let destination = try store.makeRecordingURL()
        let input = ScriptedDictationInputService()
        _ = try await input.start(recordingURL: destination.url)
        _ = try await input.stop()
        let recording = try store.addRecording(id: destination.id, audioURL: destination.url)
        let fixture = HistoryFixture(store: store, recording: recording, fake: fake, endpoint: url.appendingPathComponent("v1/audio/transcriptions"))
        do { try await body(fixture) }
        catch { fixture.controller.cancelAll(); await fixture.dismissal.open(); throw error }
        fixture.controller.cancelAll()
        await fixture.dismissal.open()
    }
}
