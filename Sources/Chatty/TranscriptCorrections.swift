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

struct CorrectionBatch: Equatable, Sendable {
    let source: String
    let preservedText: String
    let text: String
    fileprivate let revision: UUID

    var range: NSRange {
        NSRange(location: preservedText.utf16.count, length: text.utf16.count)
    }
}

/// Tracks raw recognition independently of cleanup, whose sentence boundaries
/// and length can change. Each batch replaces only its submitted text window.
struct TranscriptCorrections: Equatable, Sendable {
    private var correctedSource = ""
    private var stableSource = ""
    private var revision = UUID()
    private(set) var correctedText = ""
    private(set) var tail = ""

    var pendingText: String {
        String(stableSource.dropFirst(correctedSource.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var stableText: String { Self.join(correctedText, pendingText) }
    var text: String { Self.join(stableText, tail) }

    mutating func update(_ snapshot: TranscriptSnapshot, finalize: Bool = false) {
        let split = SentenceSplit.split(finalize ? snapshot.text : snapshot.committedText, finalize: finalize)
        stableSource = split.sentences.joined(separator: " ")
        if !hasSourcePrefix(correctedSource) {
            correctedSource = ""
            correctedText = ""
            revision = UUID()
        }
        tail = Self.join(split.remainder, finalize ? "" : snapshot.partialText)
    }

    /// The line window may reach into corrected text, but never excludes pending
    /// speech. Round its start back to a complete corrected sentence.
    func nextBatch(contextStart: Int) -> CorrectionBatch? {
        guard !pendingText.isEmpty else { return nil }
        var start = correctedText.startIndex
        var cursor = start
        for sentence in SentenceSplit.split(correctedText, finalize: true).sentences {
            while cursor < correctedText.endIndex, correctedText[cursor].isWhitespace {
                cursor = correctedText.index(after: cursor)
            }
            if cursor.utf16Offset(in: correctedText) > contextStart { break }
            start = cursor
            cursor = correctedText.index(cursor, offsetBy: sentence.count)
        }
        if contextStart >= correctedText.utf16.count { start = correctedText.endIndex }
        let preservedText = String(correctedText[..<start])
        return CorrectionBatch(
            source: stableSource,
            preservedText: start == correctedText.endIndex && !preservedText.isEmpty ? preservedText + " " : preservedText,
            text: Self.join(String(correctedText[start...]), pendingText),
            revision: revision
        )
    }

    func contains(_ batch: CorrectionBatch) -> Bool {
        batch.revision == revision && hasSourcePrefix(batch.source)
    }

    @discardableResult
    mutating func apply(_ correction: String, to batch: CorrectionBatch) -> Bool {
        guard contains(batch) else { return false }
        correctedSource = batch.source
        correctedText = batch.preservedText + correction
        return true
    }

    private func hasSourcePrefix(_ prefix: String) -> Bool {
        guard stableSource.hasPrefix(prefix) else { return false }
        let end = stableSource.index(stableSource.startIndex, offsetBy: prefix.count)
        return prefix.isEmpty || end == stableSource.endIndex || stableSource[end].isWhitespace
    }

    private static func join(_ first: String, _ second: String) -> String {
        [first, second].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
