import Foundation

/// A complete snapshot: provisional words replace the previous provisional words.
/// Recognition finality does not imply LLM cleanup has happened.
struct TranscriptSnapshot: Equatable, Sendable {
    var committedText: String
    var partialText: String

    static let empty = TranscriptSnapshot(committedText: "", partialText: "")

    var text: String {
        [committedText, partialText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum DictationEvent: Sendable {
    case transcript(TranscriptSnapshot)
    case level(Float)
    case fileSize(Int64)
}

@MainActor
protocol DictationInputService: AnyObject {
    /// Each start creates a new session and a fresh stream.
    func start(recordingURL: URL) async throws -> AsyncThrowingStream<DictationEvent, Error>

    /// Stop input, emit final results, then finish the stream. Return a saved
    /// recording for real audio, or nil for simulated input. On failure preserve
    /// captured audio; cancel explicitly discards it.
    func stop() async throws -> URL?

    /// End the stream, stop all work, and discard this session's recording.
    /// Must also work while start is awaiting permissions or model preparation.
    func cancel() async throws
}
