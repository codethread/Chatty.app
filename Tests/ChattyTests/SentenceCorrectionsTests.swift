import Testing
@testable import Chatty

struct SentenceCorrectionsTests {
    @Test(arguments: [
        ("Hello. A new thought", ["Hello."], "A new thought"),
        ("um first sentence. uh second sentence. unfinished thought", ["um first sentence.", "uh second sentence."], "unfinished thought"),
        ("Dr. Smith arrived. The value is 3.14. Next", ["Dr. Smith arrived.", "The value is 3.14."], "Next"),
        ("He said, \"yes!\" What next?", ["He said, \"yes!\"", "What next?"], ""),
        ("まだ途中", [], "まだ途中"),
        ("こんにちは。次の言葉", ["こんにちは。"], "次の言葉")
    ])
    func splitsCompleteSentencesWithoutSubmittingTheUnfinishedTail(text: String, sentences: [String], tail: String) {
        #expect(SentenceSplit.split(text) == SentenceSplit(sentences: sentences, remainder: tail))
    }

    @Test func stoppingFlushesTheUnpunctuatedTail() {
        #expect(SentenceSplit.split("One sentence. Still speaking", finalize: true)
            == SentenceSplit(sentences: ["One sentence.", "Still speaking"], remainder: ""))
    }

    @Test func provisionalSpeechIsDisplayedWithoutBeingSentForCorrection() {
        var document = SentenceCorrections()
        document.update(TranscriptSnapshot(committedText: "A stable sentence. A stable", partialText: "unfinished phrase."))

        #expect(document.sentences.map(\.source) == ["A stable sentence."])
        #expect(document.tail == "A stable unfinished phrase.")
    }

    @Test func addingSpeechPreservesExistingCorrectionsAndTheirIdentity() {
        var document = SentenceCorrections()
        document.update(TranscriptSnapshot(committedText: "Um, hello. Next", partialText: ""))
        let firstID = document.sentences[0].id
        document.apply("Hello.", to: firstID)

        document.update(TranscriptSnapshot(committedText: "Um, hello. Next sentence.", partialText: "More words"))

        #expect(document.sentences[0].id == firstID)
        #expect(document.sentences[0].correction == "Hello.")
        #expect(document.sentences[1].correction == nil)
        #expect(document.text == "Hello. Next sentence. More words")
    }

    @Test func editingASentenceInvalidatesItAndRejectsLateCorrections() {
        var document = SentenceCorrections()
        document.update(TranscriptSnapshot(committedText: "First sentence. Second sentence.", partialText: ""))
        let staleID = document.sentences[0].id
        let oldSecondID = document.sentences[1].id
        document.apply("FIRST SENTENCE.", to: staleID)

        document.update(TranscriptSnapshot(committedText: "Edited sentence. Second sentence.", partialText: ""))

        let applied = document.apply("Stale correction.", to: staleID)
        #expect(!applied)
        #expect(document.sentences[1].id != oldSecondID)
        #expect(document.text == "Edited sentence. Second sentence.")
    }

    @Test func stoppingPreservesCorrectedPrefixAndQueuesOnlyTheLastFragment() throws {
        var document = SentenceCorrections()
        let snapshot = TranscriptSnapshot(committedText: "Um, hello.", partialText: "and the last bit")
        document.update(snapshot)
        let firstID = document.sentences[0].id
        document.apply("Hello.", to: firstID)

        document.update(snapshot, finalize: true)

        try #require(document.sentences.count == 2)
        #expect(document.sentences[0].id == firstID)
        #expect(document.sentences[0].correction == "Hello.")
        #expect(document.sentences[1].source == "and the last bit")
        #expect(document.tail.isEmpty)
    }
}
