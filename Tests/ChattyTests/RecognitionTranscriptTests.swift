import CoreMedia
import Testing
@testable import Chatty

struct RecognitionTranscriptTests {
    @Test func provisionalResultReplacesTheSameAudioRange() {
        var transcript = RecognitionTranscript()
        transcript.replace(range: range(start: 0, duration: 2), text: "Hello ther", isFinal: false)
        transcript.replace(range: range(start: 0, duration: 2), text: "Hello there.", isFinal: false)

        #expect(transcript.snapshot == TranscriptSnapshot(committedText: "", partialText: "Hello there."))
    }

    @Test func finalizedRangeConsolidatesOverlappingProvisionalResults() {
        var transcript = RecognitionTranscript()
        transcript.replace(range: range(start: 0, duration: 1), text: "Hello. ", isFinal: true)
        transcript.replace(range: range(start: 1, duration: 1), text: "This ", isFinal: false)
        transcript.replace(range: range(start: 2, duration: 1), text: "works", isFinal: false)

        transcript.replace(range: range(start: 1, duration: 2), text: "This works.", isFinal: true)

        #expect(transcript.snapshot == TranscriptSnapshot(committedText: "Hello. This works.", partialText: ""))
    }

    @Test func laterFinalResultStaysInOrderUntilTheEarlierResultIsFinal() {
        var transcript = RecognitionTranscript()
        transcript.replace(range: range(start: 1, duration: 1), text: " there.", isFinal: true)
        transcript.replace(range: range(start: 0, duration: 1), text: "Hello", isFinal: false)

        #expect(transcript.snapshot == TranscriptSnapshot(committedText: "", partialText: "Hello there."))

        transcript.replace(range: range(start: 0, duration: 1), text: "Hello", isFinal: true)

        #expect(transcript.snapshot == TranscriptSnapshot(committedText: "Hello there.", partialText: ""))
    }

    @Test func finalResultAtStopDoesNotDuplicateTheLastProvisionalWords() {
        var transcript = RecognitionTranscript()
        transcript.replace(range: range(start: 0, duration: 1), text: "Hello ", isFinal: true)
        transcript.replace(range: range(start: 1, duration: 1), text: "worl", isFinal: false)

        transcript.replace(range: range(start: 1, duration: 1), text: "world.", isFinal: true)
        transcript.replace(range: range(start: 1, duration: 1), text: "world.", isFinal: true)

        #expect(transcript.snapshot == TranscriptSnapshot(committedText: "Hello world.", partialText: ""))
        #expect(transcript.snapshot.text == "Hello world.")
    }

    private func range(start: Int64, duration: Int64) -> CMTimeRange {
        CMTimeRange(start: CMTime(value: start, timescale: 1), duration: CMTime(value: duration, timescale: 1))
    }
}
