#if DEBUG || CHATTY_DEBUG_PANEL
import AVFoundation
import Foundation

actor DebugGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
final class ScriptedDictationInputService: DictationInputService {
    var holdPreparation = false
    var failStart = false
    var failStop = false
    var failCancel = false
    var savesRecording = true
    private var session: Session?

    func start(recordingURL: URL) async throws -> AsyncThrowingStream<DictationEvent, Error> {
        let session = Session(recordingURL: savesRecording ? recordingURL : nil)
        self.session = session
        if holdPreparation { await session.preparation.wait() }
        try Task.checkCancellation()
        guard self.session === session, !session.cancelled else { throw CancellationError() }
        if failStart { throw DebugInputError.injected("Input preparation failed") }
        if let url = session.recordingURL { try Self.writeAudioFixture(to: url) }
        session.ready = true
        session.events.continuation.yield(.transcript(.empty))
        return session.events.stream
    }

    func releasePreparation() async { await session?.preparation.open() }

    func inject(_ snapshot: TranscriptSnapshot) throws {
        let session = try activeSession()
        session.snapshot = snapshot
        session.events.continuation.yield(.transcript(snapshot))
    }

    func injectLevel(_ level: Float, fileSize: Int64) throws {
        let session = try activeSession()
        session.events.continuation.yield(.level(level))
        session.events.continuation.yield(.fileSize(fileSize))
    }

    func injectFailure() throws {
        try activeSession().events.continuation.finish(throwing: DebugInputError.injected("Input stream failed"))
    }

    func stop() async throws -> URL? {
        guard let session else { return nil }
        if let failure = session.stopFailure { throw failure }
        if failStop {
            let failure = DebugInputError.injected("Input finalization failed")
            session.stopFailure = failure
            session.events.continuation.finish(throwing: failure)
            throw failure
        }
        if !session.stopped {
            session.stopped = true
            session.events.continuation.yield(.transcript(TranscriptSnapshot(committedText: session.snapshot.text, partialText: "")))
            session.events.continuation.finish()
        }
        return session.recordingURL
    }

    func cancel() async throws {
        guard let session else { return }
        if failCancel { throw DebugInputError.injected("Input cancellation failed") }
        session.cancelled = true
        session.events.continuation.finish()
        await session.preparation.open()
        if let url = session.recordingURL, FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        self.session = nil
    }

    private func activeSession() throws -> Session {
        guard let session, session.ready, !session.stopped, !session.cancelled else {
            throw DebugInputError.injected("Start injected dictation before sending input")
        }
        return session
    }

    static func writeAudioFixture(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for index in 0..<16_000 {
            buffer.floatChannelData![0][index] = 0.05 * sin(Float(index) * 2 * .pi * 240 / 16_000)
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private final class Session {
        let recordingURL: URL?
        let events = AsyncThrowingStream<DictationEvent, Error>.makeStream()
        let preparation = DebugGate()
        var snapshot = TranscriptSnapshot.empty
        var ready = false
        var stopped = false
        var cancelled = false
        var stopFailure: Error?
        init(recordingURL: URL?) { self.recordingURL = recordingURL }
    }
}

struct DebugInputError: LocalizedError, Sendable {
    let message: String
    static func injected(_ message: String) -> Self { Self(message: message) }
    var errorDescription: String? { message }
}
#endif
