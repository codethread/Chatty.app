import Testing
@testable import Chatty

struct LocalSpeechTranscriptTests {
    @Test func pauseCommitsAFullStopAndTheNextUtteranceContinuesTheTranscript() {
        var transcript = LocalSpeechTranscript()
        transcript.update("The first statement")
        #expect(transcript.snapshot == TranscriptSnapshot(committedText: "", partialText: "The first statement"))

        transcript.finishUtterance("The first statement")
        #expect(transcript.snapshot == TranscriptSnapshot(committedText: "The first statement.", partialText: ""))

        transcript.update("Another top")
        transcript.update("Another topic")
        #expect(transcript.snapshot == TranscriptSnapshot(committedText: "The first statement.", partialText: "Another topic"))

        transcript.finishUtterance("Another topic")
        #expect(transcript.snapshot.text == "The first statement. Another topic.")
    }

    @Test(arguments: [
        ("Already finished.", "Already finished."),
        ("A question?", "A question?"),
        ("An exclamation!", "An exclamation!"),
        ("A pause…", "A pause…"),
        ("He said “hello”", "He said “hello.”"),
        ("He asked “why?”", "He asked “why?”"),
        ("An unfinished clause,", "An unfinished clause."),
        ("  A statement  ", "A statement.")
    ])
    func endsStatementsWithoutDuplicatingPunctuation(input: String, expected: String) {
        var transcript = LocalSpeechTranscript()
        transcript.finishUtterance(input)
        #expect(transcript.snapshot == TranscriptSnapshot(committedText: expected, partialText: ""))
    }

    @Test func flushUsesTheLastDecodedWordsAndDoesNotDuplicateAnEarlierSentence() {
        var transcript = LocalSpeechTranscript()
        transcript.update("Already done. The last wor")
        transcript.finishUtterance("Already done. The last word")
        transcript.finishUtterance("")
        #expect(transcript.snapshot.text == "Already done. The last word.")
    }
}

struct SpeechPauseDetectorTests {
    @Test func oneSecondOfQuietAfterSpeechEndsAnUtteranceOnce() {
        var detector = SpeechPauseDetector()
        let endpoints = [
            detector.consume(rms: 0.03, seconds: 0.25),
            detector.consume(rms: 0.0001, seconds: 0.25),
            detector.consume(rms: 0.0001, seconds: 0.25),
            detector.consume(rms: 0.0001, seconds: 0.25),
            detector.consume(rms: 0.0001, seconds: 0.25),
            detector.consume(rms: 0.0001, seconds: 3),
            detector.consume(rms: 0.03, seconds: 0.25),
            detector.consume(rms: 0.0001, seconds: 1)
        ]
        #expect(endpoints == [false, false, false, false, true, false, false, true])
    }

    @Test func shortPausesDoNotAccumulateAcrossSpeech() {
        var detector = SpeechPauseDetector()
        let endpoints = [
            detector.consume(rms: 0.03, seconds: 0.25),
            detector.consume(rms: 0.0001, seconds: 0.75),
            detector.consume(rms: 0.03, seconds: 0.25),
            detector.consume(rms: 0.0001, seconds: 0.75)
        ]
        #expect(endpoints == [false, false, false, false])
    }

    @Test func silenceAloneDoesNotCreateUtterances() {
        var detector = SpeechPauseDetector()
        let endpoint = detector.consume(rms: 0, seconds: 5)
        #expect(!endpoint)
    }
}
