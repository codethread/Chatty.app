import Foundation
import Testing
@testable import Chatty

struct TranscriptCorrectionsTests {
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
        var document = TranscriptCorrections()
        document.update(TranscriptSnapshot(committedText: "A stable sentence. A stable", partialText: "unfinished phrase."))

        #expect(document.nextBatch(contextStart: 0)?.text == "A stable sentence.")
        #expect(document.tail == "A stable unfinished phrase.")
    }

    @Test func coalescesSpeechArrivingDuringCorrectionWithTheCorrectedPrefix() throws {
        var document = TranscriptCorrections()
        document.update(TranscriptSnapshot(committedText: "Um, use Vaselle. That's for", partialText: "sale"))
        let first = try #require(document.nextBatch(contextStart: 0))
        #expect(first.text == "Um, use Vaselle.")

        document.update(TranscriptSnapshot(committedText: "Um, use Vaselle. That's for sale. Versell. VER C E L. That correction was for the dictation.", partialText: "And now um"))
        #expect((document.text as NSString).substring(with: first.range) == first.text)
        let appliedFirst = document.apply("Use Vaselle.", to: first)
        #expect(appliedFirst)
        let next = try #require(document.nextBatch(contextStart: 0))
        #expect(next.text == "Use Vaselle. That's for sale. Versell. VER C E L. That correction was for the dictation.")

        document.update(TranscriptSnapshot(committedText: "Um, use Vaselle. That's for sale. Versell. VER C E L. That correction was for the dictation. And now um another thought.", partialText: "Still speaking"))
        #expect((document.text as NSString).substring(with: next.range) == next.text)
        let appliedNext = document.apply("Use VERCEL.", to: next)
        #expect(appliedNext)
        #expect(document.text == "Use VERCEL. And now um another thought. Still speaking")
        #expect(document.nextBatch(contextStart: 0)?.text == "Use VERCEL. And now um another thought.")
    }

    @Test func editingSubmittedSpeechRejectsLateCorrections() throws {
        var document = TranscriptCorrections()
        document.update(TranscriptSnapshot(committedText: "First sentence. Second sentence.", partialText: ""))
        let stale = try #require(document.nextBatch(contextStart: 0))

        document.update(TranscriptSnapshot(committedText: "Edited sentence. Second sentence.", partialText: ""))

        let applied = document.apply("Stale correction.", to: stale)
        #expect(!applied)
        #expect(document.text == "Edited sentence. Second sentence.")
    }

    @Test func roundsContextBackToAFullSentenceAndPreservesOlderText() throws {
        var document = TranscriptCorrections()
        document.update(TranscriptSnapshot(committedText: "Um, an older thought. Um, use Vaselle.", partialText: ""))
        let first = try #require(document.nextBatch(contextStart: 0))
        document.apply("An older 👩🏽‍💻 thought.\n\nUse Vaselle.", to: first)
        document.update(TranscriptSnapshot(committedText: "Um, an older thought. Um, use Vaselle. That's for sale. VER C E L. That correction was for the dictation.", partialText: ""))
        let contextStart = try #require(document.stableText.range(of: "Vaselle")).lowerBound.utf16Offset(in: document.stableText)
        let next = try #require(document.nextBatch(contextStart: contextStart))

        #expect(next.text == "Use Vaselle. That's for sale. VER C E L. That correction was for the dictation.")
        #expect((document.text as NSString).substring(with: next.range) == next.text)
        document.apply("Use VERCEL.", to: next)
        #expect(document.text == "An older 👩🏽‍💻 thought.\n\nUse VERCEL.")
        #expect(document.nextBatch(contextStart: 0) == nil)
    }

    @Test func aShortContextWindowStillIncludesAllPendingSpeech() throws {
        var document = TranscriptCorrections()
        document.update(TranscriptSnapshot(committedText: "Um, hello.", partialText: ""))
        document.apply("Hello.", to: try #require(document.nextBatch(contextStart: 0)))
        document.update(TranscriptSnapshot(committedText: "Um, hello. First new sentence. Second new sentence. Third new sentence.", partialText: ""))
        let contextStart = try #require(document.stableText.range(of: "Third")).lowerBound.utf16Offset(in: document.stableText)
        let next = try #require(document.nextBatch(contextStart: contextStart))

        #expect(next.text == "First new sentence. Second new sentence. Third new sentence.")
        document.apply("Three new sentences.", to: next)
        #expect(document.text == "Hello. Three new sentences.")
    }

    @Test func deletingAWholePassageConsumesItsSourceAndDoesNotRestoreItWhenSpeechContinues() throws {
        var document = TranscriptCorrections()
        let first = "Sentence number one. Sentence number two. Sentence number three."
        document.update(.init(committedText: first, partialText: ""))
        document.apply(first, to: try #require(document.nextBatch(contextStart: 0)))
        let source = first + " Okay for the tape, please delete all sentences."
        document.update(.init(committedText: source, partialText: ""))
        let deletion = try #require(document.nextBatch(contextStart: 0))
        #expect(deletion.text == source)
        let applied = document.apply("", to: deletion)
        #expect(applied)
        #expect(document.text.isEmpty)
        #expect(document.pendingText.isEmpty)
        #expect(document.nextBatch(contextStart: 0) == nil)

        document.update(.init(committedText: source + " A fresh start.", partialText: "live tail"))
        #expect(document.text == "A fresh start. live tail")
        #expect(document.nextBatch(contextStart: 0)?.text == "A fresh start.")
    }

    @Test func deletingTheEditablePassagePreservesOlderTextWithoutATrailingSeparator() throws {
        var document = TranscriptCorrections()
        let first = "Older text. First editable sentence. Second editable sentence."
        document.update(.init(committedText: first, partialText: ""))
        document.apply(first, to: try #require(document.nextBatch(contextStart: 0)))
        document.update(.init(committedText: first + " For the tape, delete those sentences.", partialText: ""))
        let start = try #require(first.range(of: "First")).lowerBound.utf16Offset(in: first)
        let deletion = try #require(document.nextBatch(contextStart: start))
        #expect(deletion.text == "First editable sentence. Second editable sentence. For the tape, delete those sentences.")
        document.apply("", to: deletion)
        #expect(document.text == "Older text.")
    }

    @Test func stoppingIncludesTheLastFragmentWithRecentCorrectedText() throws {
        var document = TranscriptCorrections()
        let snapshot = TranscriptSnapshot(committedText: "Um, hello.", partialText: "and the last bit")
        document.update(snapshot)
        document.apply("Hello.", to: try #require(document.nextBatch(contextStart: 0)))
        #expect(document.nextBatch(contextStart: 0) == nil)

        document.update(snapshot, finalize: true)

        #expect(document.correctedText == "Hello.")
        #expect(document.nextBatch(contextStart: 0)?.text == "Hello. and the last bit")
        #expect(document.tail.isEmpty)
    }

    @Test func editingCorrectedSourceInvalidatesItsTextAndPendingResponses() throws {
        var document = TranscriptCorrections()
        document.update(TranscriptSnapshot(committedText: "Um, hello.", partialText: ""))
        document.apply("Hello.", to: try #require(document.nextBatch(contextStart: 0)))
        document.update(TranscriptSnapshot(committedText: "Um, hello. Next sentence.", partialText: ""))
        let stale = try #require(document.nextBatch(contextStart: 0))

        document.update(TranscriptSnapshot(committedText: "Edited greeting. Next sentence.", partialText: ""))
        document.update(TranscriptSnapshot(committedText: "Um, hello. Next sentence.", partialText: ""))

        let applied = document.apply("Stale response.", to: stale)
        #expect(!applied)
        #expect(document.correctedText.isEmpty)
        #expect(document.nextBatch(contextStart: 0)?.text == "Um, hello. Next sentence.")
    }
}
