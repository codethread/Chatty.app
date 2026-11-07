import AppKit
import Testing
@testable import Chatty

@MainActor
struct TranscriptLayoutTests {
    @Test(arguments: [(1, "Four."), (3, "Two.\nThree.\nFour."), (8, "One.\nTwo.\nThree.\nFour.")])
    func selectsTheLastConfiguredLines(lines: Int, expected: String) {
        let text = "One.\nTwo.\nThree.\nFour."
        let start = TranscriptLayout.contextStart(in: text, lines: lines, width: TranscriptLayout.defaultWidth)
        #expect(String(text[String.Index(utf16Offset: start, in: text)...]) == expected)
    }

    @Test func countsWrappedLinesWithoutRequiringNewlines() {
        let sentence = "Sentence."
        let width = (sentence as NSString).size(withAttributes: [.font: TranscriptLayout.font]).width + 5
        let text = Array(repeating: sentence, count: 5).joined(separator: " ")
        let start = TranscriptLayout.contextStart(in: text, lines: 3, width: width)

        #expect(String(text[String.Index(utf16Offset: start, in: text)...]) == "Sentence. Sentence. Sentence.")
    }
}
