#if CHATTY_DEBUG_PANEL
import AVFoundation
import Darwin
import Foundation
import FluidAudio
import Speech

/// File audio follows the same recognizer as the microphone, in 80 ms packets.
/// This deliberately excludes microphone hardware, UI rendering and LLM cleanup.
@MainActor
enum DebugASRBenchmark {
    private static var output = FileHandle.standardOutput
    nonisolated static let help = """
    Usage: Chatty --benchmark-asr prepare
           Chatty --benchmark-asr <nemotron|apple> <audio-file> [--realtime]
           Chatty --benchmark-asr parakeet <audio-file>
    Emits JSON lines for changed transcripts and a timing summary. --realtime
    paces 80 ms packets against a clock; otherwise measures inference throughput.
    prepare downloads/loads the Nemotron 600M 560 ms model into the local cache.
    Audio and transcripts remain on this Mac. No cleanup API is called.
    """

    static func run(_ arguments: [String]) async throws {
        if arguments == ["--help"] { print(help); return }
        // Core ML can write native diagnostics to stdout. Keep JSON on its own
        // descriptor and send library output to stderr for this benchmark process.
        output = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        guard let engine = arguments.first, ["prepare", "nemotron", "apple", "parakeet"].contains(engine) else {
            throw BenchmarkError.arguments
        }
        if engine == "prepare" {
            guard arguments.count == 1 else { throw BenchmarkError.arguments }
        } else {
            guard arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--realtime") else {
                throw BenchmarkError.arguments
            }
        }
        if engine == "parakeet" {
            guard arguments.count == 2 else { throw BenchmarkError.arguments }
            try await runParakeet(URL(fileURLWithPath: arguments[1]))
            return
        }
        let recognizer = LocalSpeechRecognizer()
        let loadStart = ContinuousClock.now
        if engine != "apple" { try await recognizer.prepare() }
        let loadSeconds = seconds(loadStart.duration(to: .now))
        if engine == "prepare" {
            emit(["type": "ready", "model": "nemotron-600m-560ms", "loadSeconds": loadSeconds])
            return
        }
        let url = URL(fileURLWithPath: arguments[1])
        let realtime = arguments.count == 3
        // SpeechAnalyzer requires signed Int16; Nemotron consumes Float32.
        let commonFormat: AVAudioCommonFormat = engine == "apple" ? .pcmFormatInt16 : .pcmFormatFloat32
        let file = try AVAudioFile(forReading: url, commonFormat: commonFormat, interleaved: false)
        if engine == "apple", file.processingFormat.sampleRate != 16_000 || file.processingFormat.channelCount != 1 {
            throw BenchmarkError.appleAudioFormat
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let captured = AsyncStream<AnalyzerInput>.makeStream()
        let events = AsyncThrowingStream<DictationEvent, Error>.makeStream()
        let start = ContinuousClock.now
        let feeder = Task.detached {
            try await DebugAudioReplay.feed(url, into: captured.continuation, realtime: realtime,
                                           start: start, commonFormat: commonFormat)
        }
        let recognition = Task {
            do {
                if engine == "nemotron" {
                    try await recognizer.run(input: captured.stream, events: events.continuation)
                } else {
                    try await runApple(input: captured.stream, format: file.processingFormat, events: events.continuation)
                }
                events.continuation.finish()
            } catch {
                events.continuation.finish(throwing: error)
                throw error
            }
        }
        var text = ""
        var updates: [Double] = []
        do {
            for try await event in events.stream {
                if case .transcript(let snapshot) = event, snapshot.text != text {
                    text = snapshot.text
                    let elapsed = seconds(start.duration(to: .now))
                    updates.append(elapsed)
                    emit(["type": "transcript", "seconds": elapsed, "text": text])
                }
            }
            try await feeder.value
            try await recognition.value
        } catch {
            feeder.cancel()
            recognition.cancel()
            _ = try? await feeder.value
            _ = try? await recognition.value
            throw error
        }
        let elapsed = seconds(start.duration(to: .now))
        let gaps = zip(updates.dropFirst(), updates).map(-).sorted()
        var summary: [String: Any] = [
            "type": "summary", "engine": engine, "realtime": realtime,
            "audioSeconds": duration, "loadSeconds": loadSeconds, "elapsedSeconds": elapsed,
            "realtimeFactor": elapsed / duration, "updates": updates.count, "text": text
        ]
        if let first = updates.first { summary["firstTextSeconds"] = first }
        if !gaps.isEmpty { summary["medianUpdateGapSeconds"] = gaps[gaps.count / 2] }
        if realtime { summary["tailSeconds"] = max(0, elapsed - duration) }
        emit(summary)
    }

    private static func runApple(
        input: AsyncStream<AnalyzerInput>, format: AVAudioFormat,
        events: AsyncThrowingStream<DictationEvent, Error>.Continuation
    ) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-GB")) else {
            throw BenchmarkError.appleUnavailable
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let results = Task {
            var transcript = RecognitionTranscript()
            for try await result in transcriber.results {
                transcript.replace(range: result.range, text: String(result.text.characters), isFinal: result.isFinal)
                events.yield(.transcript(transcript.snapshot))
            }
        }
        do {
            try await analyzer.start(inputSequence: input)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await results.value
        } catch {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            _ = try? await results.value
            throw error
        }
    }

    private static func runParakeet(_ url: URL) async throws {
        let loadStart = ContinuousClock.now
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let manager = AsrManager()
        try await manager.loadModels(models)
        let loadSeconds = seconds(loadStart.duration(to: .now))
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let start = ContinuousClock.now
        let result = try await manager.transcribe(url, decoderState: &state)
        emit(["type": "summary", "engine": "parakeet-v2-batch", "loadSeconds": loadSeconds,
              "elapsedSeconds": seconds(start.duration(to: .now)), "text": result.text])
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        output.write(data + Data([0x0A]))
    }

    private enum BenchmarkError: LocalizedError {
        case arguments, appleUnavailable, appleAudioFormat
        var errorDescription: String? {
            switch self {
            case .arguments: DebugASRBenchmark.help
            case .appleUnavailable: "Apple English speech recognition is unavailable."
            case .appleAudioFormat: "The Apple packet benchmark requires 16 kHz mono audio. Convert the input with ffmpeg -ar 16000 -ac 1."
            }
        }
    }
}
#endif
