import Foundation

/// A pause closes one utterance while the recording and its transcript continue.
struct LocalSpeechTranscript {
    private var completedText = ""
    private var currentText = ""

    mutating func update(_ text: String) {
        currentText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func finishUtterance(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { completedText = join(completedText, Self.endingSentence(text)) }
        currentText = ""
    }

    var snapshot: TranscriptSnapshot {
        let split = SentenceSplit.split(currentText)
        return TranscriptSnapshot(
            committedText: join(completedText, split.sentences.joined(separator: " ")),
            partialText: split.remainder
        )
    }

    private func join(_ prefix: String, _ suffix: String) -> String {
        [prefix, suffix].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func endingSentence(_ text: String) -> String {
        let closers = "\"'”’»)]}"
        guard let last = text.lastIndex(where: { !closers.contains($0) }) else { return text }
        if ".!?…。！？".contains(text[last]) { return text }
        let end = text.index(after: last)
        let body = ",;:".contains(text[last]) ? text[..<last] : text[..<end]
        return body + "." + text[end...]
    }
}

/// Quiet-office endpointing, measured in audio time rather than timer callbacks.
struct SpeechPauseDetector {
    private var heardSpeech = false
    private var silentSeconds = 0.0

    mutating func consume(rms: Float, seconds: Double) -> Bool {
        if rms >= 0.00316 { // Approximately -50 dBFS.
            heardSpeech = true
            silentSeconds = 0
        } else if heardSpeech {
            silentSeconds += seconds
            if silentSeconds >= 1 {
                heardSpeech = false
                silentSeconds = 0
                return true
            }
        }
        return false
    }
}
