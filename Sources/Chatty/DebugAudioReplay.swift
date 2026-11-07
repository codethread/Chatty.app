#if CHATTY_DEBUG_PANEL
import AVFoundation
import Foundation
import Speech

enum DebugAudioReplay {
    static func feed(
        _ url: URL, into captured: AsyncStream<AnalyzerInput>.Continuation,
        realtime: Bool, start: ContinuousClock.Instant,
        commonFormat: AVAudioCommonFormat = .pcmFormatFloat32
    ) async throws {
        defer { captured.finish() }
        let file = try AVAudioFile(forReading: url, commonFormat: commonFormat, interleaved: false)
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate * 0.08)
        var supplied = 0.0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
            try file.read(into: buffer)
            supplied += Double(buffer.frameLength) / file.processingFormat.sampleRate
            if realtime { try await ContinuousClock().sleep(until: start + .seconds(supplied)) }
            captured.yield(AnalyzerInput(buffer: buffer))
        }
    }
}

@MainActor
final class DebugAudioFileInputService: DictationInputService {
    var audioURL: URL!
    var onDiagnostic: (@MainActor @Sendable (String) -> Void)?
    var onFinished: (() -> Void)?
    private let recognizer: LocalSpeechRecognizer
    private var session: Session?

    init(recognizer: LocalSpeechRecognizer) { self.recognizer = recognizer }

    func start(recordingURL: URL) async throws -> AsyncThrowingStream<DictationEvent, Error> {
        let session = Session()
        self.session = session
        try await recognizer.prepare()
        try Task.checkCancellation()
        guard self.session === session else { throw CancellationError() }
        let url = audioURL!
        let captured = session.captured
        let feeder = Task.detached {
            do {
                try await DebugAudioReplay.feed(url, into: captured.continuation, realtime: true, start: .now)
            } catch is CancellationError {
                // Stop means end of input; the recognizer still flushes its tail.
            }
        }
        session.feeder = feeder
        let diagnostic = onDiagnostic
        session.task = Task {
            do {
                try await recognizer.run(input: captured.stream, events: session.events.continuation,
                                         onDiagnostic: { await diagnostic?($0) })
                try await feeder.value
                session.events.continuation.finish()
                onFinished?()
            } catch {
                feeder.cancel()
                _ = try? await feeder.value
                session.events.continuation.finish(throwing: error)
                throw error
            }
        }
        return session.events.stream
    }

    func stop() async throws -> URL? {
        // Stopping a replay flushes the packets already supplied, just like mic stop.
        session?.feeder?.cancel()
        try await session?.task?.value
        return nil
    }

    func cancel() async throws {
        let cancelled = session
        session = nil
        cancelled?.feeder?.cancel()
        cancelled?.task?.cancel()
        _ = try? await cancelled?.task?.value
        cancelled?.events.continuation.finish()
    }

    private final class Session {
        let captured = AsyncStream<AnalyzerInput>.makeStream()
        let events = AsyncThrowingStream<DictationEvent, Error>.makeStream()
        var feeder: Task<Void, Error>?
        var task: Task<Void, Error>?
    }
}
#endif
