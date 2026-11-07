import AppKit
import Foundation
import Testing
@testable import Chatty

struct PersistenceTests {
    @Test func recordingMetadataReloadsWithErrorsAndTranscriptRecovery() throws {
        try inTemporaryDirectory { directory in
            let store = try RecordingStore(directory: directory)
            let destination = try store.makeRecordingURL()
            try Data("audio fixture".utf8).write(to: destination.url)
            let saved = try store.addRecording(id: destination.id, audioURL: destination.url)
            try store.updateError(for: saved.id, message: "Upload failed")
            let reopened = try RecordingStore(directory: directory)
            #expect(try reopened.load().first?.transcriptionError == "Upload failed")
            try reopened.clearError(for: saved.id)
            #expect(try reopened.load().first?.transcriptionError == nil)
            try reopened.updateError(for: saved.id, message: "Retry failed")
            try reopened.updateTranscript(for: saved.id, transcript: "RECOVERED_TEXT")
            #expect(try reopened.load().first?.transcript == "RECOVERED_TEXT")
            #expect(try reopened.load().first?.transcriptionError == nil)
            #expect(reopened.audioURL(for: saved) == destination.url)
        }
    }

    @Test func retentionRemovesOnlyExpiredAudioAndMetadata() throws {
        try inTemporaryDirectory { directory in
            let store = try RecordingStore(directory: directory)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let old = try store.makeRecordingURL()
            let recent = try store.makeRecordingURL()
            try Data([1]).write(to: old.url)
            try Data([2]).write(to: recent.url)
            _ = try store.addRecording(id: old.id, audioURL: old.url, createdAt: now.addingTimeInterval(-30 * 86400))
            _ = try store.addRecording(id: recent.id, audioURL: recent.url, createdAt: now)
            #expect(try store.pruneRecordingsOlderThan(days: 14, now: now) == 1)
            #expect(!FileManager.default.fileExists(atPath: old.url.path))
            #expect(FileManager.default.fileExists(atPath: recent.url.path))
            #expect(try store.load().map(\.id) == [recent.id])
        }
    }

    @Test func corruptionAndUnwritableStorageFailVisiblyWithoutReplacingMetadata() throws {
        try inTemporaryDirectory { directory in
            let store = try RecordingStore(directory: directory)
            let metadata = directory.appendingPathComponent("recordings.json")
            let corrupt = Data("broken metadata".utf8)
            try corrupt.write(to: metadata)
            #expect(throws: (any Error).self) { try store.load() }
            #expect(try Data(contentsOf: metadata) == corrupt)
            let obstruction = directory.appendingPathComponent("not-a-directory")
            try Data([1]).write(to: obstruction)
            #expect(throws: (any Error).self) { try RecordingStore(directory: obstruction) }
        }
    }

    @MainActor
    @Test func settingsPersistThroughTheRealConfigStoreAndRemainIsolated() throws {
        try inTemporaryDirectory { directory in
            let store = ConfigStore(directory: directory)
            let settings = CorrectionSettings(prompt: "Keep my words.", dictionary: ["jason": "JSON"], contextLines: 7)
            _ = try store.setCorrectionSettings(settings)
            _ = try store.setTranscriptionPrompt("Swift and AppKit")
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control],
                                        timestamp: 0, windowNumber: 0, context: nil, characters: "9",
                                        charactersIgnoringModifiers: "9", isARepeat: false, keyCode: 25)!
            let binding = try #require(KeyBinding(event: event))
            _ = try store.setRecordingShortcut(binding)
            let reloaded = try ConfigStore(directory: directory).load()
            #expect(reloaded.effectiveCorrectionSettings == settings)
            #expect(reloaded.transcriptionPrompt == "Swift and AppKit")
            #expect(reloaded.recordingShortcut == binding)
            #expect(directory != RecordingStore.defaultDirectory)
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CredentialsTests {
    @Test func sharedCredentialReadSurvivesOneCallerCancellingAndCachesTheResult() async throws {
        let source = CredentialSource()
        let credentials = OpenAICredentials(apiKey: nil, readKey: { try await source.read() })
        let first = Task { try await credentials.load() }
        await source.started.wait()
        let second = Task { try await credentials.load() }
        first.cancel()
        await source.gate.open()
        do { _ = try await first.value; Issue.record("Expected cancelled waiter") }
        catch { #expect(error is CancellationError) }
        #expect(try await second.value == "test-credential")
        #expect(try await credentials.load() == "test-credential")
        #expect(await source.reads == 1)
    }

    @Test func replacingAKeyWinsOverAnOlderPendingKeychainRead() async throws {
        let source = CredentialSource()
        let credentials = OpenAICredentials(apiKey: nil, readKey: { try await source.read() })
        let waiting = Task { try await credentials.load() }
        await source.started.wait()
        await credentials.use("replacement")
        #expect(try await waiting.value == "replacement")
        await source.gate.open()
        #expect(try await credentials.load() == "replacement")
    }

    @Test func credentialFailureIsReportedAndTheNextAttemptCanSucceed() async throws {
        let source = CredentialSource()
        await source.setFailure(true)
        await source.gate.open()
        let credentials = OpenAICredentials(apiKey: nil, readKey: { try await source.read() })
        do { _ = try await credentials.load(); Issue.record("Expected credential failure") }
        catch { #expect(error.localizedDescription == "Injected credential failure") }
        await source.setFailure(false)
        #expect(try await credentials.load() == "test-credential")
        #expect(await source.reads == 2)
    }
}

private actor CredentialSource {
    let started = DebugGate()
    let gate = DebugGate()
    private(set) var reads = 0
    private var fails = false
    func setFailure(_ value: Bool) { fails = value }
    func read() async throws -> String {
        reads += 1
        await started.open()
        await gate.wait()
        if fails { throw DebugInputError.injected("Injected credential failure") }
        return "test-credential"
    }
}

func inTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChattyTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}
