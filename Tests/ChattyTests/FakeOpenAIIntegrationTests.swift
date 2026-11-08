import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import Chatty

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FakeOpenAIIntegrationTests {
    @Test(arguments: [true, false])
    func postsTheRealPayloadAndParsesScreamingSnakeOverHTTP(tapeEnabled: Bool) async throws {
        try await withFake { fake, url in
            let settings = CorrectionSettings(prompt: "Preserve my tone.", dictionary: ["jason": "JSON"], contextLines: 5,
                                              tapeEnabled: tapeEnabled, tapePrompt: "Follow my custom editing requests.")
            let corrector = OpenAITranscriptCorrector(credentials: OpenAICredentials(apiKey: FakeOpenAI.apiKey),
                                                     endpoint: url.appendingPathComponent("v1/responses"))
            let result = try await corrector.correct("Hello, café! Use JSON 🚀", settings: settings)
            #expect(result == "HELLO_CAFÉ_USE_JSON")
            let receipt = try #require(await fake.receipts.first)
            #expect(receipt.input == "Hello, café! Use JSON 🚀")
            #expect(receipt.instructions == settings.instructions)
            #expect(receipt.instructions?.contains(settings.tapePrompt) == tapeEnabled)
            #expect(receipt.model == OpenAITranscriptCorrector.model)
            #expect(receipt.payload?.contains(FakeOpenAI.apiKey) == false)
        }
    }

    @Test func cancellationEndsAHeldRequestAndTheSameClientCanSendAgain() async throws {
        try await withFake { fake, url in
            await fake.configure(behavior: .hold)
            let corrector = OpenAITranscriptCorrector(credentials: OpenAICredentials(apiKey: FakeOpenAI.apiKey),
                                                     endpoint: url.appendingPathComponent("v1/responses"))
            let pending = Task { try await corrector.correct("Old statement.", settings: .default) }
            _ = try await fake.waitForRequests(1)
            pending.cancel()
            do { _ = try await pending.value; Issue.record("Expected cancellation") }
            catch { #expect(error is CancellationError) }
            await fake.release()
            await fake.configure(behavior: .success)
            #expect(try await corrector.correct("New statement.", settings: .default) == "NEW_STATEMENT")
        }
    }

    @Test func uploadsTheExactAACBytesAndVocabularyThroughMultipart() async throws {
        try await withFake { fake, url in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let audio = directory.appendingPathComponent("fixture.m4a")
            try ScriptedDictationInputService.writeAudioFixture(to: audio)
            let decoded = try AVAudioFile(forReading: audio)
            #expect(decoded.length > 0)
            await fake.configure(behavior: .success, audioText: "Transcribed fixture audio")
            let client = OpenAITranscriber(credentials: OpenAICredentials(apiKey: FakeOpenAI.apiKey),
                                           endpoint: url.appendingPathComponent("v1/audio/transcriptions"))
            #expect(try await client.transcribe(file: audio, prompt: "Swift and AppKit") == "TRANSCRIBED_FIXTURE_AUDIO")
            let receipt = try #require(await fake.receipts.first)
            #expect(receipt.audioBytes == (try Data(contentsOf: audio).count))
            let hash = SHA256.hash(data: try Data(contentsOf: audio)).map { String(format: "%02x", $0) }.joined()
            #expect(receipt.audioSHA256 == hash)
            #expect(receipt.prompt == "Swift and AppKit")
            #expect(receipt.model == "gpt-4o-transcribe")
        }
    }
}

@MainActor
func withFake<T>(_ body: @MainActor (FakeOpenAI, URL) async throws -> T) async throws -> T {
    let fake = FakeOpenAI()
    let url = try await fake.start()
    do {
        let result = try await body(fake, url)
        await fake.stop()
        return result
    } catch {
        await fake.stop()
        throw error
    }
}
