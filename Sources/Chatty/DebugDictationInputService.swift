#if CHATTY_DEBUG_PANEL
import Foundation

@MainActor
final class DebugDictationInputService: DictationInputService {
    enum Source: Int, CaseIterable {
        case injected, nemotron, apple, typed, audioFile, configured
        var title: String {
            switch self {
            case .injected: "Injected transcript · synthetic recording"
            case .nemotron: "Microphone · Nemotron 600M · 560 ms"
            case .apple: "Microphone · Apple SpeechAnalyzer"
            case .typed: "Typed text"
            case .audioFile: "Audio file · configured speech engine"
            case .configured: "Microphone · configured speech engine"
            }
        }
    }

    var source: Source = .injected
    let injected = ScriptedDictationInputService()
    let typed = DebugTextInputService()
    let local: MicrophoneDictationService
    let audioFile: DebugAudioFileInputService
    private let apple = MicrophoneDictationService()
    let configured: MicrophoneDictationService
    private var active: (any DictationInputService)?

    init(recognizer: LocalSpeechRecognizer) {
        configured = MicrophoneDictationService(localRecognizer: recognizer)
        local = MicrophoneDictationService(backend: .nemotron, localRecognizer: recognizer)
        audioFile = DebugAudioFileInputService(recognizer: recognizer)
    }

    func setEngine(_ engine: SpeechRecognitionEngine) {
        configured.backend = engine
        audioFile.backend = engine
    }

    func start(recordingURL: URL) async throws -> AsyncThrowingStream<DictationEvent, Error> {
        let service: any DictationInputService
        switch source {
        case .injected: service = injected
        case .nemotron: service = local
        case .apple: service = apple
        case .typed: service = typed
        case .audioFile: service = audioFile
        case .configured: service = configured
        }
        active = service
        return try await service.start(recordingURL: recordingURL)
    }

    func stop() async throws -> URL? { try await active?.stop() }

    func cancel() async throws {
        try await active?.cancel()
        active = nil
    }
}
#endif
