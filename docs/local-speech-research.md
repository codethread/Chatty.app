# Local speech recognition experiment

Investigated 7 November 2026 on an Apple M4 Pro, 24 GB RAM, macOS 26.7.2.
Branch: `codex/local-streaming-dictation`. This is a demo experiment; production
composition still selects Apple SpeechAnalyzer.

## Finding

Local recognition can comfortably produce text while the user is speaking.
The working demo uses **Nemotron Speech Streaming 600M, int8, 560 ms chunks**
through FluidAudio 0.15.6. On a 19.71-second office-dictation sample, first text
appeared at **0.58 seconds**, changes arrived at a median **0.56-second** interval,
and the last audio packet finished in another **37 ms**. The model has ample
inference headroom: processing that recording without pacing took **0.43 seconds**,
about 46 times faster than real time. These timings exclude model loading.

**An accuracy improvement over Apple is not established.** On five short clean
English audiobook clips, Apple and batch Parakeet TDT each made one word error;
streaming Nemotron made two. This is a 157-word, single-speaker sample, not an
accuracy benchmark representative of Adam's dictation. The live demo is ready
for that comparison; there is no evidence here to promise fewer mistakes yet.

## What OpenSuperWhisper contributes

[OpenSuperWhisper](https://github.com/starmel/OpenSuperWhisper), inspected at
`c8e6fe79d6851078940f459ab7dbc8ee39e2a97d`, integrates two useful local backends:

- [WhisperEngine](https://github.com/starmel/OpenSuperWhisper/blob/c8e6fe79d6851078940f459ab7dbc8ee39e2a97d/OpenSuperWhisper/Engines/WhisperEngine.swift)
  wraps whisper.cpp and supports direct PCM input, keeping models loaded between
  recordings.
- [FluidAudioEngine](https://github.com/starmel/OpenSuperWhisper/blob/c8e6fe79d6851078940f459ab7dbc8ee39e2a97d/OpenSuperWhisper/Engines/FluidAudioEngine.swift)
  loads Parakeet TDT v2/v3 models through a native Swift/Core ML dependency.

Its microphone UI [stops capture before calling transcription](https://github.com/starmel/OpenSuperWhisper/blob/c8e6fe79d6851078940f459ab7dbc8ee39e2a97d/OpenSuperWhisper/Indicator/IndicatorWindow.swift#L232-L252).
Its README also lists streaming transcription as future work. We can reuse the
engine choices, model caching and direct PCM approach, but its current capture
flow does not provide Chatty's live partial transcripts. This experiment depends
directly on FluidAudio; it copies no OpenSuperWhisper source.

## Model choices

| Candidate | Live behavior | Assessment |
| --- | --- | --- |
| Nemotron Streaming 600M | Native cache-aware streaming; 560/1120/2240 ms SDK tiers | Working 560 ms demo. The downloaded model variant is roughly 626 MB. |
| Parakeet TDT 600M v2 | Batch English recognition; overlapping windows needed for live results | Tested as an accuracy reference. Fixed “Concord,” which Nemotron rendered “Commoncord.” |
| Parakeet TDT v3 | Batch recognition with 25 European languages | Useful if multilingual input becomes a requirement; v2 is the SDK's recommended English choice. |
| Parakeet EOU 120M | Native 160/320 ms streaming | Faster feedback, but the model publisher reports 8.29%/4.87% LibriSpeech WER for those tiers. Not downloaded. |
| Whisper small / larger quantized Whisper | Repeated decoding of overlapping audio windows | Remains an option for quality comparison. whisper.cpp's example uses 500 ms steps over 5 seconds of audio; a step is not a guarantee of word latency. Not benchmarked here. |

Sources: [FluidAudio model catalog](https://github.com/FluidInference/FluidAudio/blob/v0.15.6/Documentation/Models.md),
[English model guidance](https://github.com/FluidInference/FluidAudio/blob/v0.15.6/Documentation/ASR/GettingStarted.md),
[Nemotron Core ML model](https://huggingface.co/FluidInference/nemotron-speech-streaming-en-0.6b-coreml),
[Parakeet EOU model](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml),
[whisper.cpp streaming example](https://github.com/ggml-org/whisper.cpp/tree/master/examples/stream).
Published model scores use different subsets and implementations; they are not
a direct ranking against Apple's recognizer on this Mac. The Core ML Nemotron
conversion also has its own artifact history; current NVIDIA model-card results
must not be assumed to describe the downloaded conversion.

## Small packets and model context

Small microphone packets are compatible with a larger model. They do not need
to become independent, context-free transcription requests. Chatty converts
audio to 16 kHz mono Float32 and feeds packets continuously. Nemotron accumulates
560 ms of new audio per inference step while retaining encoder and decoder
context across steps. Nothing is uploaded for recognition.

At that format, 80 ms is 5,120 bytes and 560 ms is 35,840 bytes. The app's existing
capture tap is 4096 frames at the microphone's native rate, so capture packets
are not necessarily exactly 80 ms; the file-replay harness uses exactly paced
80 ms packets. Recognition chunk size is independent of capture packet size.

The model remains loaded between sessions. Initial download plus device
preparation took 81 seconds; a separate cold app load took about 10 seconds.
Later process loads from Core ML's cache were about 0.13–0.25 seconds. Use
**Prepare local model** before judging the first spoken result. A production
rollout should prepare before the user begins speaking.

Sentence boundaries use a quiet-office pause rule: after speech, about one
second below -50 dBFS flushes and commits the current utterance, adding a full
stop if the model supplied no terminal punctuation. Recording continues and
decoder state resets for the next utterance, with weights still loaded. Short
pauses do not close an utterance. This makes statements eligible for cleanup
without requiring a question or stopping the recording. Stop also closes the
last statement. A long pause in the middle of a thought will therefore produce
a full stop; this is an audio pause rule rather than semantic sentence detection.
In a clock-paced replay with two statements separated by 1.6 seconds of silence,
the first full stop appeared at 3.16 seconds and the second at 6.75 seconds,
both before the 7.25-second recording ended. Both statements retained all their
words. The pause/full-stop change passes all 33 tests, including regressions for
short pauses, existing punctuation, final-word flushing and continued dictation.

The existing AAC recorder, waveform, overlay and cleanup pipeline are shared.
Complete recognized sentences enter cleanup while the unfinished tail remains
visible. Stop drains input and flushes the last model chunk. Cancel joins the
current inference before another session can reset the model state. With
**Transcription only**, the demo does not call OpenAI; choosing OpenAI cleanup
retains the existing text-upload behavior.

## Measurements

Release Swift build, no LLM cleanup. File audio was supplied on an absolute clock
in 80 ms packets. The synthetic office sample uses macOS's Daniel voice at 165
words/minute. It is useful for reproducibility, not evidence about human accents.

| Input / engine | First changed text | Median changed-text gap | Time after audio ends |
| --- | --- | --- | --- |
| Office, 19.71 s / Nemotron | 0.579 s | 0.560 s | 0.037 s |
| Office, 19.71 s / Apple | 1.057 s | Bursts of revisions | 0.154 s |
| Natural sample, 7.44 s / Nemotron | 1.159 s | 0.560 s | 0.033 s |
| Natural sample, 7.44 s / Apple | 1.058 s | Bursts of revisions | 0.084 s |

First-text time is measured from stream start, including any initial silence;
it is not a measured per-word acoustic latency. Update cadence excludes chunks
where text did not change. In-app replay also worked: first text at 614 ms,
typical decode work around 20–38 ms per changed chunk, final flush 26 ms.

The office sample had no Nemotron word errors, but one missed sentence boundary
(“text schedule a meeting”). Apple preserved that boundary. TDT also produced
all intended words, with “3” instead of “three” and an extra boundary after
“Thursday.” Cleanup could repair punctuation, but was disabled in these runs.
Three seconds of silence produced no text.
48 kHz stereo file input was also converted and transcribed successfully.

For a small natural-speech check, clips `6930-75918-0000` through `0004` from
[LibriSpeech test-clean](https://www.openslr.org/12) contain 57.14 seconds and 157
reference words. Each clip was reset and processed independently. Case and
punctuation were removed; apostrophes were retained. Word-error counts use
Levenshtein distance against the published transcripts:

| Engine | Errors / reference words | WER |
| --- | --- | --- |
| Apple SpeechAnalyzer, en-GB | 1 / 157 | 0.64% |
| Nemotron 600M, 560 ms streaming chunks | 2 / 157 | 1.27% |
| Parakeet TDT 600M v2, full-file batch | 1 / 157 | 0.64% |

Batch accuracy is an upper-context reference, not proof that short-window TDT
will preserve the same accuracy. These clips are one speaker reading literature;
proper names, technical vocabulary and spontaneous speech need real dictation
evaluation. The existing app already uses modern SpeechAnalyzer, not the older
SFSpeechRecognizer API, which is relevant when comparing internet anecdotes.

## Try the working demo

Build the explicitly requested demo with `./scripts/build-app.sh` under the
repository's `qlock`. It opens a numbered debug app. Choose **Microphone ·
Nemotron 600M · 560 ms**, prepare the model, keep **Transcription only**, then
start and speak. Compare the same phrases with **Microphone · Apple
SpeechAnalyzer**. Stop copies text and saves microphone audio; this demo does
not paste into another application.

**Replay audio…** runs a local recording through the full overlay/session flow
without accessing the microphone. Full replay, early Stop, and immediate Cancel
were verified in the app. Microphone capture with this new backend still needs
an actual spoken trial; file replay bypasses microphone hardware and permissions.

Raw local measurements and replay audio are retained in the worktree's ignored
`build/asr-research/` folder. `Chatty --benchmark-asr --help` documents the JSON
benchmark. Apple packet input is restricted to 16 kHz mono and converted to
Int16; supplying Float32 to SpeechAnalyzer triggers a framework precondition.
This was a harness error, corrected before the Apple results above.

Validation: `swift build`, all 33 tests, release demo compilation,
app signing verification, and
the file/GUI checks described above. Full builds and test suites used `qlock`
on `/tmp/agent-cpu.lock`.

## Decision

Keep Nemotron 560 ms as the usable local alternative in the demo. It satisfies
the live-text constraint on this Mac with substantial processing headroom.
Do not promote it as more accurate than Apple based on these results. The next
decision should use a short set of Adam's real phrases, especially names and
technical terms that Apple gets wrong. If those favor TDT or a larger Whisper
model, use live provisional output plus phrase-level audio re-decoding; measure
that combination before replacing the streaming backend.
