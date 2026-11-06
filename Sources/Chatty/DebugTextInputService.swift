#if CHATTY_DEBUG_PANEL
import Foundation

@MainActor
final class DebugTextInputService: DictationInputService {
    private var continuation: AsyncThrowingStream<DictationEvent, Error>.Continuation?
    private var replayTask: Task<Void, Never>?
    private var text = ""

    func start(recordingURL: URL) async throws -> AsyncThrowingStream<DictationEvent, Error> {
        stopReplay()
        continuation?.finish()
        text = ""
        let (stream, continuation) = AsyncThrowingStream<DictationEvent, Error>.makeStream()
        self.continuation = continuation
        continuation.yield(.transcript(.empty))
        continuation.yield(.level(0))
        return stream
    }

    func updateText(_ text: String) {
        stopReplay()
        self.text = text
        emitText()
        continuation?.yield(.level(text.isEmpty ? 0 : 1))
    }

    /// Replay prefixes of the original string, preserving punctuation, Unicode,
    /// and whitespace instead of rebuilding the text from split words.
    func replay(_ text: String) {
        stopReplay()
        self.text = ""
        emitText()
        guard continuation != nil else { return }

        var wordEnds: [String.Index] = []
        var wasWhitespace = true
        for index in text.indices {
            let isWhitespace = text[index].isWhitespace
            if isWhitespace && !wasWhitespace { wordEnds.append(index) }
            wasWhitespace = isWhitespace
        }
        wordEnds.append(text.endIndex)

        replayTask = Task { [weak self] in
            for end in wordEnds {
                guard !Task.isCancelled, let self else { return }
                self.text = String(text[..<end])
                self.emitText()
                self.continuation?.yield(.level(1))
                do {
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    return
                }
            }
            self?.continuation?.yield(.level(0))
            self?.replayTask = nil
        }
    }

    func stop() async throws -> URL? {
        stopReplay()
        continuation?.yield(.transcript(TranscriptSnapshot(committedText: text, partialText: "")))
        continuation?.yield(.level(0))
        continuation?.finish()
        continuation = nil
        return nil
    }

    func cancel() async throws {
        stopReplay()
        continuation?.finish()
        continuation = nil
        text = ""
    }

    private func emitText() {
        let split = SentenceSplit.split(text)
        continuation?.yield(.transcript(TranscriptSnapshot(
            committedText: split.sentences.joined(separator: " "), partialText: split.remainder
        )))
    }

    private func stopReplay() {
        replayTask?.cancel()
        replayTask = nil
    }
}
#endif
