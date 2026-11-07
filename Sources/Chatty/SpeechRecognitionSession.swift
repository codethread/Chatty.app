import AVFoundation
import Foundation
import Speech

/// The same recognition lifecycle receives converted microphone or replay audio.
@MainActor
final class SpeechRecognitionSession {
    let engine: SpeechRecognitionEngine
    private let local: LocalSpeechRecognizer
    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var installation: AssetInstallationRequest?
    private var results: Task<Void, Error>?
    private var cancelled = false

    init(engine: SpeechRecognitionEngine, local: LocalSpeechRecognizer, locale: Locale = .current) {
        self.engine = engine; self.local = local; self.locale = locale
    }

    func start(inputFormat: AVAudioFormat, input: AsyncStream<AnalyzerInput>,
               events: AsyncThrowingStream<DictationEvent, Error>.Continuation,
               onDiagnostic: @escaping @Sendable (String) async -> Void = { _ in },
               onFailure: @escaping @MainActor (Error) -> Void) async throws -> AVAudioFormat {
        switch engine {
        case .nemotron:
            try await local.prepare()
            try checkCancellation()
            results = Task {
                do { try await local.run(input: input, events: events, onDiagnostic: onDiagnostic) }
                catch { onFailure(error); throw error }
            }
            return AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        case .apple:
            guard SpeechTranscriber.isAvailable else { throw RecognitionError.unavailable }
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw RecognitionError.unsupportedLocale(locale.identifier)
            }
            try checkCancellation()
            let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
            installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
            try checkCancellation()
            if let installation { try await installation.downloadAndInstall() }
            try checkCancellation()
            installation = nil
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: inputFormat) else {
                throw RecognitionError.noCompatibleFormat
            }
            try await analyzer.prepareToAnalyze(in: format)
            try checkCancellation()
            results = Task {
                do {
                    var transcript = RecognitionTranscript()
                    for try await result in transcriber.results {
                        try Task.checkCancellation()
                        transcript.replace(range: result.range, text: String(result.text.characters), isFinal: result.isFinal)
                        events.yield(.transcript(transcript.snapshot))
                    }
                } catch { onFailure(error); throw error }
            }
            try await analyzer.start(inputSequence: input)
            try checkCancellation()
            return format
        }
    }

    func finish() async throws {
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        try await results?.value
    }

    func cancel() async {
        cancelled = true
        installation?.progress.cancel()
        results?.cancel()
        await analyzer?.cancelAndFinishNow()
        _ = try? await results?.value
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }
}

private enum RecognitionError: LocalizedError {
    case unavailable, unsupportedLocale(String), noCompatibleFormat
    var errorDescription: String? {
        switch self {
        case .unavailable: "On-device Apple speech recognition is unavailable on this Mac."
        case .unsupportedLocale(let locale): "Apple speech recognition does not support \(locale)."
        case .noCompatibleFormat: "Could not configure a compatible speech recognition audio format."
        }
    }
}
