import Foundation
import NaturalLanguage

struct SentenceSplit: Equatable {
    var sentences: [String]
    var remainder: String

    static func split(_ text: String, finalize: Bool = false) -> SentenceSplit {
        var sentences: [String] = []
        var start = text.startIndex
        var cursor = start
        let terminators = ".!?…。！？"
        let closers = "\"'”’»)]}"
        while cursor < text.endIndex {
            guard terminators.contains(text[cursor]) else {
                cursor = text.index(after: cursor)
                continue
            }
            var end = text.index(after: cursor)
            while end < text.endIndex, terminators.contains(text[end]) || closers.contains(text[end]) {
                end = text.index(after: end)
            }
            let strongEnding = text[cursor..<end].contains { $0 != "." && terminators.contains($0) }
            if strongEnding || end == text.endIndex || text[end].isWhitespace {
                let sentence = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                var isComplete = strongEnding
                if !isComplete {
                    // Give the tokenizer a capitalized next word to distinguish
                    // full stops from abbreviations without requiring the user
                    // to capitalize their next sentence.
                    let probe = sentence + " A"
                    let tokenizer = NLTokenizer(unit: .sentence)
                    tokenizer.string = probe
                    isComplete = tokenizer.tokens(for: probe.startIndex..<probe.endIndex).count > 1
                }
                if isComplete {
                    sentences.append(sentence)
                    start = end
                }
            }
            cursor = end
        }
        let remainder = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if finalize, !remainder.isEmpty { sentences.append(remainder) }
        return SentenceSplit(sentences: sentences, remainder: finalize ? "" : remainder)
    }
}

struct CorrectedSentence: Equatable, Identifiable, Sendable {
    let id: UUID
    let source: String
    var correction: String?

    var text: String { correction ?? source }
}

/// Keeps unchanged prefix corrections while invalidating edited text and every
/// sentence after it. Late results can only apply to their original sentence ID.
struct SentenceCorrections: Equatable, Sendable {
    private(set) var sentences: [CorrectedSentence] = []
    private(set) var tail = ""

    var text: String {
        (sentences.map(\.text) + [tail]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    mutating func update(_ snapshot: TranscriptSnapshot, finalize: Bool = false) {
        var remaining = (finalize ? snapshot.text : snapshot.committedText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var retained: [CorrectedSentence] = []
        // Preserve corrections only while their original source still matches
        // at the same position in the recognized text.
        for sentence in sentences {
            guard remaining.hasPrefix(sentence.source) else { break }
            let end = remaining.index(remaining.startIndex, offsetBy: sentence.source.count)
            guard end == remaining.endIndex || remaining[end].isWhitespace else { break }
            retained.append(sentence)
            remaining = String(remaining[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let split = SentenceSplit.split(remaining, finalize: finalize)
        sentences = retained + split.sentences.map {
            CorrectedSentence(id: UUID(), source: $0)
        }
        tail = [split.remainder, finalize ? "" : snapshot.partialText]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    @discardableResult
    mutating func apply(_ correction: String, to id: UUID) -> Bool {
        guard let index = sentences.firstIndex(where: { $0.id == id }) else { return false }
        sentences[index].correction = correction
        return true
    }
}
