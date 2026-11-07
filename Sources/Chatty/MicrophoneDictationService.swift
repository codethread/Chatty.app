import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Speech
import Synchronization

@MainActor
final class MicrophoneDictationService: DictationInputService {
    private static let logger = Logger(subsystem: "local.chatty.Chatty", category: "Recording")
    private let locale: Locale
    var backend: SpeechRecognitionEngine
    private let localRecognizer: LocalSpeechRecognizer
    private var session: Session?
    var recognitionEngine: SpeechRecognitionEngine? { session?.recognition.engine }
    var onDiagnostic: (@MainActor @Sendable (String) -> Void)?

    init(locale: Locale = .current, backend: SpeechRecognitionEngine = .apple,
         localRecognizer: LocalSpeechRecognizer = LocalSpeechRecognizer()) {
        self.locale = locale
        self.backend = backend
        self.localRecognizer = localRecognizer
    }

    func prepareLocalModel() async throws { try await localRecognizer.prepare(allowDownload: true) }

    func start(recordingURL: URL) async throws -> AsyncThrowingStream<DictationEvent, Error> {
        if let session, !session.isStopped { throw MicrophoneError.alreadyRecording }
        let session = Session(recordingURL: recordingURL, recognition: SpeechRecognitionSession(engine: backend, local: localRecognizer, locale: locale))
        self.session = session
        Self.logger.notice("Starting on-device dictation; destination=\(recordingURL.path, privacy: .public)")

        do {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            try checkSession(session)
            guard granted else { throw MicrophoneError.microphoneDenied }
            let inputFormat = session.engine.inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw MicrophoneError.noAudioInput
            }
            let diagnostic = onDiagnostic
            let analysisFormat = try await session.recognition.start(
                inputFormat: inputFormat, input: session.analysis.stream, events: session.events.continuation,
                onDiagnostic: { await diagnostic?($0) },
                onFailure: { [weak self] error in self?.fail(error, session: session) }
            )
            try checkSession(session)

            let processor = try MicrophoneBufferProcessor(
                recordingURL: recordingURL, inputFormat: inputFormat, analysisFormat: analysisFormat
            )
            session.hasRecording = true
            session.processingTask = Task { [weak self] in
                do {
                    try await processor.run(
                        input: session.captured.stream,
                        analysis: session.analysis.continuation,
                        events: session.events.continuation
                    )
                } catch {
                    session.analysis.continuation.finish()
                    self?.fail(error, session: session)
                    throw error
                }
            }

            let capture = Self.makeCaptureCallback(into: session.captured.continuation) { [weak self] error in
                Task { @MainActor in self?.fail(error, session: session) }
            }
            session.engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: capture)
            session.hasTap = true
            session.engine.prepare()
            try session.engine.start()
            Self.logger.notice("Microphone stream started; sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")
            session.configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: session.engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.fail(MicrophoneError.audioInputChanged, session: session) }
            }
            session.events.continuation.yield(.transcript(.empty))
            return session.events.stream
        } catch {
            Self.logger.error("Dictation start failed: \(error.localizedDescription, privacy: .public)")
            if !session.cancelled {
                session.failure = error
                _ = try? await stop(session)
            }
            throw error
        }
    }

    func stop() async throws -> URL? {
        guard let session else { return nil }
        return try await stop(session)
    }

    func cancel() async throws {
        guard let session else { return }
        session.cancelled = true
        stopCapture(session)
        session.stopTask?.cancel()
        session.processingTask?.cancel()
        session.analysis.continuation.finish()
        await session.recognition.cancel()
        _ = try? await session.processingTask?.value
        _ = try? await session.stopTask?.value
        session.events.continuation.finish()
        session.isStopped = true
        if FileManager.default.fileExists(atPath: session.recordingURL.path) {
            try FileManager.default.removeItem(at: session.recordingURL)
        }
        if self.session === session { self.session = nil }
    }

    private func checkSession(_ session: Session) throws {
        try Task.checkCancellation()
        guard self.session === session, !session.cancelled, session.stopTask == nil else { throw CancellationError() }
    }

    private func fail(_ error: Error, session: Session) {
        guard !session.cancelled, !session.isStopped else { return }
        let failure = session.failure ?? error
        Self.logger.error("Dictation stream failed: \(failure.localizedDescription, privacy: .public)")
        session.failure = failure
        session.events.continuation.finish(throwing: failure)
        stopCapture(session)
    }

    private func stop(_ session: Session) async throws -> URL? {
        if let task = session.stopTask { return try await task.value }
        Self.logger.notice("Stopping microphone stream and finalizing recognition")
        stopCapture(session)
        let task = Task { @MainActor in
            do {
                try await session.processingTask?.value
                session.analysis.continuation.finish()
                if session.failure != nil || session.cancelled {
                    await session.recognition.cancel()
                } else {
                    try await session.recognition.finish()
                }
                if let failure = session.failure { throw failure }
                try Task.checkCancellation()
                session.events.continuation.yield(.level(0))
                session.events.continuation.finish()
                session.isStopped = true
                return session.hasRecording ? session.recordingURL : nil
            } catch {
                await session.recognition.cancel()
                session.events.continuation.finish(throwing: error)
                session.isStopped = true
                throw error
            }
        }
        session.stopTask = task
        return try await task.value
    }

    private func stopCapture(_ session: Session) {
        if let observer = session.configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            session.configurationObserver = nil
        }
        session.engine.stop()
        if session.hasTap {
            session.engine.inputNode.removeTap(onBus: 0)
            session.hasTap = false
        }
        session.captured.continuation.finish()
    }

    static func makeCaptureCallback(
        into captured: AsyncStream<AnalyzerInput>.Continuation,
        onError: @escaping @Sendable (Error) -> Void
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        // AVAudioNodeTapBlock lacks a Sendable annotation in the SDK. The
        // callback runs on AVAudioEngine's queue, never on this class's actor.
        { @Sendable buffer, _ in
            do {
                captured.yield(AnalyzerInput(buffer: try Self.copy(buffer)))
            } catch {
                onError(error)
            }
        }
    }

    /// AVAudioEngine owns/reuses tap memory; copy before leaving the callback.
    nonisolated private static func copy(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            throw MicrophoneError.cannotAllocateBuffer
        }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (source, destination) in zip(sourceBuffers, destinationBuffers) {
            memcpy(destination.mData!, source.mData!, Int(source.mDataByteSize))
        }
        return copy
    }

    @MainActor
    private final class Session {
        let recordingURL: URL
        let engine = AVAudioEngine()
        let events = AsyncThrowingStream<DictationEvent, Error>.makeStream()
        let captured = AsyncStream<AnalyzerInput>.makeStream()
        let analysis = AsyncStream<AnalyzerInput>.makeStream()
        let recognition: SpeechRecognitionSession
        var configurationObserver: NSObjectProtocol?
        var processingTask: Task<Void, Error>?
        var stopTask: Task<URL?, Error>?
        var hasTap = false
        var hasRecording = false
        var isStopped = false
        var cancelled = false
        var failure: Error?

        init(recordingURL: URL, recognition: SpeechRecognitionSession) {
            self.recordingURL = recordingURL; self.recognition = recognition
        }
    }
}

/// Results replace the same audio range, including provisional ranges that are
/// later consolidated into one finalized result.
struct RecognitionTranscript {
    private struct Segment {
        let range: CMTimeRange
        let text: String
        let isFinal: Bool
    }
    private var segments: [Segment] = []

    mutating func replace(range: CMTimeRange, text: String, isFinal: Bool) {
        segments.removeAll {
            CMTimeCompare($0.range.start, range.start) == 0 ||
                CMTimeRangeGetIntersection($0.range, otherRange: range).duration > .zero
        }
        segments.append(Segment(range: range, text: text, isFinal: isFinal))
        segments.sort { CMTimeCompare($0.range.start, $1.range.start) < 0 }
    }

    var snapshot: TranscriptSnapshot {
        let firstProvisional = segments.firstIndex { !$0.isFinal } ?? segments.endIndex
        return TranscriptSnapshot(
            committedText: segments[..<firstProvisional].map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
            partialText: segments[firstProvisional...].map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

actor MicrophoneBufferProcessor {
    private var file: AVAudioFile?
    private let recordingURL: URL
    private let recordingFormat: AVAudioFormat
    private let analysisFormat: AVAudioFormat
    private let recordingConverter: AVAudioConverter?
    private let analysisConverter: AVAudioConverter?

    init(recordingURL: URL, inputFormat: AVAudioFormat, analysisFormat: AVAudioFormat) throws {
        self.recordingURL = recordingURL
        let file = try AVAudioFile(forWriting: recordingURL, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        self.recordingFormat = file.processingFormat
        self.analysisFormat = analysisFormat
        recordingConverter = try Self.converter(from: inputFormat, to: file.processingFormat)
        analysisConverter = try Self.converter(from: inputFormat, to: analysisFormat)
    }

    func run(
        input: AsyncStream<AnalyzerInput>,
        analysis: AsyncStream<AnalyzerInput>.Continuation,
        events: AsyncThrowingStream<DictationEvent, Error>.Continuation
    ) async throws {
        defer {
            file = nil // Closing AVAudioFile finalizes its AAC container.
            analysis.finish()
        }
        var framesSinceMeter = 0
        for await input in input {
            try Task.checkCancellation()
            let buffer = input.buffer
            let recording = try convert(buffer, with: recordingConverter, to: recordingFormat)
            try file!.write(from: recording)
            let converted = try convert(buffer, with: analysisConverter, to: analysisFormat)
            if converted.frameLength > 0 { analysis.yield(AnalyzerInput(buffer: converted)) }
            framesSinceMeter += Int(buffer.frameLength)
            if framesSinceMeter >= Int(buffer.format.sampleRate / 10) {
                framesSinceMeter = 0
                events.yield(.level(Self.level(recording)))
                let attributes = try FileManager.default.attributesOfItem(atPath: recordingURL.path)
                events.yield(.fileSize((attributes[.size] as! NSNumber).int64Value))
            }
        }
        try flush(recordingConverter, format: recordingFormat) { try file!.write(from: $0) }
        try flush(analysisConverter, format: analysisFormat) { analysis.yield(AnalyzerInput(buffer: $0)) }
    }

    private static func converter(from input: AVAudioFormat, to output: AVAudioFormat) throws -> AVAudioConverter? {
        if input == output { return nil }
        guard let converter = AVAudioConverter(from: input, to: output) else { throw MicrophoneError.noCompatibleFormat }
        converter.downmix = true
        return converter
    }

    private func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter?, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter else { return input }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw MicrophoneError.cannotAllocateBuffer
        }
        let ownedInput = AnalyzerInput(buffer: input)
        let supplied = Mutex(false)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            let wasSupplied = supplied.withLock { supplied in
                let previous = supplied
                supplied = true
                return previous
            }
            if wasSupplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return ownedInput.buffer
        }
        if let error { throw error }
        if status == .error { throw MicrophoneError.audioConversionFailed }
        return output
    }

    private func flush(_ converter: AVAudioConverter?, format: AVAudioFormat, consume: (AVAudioPCMBuffer) throws -> Void) throws {
        guard let converter else { return }
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
                throw MicrophoneError.cannotAllocateBuffer
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let error { throw error }
            if status == .error { throw MicrophoneError.audioConversionFailed }
            if output.frameLength > 0 { try consume(output) }
            if status == .endOfStream || output.frameLength == 0 { return }
        }
    }

    private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return min(1, max(0, (20 * log10(max(rms, 0.00001)) + 50) / 50))
    }
}

private enum MicrophoneError: LocalizedError {
    case alreadyRecording
    case microphoneDenied
    case noAudioInput
    case audioInputChanged
    case noCompatibleFormat
    case cannotAllocateBuffer
    case audioConversionFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "A microphone dictation session is already running."
        case .microphoneDenied: "Microphone permission denied. Enable Chatty in System Settings → Privacy & Security → Microphone."
        case .noAudioInput: "The default microphone has no available audio input."
        case .audioInputChanged: "The audio input changed during dictation. The recording was stopped; start dictation again to use the new input."
        case .noCompatibleFormat: "Could not configure a compatible audio format for dictation."
        case .cannotAllocateBuffer: "Could not allocate an audio buffer for dictation."
        case .audioConversionFailed: "Could not convert microphone audio for dictation."
        }
    }
}
