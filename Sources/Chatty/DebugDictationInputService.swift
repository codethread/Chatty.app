#if CHATTY_DEBUG_PANEL
import Foundation

@MainActor
final class DebugDictationInputService: DictationInputService {
    enum Source: Int, CaseIterable {
        case injected, nemotron, apple, typed, audioFile
        var title: String {
            switch self {
            case .injected: "Injected transcript · synthetic recording"
            case .nemotron: "Microphone · Nemotron 600M · 560 ms"
            case .apple: "Microphone · Apple SpeechAnalyzer"
            case .typed: "Typed text"
            case .audioFile: "Audio file · Nemotron · real time"
            }
        }
    }

    var source: Source = .injected
    let injected = ScriptedDictationInputService()
    let typed = DebugTextInputService()
    let local: MicrophoneDictationService
    let audioFile: DebugAudioFileInputService
    private let apple = MicrophoneDictationService()
    private var active: (any DictationInputService)?

    init() {
        let recognizer = LocalSpeechRecognizer()
        local = MicrophoneDictationService(backend: .nemotron, localRecognizer: recognizer)
        audioFile = DebugAudioFileInputService(recognizer: recognizer)
    }

    func start(recordingURL: URL) async throws -> AsyncThrowingStream<DictationEvent, Error> {
        let service: any DictationInputService
        switch source {
        case .injected: service = injected
        case .nemotron: service = local
        case .apple: service = apple
        case .typed: service = typed
        case .audioFile: service = audioFile
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
