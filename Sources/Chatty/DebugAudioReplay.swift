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
    var backend: SpeechRecognitionEngine = .nemotron
    var onDiagnostic: (@MainActor @Sendable (String) -> Void)?
    var onFinished: (() -> Void)?
    private let recognizer: LocalSpeechRecognizer
    private var session: Session?
    var recognitionEngine: SpeechRecognitionEngine? { session?.recognition.engine }

    init(recognizer: LocalSpeechRecognizer) { self.recognizer = recognizer }

    func start(recordingURL: URL) async throws -> AsyncThrowingStream<DictationEvent, Error> {
        let session = Session(recordingURL: recordingURL, recognition: SpeechRecognitionSession(engine: backend, local: recognizer))
        self.session = session
        try Task.checkCancellation()
        guard self.session === session else { throw CancellationError() }
        let url = audioURL!
        let format = try AVAudioFile(forReading: url).processingFormat
        let diagnostic = onDiagnostic
        let analysisFormat = try await session.recognition.start(inputFormat: format, input: session.analysis.stream,
            events: session.events.continuation, onDiagnostic: { await diagnostic?($0) }, onFailure: { error in
                session.events.continuation.finish(throwing: error)
                session.feeder?.cancel()
                session.processing?.cancel()
            })
        guard self.session === session else { throw CancellationError() }
        let processor = try MicrophoneBufferProcessor(recordingURL: recordingURL, inputFormat: format, analysisFormat: analysisFormat)
        let captured = session.captured
        let feeder = Task.detached {
            do {
                try await DebugAudioReplay.feed(url, into: captured.continuation, realtime: true, start: .now)
            } catch is CancellationError {
                // Stop means end of input; the recognizer still flushes its tail.
            }
        }
        session.feeder = feeder
        let processing = Task {
            try await processor.run(input: captured.stream, analysis: session.analysis.continuation,
                                    events: session.events.continuation)
        }
        session.processing = processing
        session.task = Task {
            do {
                try await processing.value
                try await feeder.value
                try await session.recognition.finish()
                session.events.continuation.finish()
                onFinished?()
            } catch {
                feeder.cancel()
                processing.cancel()
                await session.recognition.cancel()
                _ = try? await feeder.value
                _ = try? await processing.value
                session.events.continuation.finish(throwing: error)
                throw error
            }
        }
        return session.events.stream
    }

    func stop() async throws -> URL? {
        // Stopping a replay flushes the packets already supplied, just like mic stop.
        session?.feeder?.cancel()
        if let task = session?.task { try await task.value }
        else {
            session?.analysis.continuation.finish()
            await session?.recognition.cancel()
        }
        return session?.recordingURL
    }

    func cancel() async throws {
        let cancelled = session
        session = nil
        cancelled?.feeder?.cancel()
        cancelled?.processing?.cancel()
        cancelled?.task?.cancel()
        await cancelled?.recognition.cancel()
        _ = try? await cancelled?.task?.value
        cancelled?.events.continuation.finish()
        if let url = cancelled?.recordingURL, FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private final class Session {
        let captured = AsyncStream<AnalyzerInput>.makeStream()
        let analysis = AsyncStream<AnalyzerInput>.makeStream()
        let events = AsyncThrowingStream<DictationEvent, Error>.makeStream()
        let recordingURL: URL
        let recognition: SpeechRecognitionSession
        var feeder: Task<Void, Error>?
        var processing: Task<Void, Error>?
        var task: Task<Void, Error>?
        init(recordingURL: URL, recognition: SpeechRecognitionSession) {
            self.recordingURL = recordingURL; self.recognition = recognition
        }
    }
}
#endif
