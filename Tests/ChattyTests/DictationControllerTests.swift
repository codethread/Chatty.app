import AppKit
import AVFoundation
import Foundation
import Testing
@testable import Chatty

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DictationControllerTests {
    @Test func stopFinalizesTailCopiesOnceAndPersistsPlayableAudioAndTranscript() async throws {
        try await withController { fixture in
            await fixture.controller.start()
            try fixture.input.inject(TranscriptSnapshot(committedText: "A sentence.", partialText: "Unfinished tail"))
            await fixture.controller.stop()
            #expect(fixture.controller.phase == .complete)
            #expect(fixture.copies == ["A_SENTENCE_UNFINISHED_TAIL"])
            #expect(fixture.completions == fixture.copies)
            #expect(!fixture.presentation.visible)
            #expect(fixture.controller.transcript == .empty)
            let saved = try #require(fixture.store.load().first)
            #expect(saved.transcript == fixture.copies.first)
            #expect(try AVAudioFile(forReading: fixture.store.audioURL(for: saved)).length > 0)
        }
    }

    @Test func stableSpeechCleansWhileTheProvisionalTailRemainsVisible() async throws {
        try await withController { fixture in
            await fixture.fake.configure(behavior: .hold)
            await fixture.controller.start()
            try fixture.input.inject(.init(committedText: "First sentence.", partialText: "live tail"))
            _ = try await fixture.fake.waitForRequests(1)
            #expect(fixture.presentation.document.pendingText == "First sentence.")
            #expect(fixture.presentation.document.tail == "live tail")
            #expect(fixture.presentation.activeRange == NSRange(location: 0, length: 15))
            try fixture.input.injectLevel(0.8, fileSize: 123_456)
            try await fixture.wait { fixture.presentation.bytes == 123_456 }
            #expect(fixture.presentation.level == 0.8)
            await fixture.fake.release()
            try await fixture.wait { fixture.controller.correctionState.correctedText == "FIRST_SENTENCE" }
            #expect(fixture.presentation.document.tail == "live tail")
            #expect(fixture.presentation.activeRange == nil)
            await fixture.controller.cancel()
        }
    }

    @Test func queuesSpeechAndSendsTheCorrectedContextInTheNextRequest() async throws {
        try await withController { fixture in
            await fixture.fake.configure(behavior: .hold)
            await fixture.controller.start()
            try fixture.input.inject(.init(committedText: "First sentence.", partialText: ""))
            _ = try await fixture.fake.waitForRequests(1)
            try fixture.input.inject(.init(committedText: "First sentence. Second sentence.", partialText: ""))
            try await fixture.wait { fixture.controller.transcript.committedText.contains("Second") }
            #expect(await fixture.fake.receipts.count == 1)
            await fixture.fake.configure(behavior: .success)
            await fixture.fake.release()
            let requests = try await fixture.fake.waitForRequests(2)
            #expect(requests[1].input == "FIRST_SENTENCE Second sentence.")
            await fixture.controller.stop()
            #expect(fixture.copies == ["FIRST_SENTENCE_SECOND_SENTENCE"])
        }
    }

    @Test func revisingInFlightRecognitionRejectsTheOldReply() async throws {
        try await withController { fixture in
            await fixture.fake.configure(behavior: .hold)
            await fixture.controller.start()
            try fixture.input.inject(.init(committedText: "Wrong name.", partialText: ""))
            _ = try await fixture.fake.waitForRequests(1)
            await fixture.fake.configure(behavior: .success)
            try fixture.input.inject(.init(committedText: "Correct name.", partialText: ""))
            _ = try await fixture.fake.waitForRequests(2)
            await fixture.fake.release()
            await fixture.controller.stop()
            #expect(fixture.copies == ["CORRECT_NAME"])
            #expect(fixture.errors.isEmpty)
        }
    }

    @Test func escapeCopiesVisibleTextDiscardsAudioAndLateRepliesCannotChangeANewSession() async throws {
        try await withController { fixture in
            await fixture.fake.configure(behavior: .hold)
            await fixture.controller.start()
            try fixture.input.inject(.init(committedText: "Old sentence.", partialText: "old tail"))
            _ = try await fixture.fake.waitForRequests(1)
            await fixture.controller.cancel()
            #expect(fixture.copies == ["Old sentence. old tail"])
            #expect(fixture.controller.phase == .idle)
            #expect(try fixture.store.load().isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.store.recordingsDirectory.path).isEmpty)
            await fixture.fake.configure(behavior: .success)
            await fixture.controller.start()
            try fixture.input.inject(.init(committedText: "New sentence.", partialText: ""))
            await fixture.fake.release()
            await fixture.controller.stop()
            #expect(fixture.copies == ["Old sentence. old tail", "NEW_SENTENCE"])
            #expect(fixture.completions == ["NEW_SENTENCE"])
        }
    }

    @Test func cancelWhilePreparingJoinsTheOldStartBeforeRestart() async throws {
        try await withController { fixture in
            fixture.input.holdPreparation = true
            let starting = Task { await fixture.controller.start() }
            try await fixture.wait { fixture.controller.phase == .preparing }
            await fixture.controller.cancel()
            await starting.value
            #expect(fixture.controller.phase == .idle)
            fixture.input.holdPreparation = false
            await fixture.controller.start()
            #expect(fixture.controller.phase == .listening)
            await fixture.controller.cancel()
        }
    }

    @Test(arguments: ["stream", "stop", "cleanup", "cancel"])
    func failuresPreserveAudioAndNeverCompleteOrPaste(stage: String) async throws {
        try await withController { fixture in
            await fixture.controller.start()
            try fixture.input.inject(.init(committedText: "A sentence.", partialText: ""))
            switch stage {
            case "stream": try fixture.input.injectFailure()
            case "stop": fixture.input.failStop = true; await fixture.controller.stop()
            case "cleanup":
                await fixture.fake.configure(behavior: .serverError)
                try fixture.input.inject(.init(committedText: "Revised sentence.", partialText: ""))
            case "cancel": fixture.input.failCancel = true; await fixture.controller.cancel()
            default: preconditionFailure()
            }
            try await fixture.wait { if case .failed = fixture.controller.phase { true } else { false } }
            #expect(fixture.completions.isEmpty)
            #expect(!fixture.errors.isEmpty)
            let saved = try #require(fixture.store.load().first)
            #expect(saved.transcriptionError != nil)
            #expect(try AVAudioFile(forReading: fixture.store.audioURL(for: saved)).length > 0)
        }
    }

    @Test func emptySpeechIsAnErrorAndPreparationFailureDoesNotCreateHistory() async throws {
        try await withController { fixture in
            fixture.input.failStart = true
            await fixture.controller.start()
            #expect(!fixture.controller.isActive)
            let history = try fixture.store.load()
            #expect(history.isEmpty)
            fixture.input.failStart = false
            await fixture.controller.start()
            await fixture.controller.stop()
            #expect(fixture.errors.last?.contains("No speech") == true)
            #expect(fixture.completions.isEmpty)
        }
    }
}

@MainActor
final class ControllerFixture {
    let directory: URL
    let store: RecordingStore
    let input = ScriptedDictationInputService()
    let presentation = PresentationProbe()
    let fake: FakeOpenAI
    let controller: DictationController
    private var changes: [UUID: AsyncStream<Void>.Continuation] = [:]
    var copies: [String] = []
    var completions: [String] = []
    var errors: [String] = []

    init(directory: URL, store: RecordingStore, corrector: OpenAITranscriptCorrector, fake: FakeOpenAI) {
        self.directory = directory
        self.store = store
        self.fake = fake
        controller = DictationController(input: input, corrections: CorrectionController(corrector: corrector),
                                        overlay: presentation, recordings: store)
        controller.onStateChange = { [weak self] in self?.changed() }
        controller.onCopy = { [weak self] in self?.copies.append($0) }
        controller.onComplete = { [weak self] in self?.completions.append($0) }
        controller.onError = { [weak self] in self?.errors.append($0) }
    }

    func wait(until condition: @MainActor () -> Bool) async throws {
        if condition() { return }
        let id = UUID()
        let stream = AsyncStream<Void>.makeStream()
        changes[id] = stream.continuation
        defer { changes.removeValue(forKey: id) }
        for await _ in stream.stream {
            try Task.checkCancellation()
            if condition() { return }
        }
        throw CancellationError()
    }

    private func changed() { for continuation in changes.values { continuation.yield(()) } }
}

@MainActor
final class PresentationProbe: DictationPresenting {
    var transcriptWidth: CGFloat = 672
    var document = TranscriptCorrections()
    var activeRange: NSRange?
    var visible = false
    var level: Float = 0
    var bytes: Int64 = 0
    func showPreparing() { visible = true }
    func showRecording() { visible = true }
    func updateCorrections(_ document: TranscriptCorrections, activeRange: NSRange?) { self.document = document; self.activeRange = activeRange }
    func updateLevel(_ level: Float) { self.level = level }
    func updateFileSize(_ bytes: Int64) { self.bytes = bytes }
    func showProcessing(canCancel: Bool, canRetry: Bool, message: String) { visible = true }
    func showSuccess(message: String) { visible = true }
    func showError(_ message: String, canRetry: Bool) { visible = true }
    func close() { visible = false }
}

@MainActor
func withController(_ body: @MainActor (ControllerFixture) async throws -> Void) async throws {
    try await withFake { fake, url in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChattyTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RecordingStore(directory: directory)
        let corrector = OpenAITranscriptCorrector(credentials: OpenAICredentials(apiKey: FakeOpenAI.apiKey),
                                                 endpoint: url.appendingPathComponent("v1/responses"))
        let fixture = ControllerFixture(directory: directory, store: store, corrector: corrector, fake: fake)
        try await body(fixture)
    }
}
