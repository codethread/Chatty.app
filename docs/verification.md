# Verification and the testing pyramid

Checked items have executed evidence; unchecked items are verification gaps.
Update affected items when behavior or tests change, naming the actual I/O boundary.

- **Auto UI:** XCUITest operates real AppKit controls in the signed debug app.
- **Auto IO:** Real HTTP, files or AVFoundation processing without desktop UI.
- **Unit/DI:** Pure logic or injected collaborators, with hardware/services substituted.
- **Manual:** A recorded human check. Agent-operated desktop checks are labeled separately.

The native suite is [DictationUITests](../Tests/ChattyUITests/DictationUITests.swift).
[ChattyTests](../Tests/ChattyTests) contains both logic and real component I/O;
its framework/folder name alone does not identify the boundary tested.
See the [testing runbook](debug-verification.md) for execution procedures.

## Choose the lowest layer that proves the behavior

Keep a small maintained workflow test across each real mechanism, then exercise
its variants at the lowest layer that can detect the relevant regression. A
past successful run is evidence, not a reason to retire that workflow test.
When moving cases down, preserve their outcomes (saved audio, errors, copy/paste,
session ownership), run the replacement tests, and keep the native check for
control wiring and presentation. The full gate runs both layers.

| Mechanism retained at the higher layer | Variants owned by faster tests |
| --- | --- |
| File replay through **each** recognizer, conversion/AAC, cleanup and saved output: `testAudioEngineSwitchAppliesToNextSession` | Buffer ownership, sample rates/channels and metering: `MicrophoneCaptureTests`; recognition revisions, punctuation and pause boundaries: `RecognitionTranscriptTests`, `LocalSpeechTranscriptTests`, `SpeechPauseDetectorTests`. |
| Native streaming/Stop, Cancel/restart and preparation cancellation | Queue/context/revision handling, stale replies and session ownership: `DictationControllerTests`, `TranscriptCorrectionsTests`, `TranscriptLayoutTests`. |
| One incomplete HTTP response and one Stop failure shown in the running app | All eight HTTP/response failures and all four input-failure stages, including retained audio and completion suppression: `DictationControllerTests`. These are component tests with real loopback HTTP/files and substituted capture/presentation. |
| Native saved-recording Transcribe/Retry, Cancel and Copy | Multipart bytes/vocabulary, persisted errors, retry and background ownership: `FakeOpenAIIntegrationTests`, `RecordingTranscriptionControllerTests`. |
| Settings validation, Save/Cancel/Reset and relaunch | Invalid dictionary/context variants and instruction encoding: `CorrectionSettingsTests`; file persistence/retention/corruption: `PersistenceTests`. |
| Cross-app shortcut/Escape and production paste with clipboard restoration | Timing/modifier/key variants: `ShortcutTests`. Keep desktop tests because constructed events cannot prove global delivery or focus. |

Pure parsing/state tests come first; real component I/O comes next; native
workflows prove app/platform wiring. Hardware and live-service checks cover
boundaries these layers substitute. Do not multiply UI scenarios for every
response, text, format or timing variant. Add a higher-layer case when it crosses
a different boundary or reveals a wiring failure lower tests cannot observe.

**Automated microphone evidence is still incomplete:** file replay bypasses the
real input tap, and direct buffers do not prove device acquisition or shutdown.
The recorded human comparison below exercises microphone recognition and live
cleanup; device shutdown/recovery and the virtual-input lane remain gaps.
Retain a representative capture-to-output workflow when automating that lane,
and keep format/text variants in the existing faster suites.

## Install, launch and grant access

- [x] **Auto IO:** Production ZIP signing, menu-bar identity and debug exclusion. [Archive check](../scripts/verify-release.swift).
- [x] **Auto UI:** Fresh debug storage, relaunch and isolation from production. `testStreamingQueueStopAndPersistence`, `testCleanupSettingsValidationCancelResetAndPayload`.
- [x] **Agent-operated IO:** Homebrew upgraded 0.3.0 → 0.4.0 from the published release, 2026-11-07. Verified the archive checksum/signature, installed version/menu-bar identity, exact installed binary and `chatty` symlink target; opened `/Applications/Chatty.app` and confirmed its process running. Local record: `build/homebrew-0.4.0-verification.json`.
- [ ] **Manual:** Fresh Homebrew install, installed menu interaction and invoking the `chatty` launcher from Terminal. The agent-operated upgrade check above does not exercise those interactions.
- [ ] **Manual:** Production Microphone/Accessibility allow/deny, visible failures and recovery after permission changes.
- [ ] **Manual:** API-key menu, real Keychain save/trust, replacement and relaunch. The debug suite supplies a fake key.
- [x] **Unit/DI:** Shared credential loading/cache, cancellation, replacement and retry with an injected loader. [CredentialsTests](../Tests/ChattyTests/PersistenceAndCredentialsTests.swift).

## Choose a speech engine and download its model

- [x] **Auto UI:** Apple default, Cancel and missing-model Save validation. `testSpeechSettingsDefaultCancelAndMissingModel`.
- [x] **Auto UI + audio:** Cached Nemotron load, persisted selection, both recognizers and switching only the next session. `testAudioEngineSwitchAppliesToNextSession`.
- [x] **One-off Auto IO / desktop check:** Cold download, progress, interrupted/resumed cache, readiness and native Save for both engines, 2026-11-07. Local records: `build/native-verification.json`, `build/speech-download-resume-verification.json`.
- [ ] **Automated IO gap:** Maintained cold-download readiness check; cache interruption/resume and download-failure variants belong in component I/O tests. The ordinary suite uses cached weights; the one-off record is not a maintained regression check.

## Start dictation and watch words arrive

- [x] **Auto UI:** Start/Inject, stable/provisional text, active/queued highlights and serial cleanup. `testStreamingQueueStopAndPersistence` injects text and synthetic AAC.
- [x] **Auto UI + audio:** Apple/Nemotron inference, shared conversion/AAC, pause endpointing and cleanup from a clock-paced WAV. `testAudioEngineSwitchAppliesToNextSession` bypasses the microphone tap.
- [x] **Auto IO:** Owned capture-buffer copies off-main; right-channel-only stereo at 16/44.1/48 kHz becomes mono analysis/playable AAC with levels/file sizes. [MicrophoneCaptureTests](../Tests/ChattyTests/MicrophoneCaptureTests.swift) supplies buffers directly.
- [x] **Unit:** Recognition revisions, sentence/tail splitting, pause punctuation and final-word deduplication. [RecognitionTranscriptTests](../Tests/ChattyTests/RecognitionTranscriptTests.swift), [LocalSpeechTranscriptTests](../Tests/ChattyTests/LocalSpeechTranscriptTests.swift).
- [ ] **Manual / hardware:** Speak through each recognizer; check first-word delay, live updates, saved audible recording and warm restart.
- [ ] **Automated IO gap:** Virtual Core Audio fixture feed through the actual input tap. [Proposed lane](macos-io-testing.md).
- [x] **Manual / hardware + service IO:** User read the [programming/path passage](dictation-test.md) through Apple and Nemotron in Chatty 13 with live sentence cleanup, 2026-11-07. Both final transcripts were usable; Nemotron felt faster and was preferred. Both retained technical/path errors. This compares the complete experience, not isolated recognition accuracy; user supplied both final outputs in this chat.

## Stop and insert the finished text

- [x] **Auto UI:** Tail flush, cleanup completion, one copy/completion, playable AAC/transcript and history reload. `testStreamingQueueStopAndPersistence`.
- [x] **Auto UI / desktop IO:** Production activation/CGEvent Command-V, exact separate-editor text and restoration of every clipboard representation. `testExternalApplicationPasteAndClipboardRestoration`.
- [x] **Unit:** Context/pending speech/final-fragment handling preserves older corrected text. [TranscriptCorrectionsTests](../Tests/ChattyTests/TranscriptCorrectionsTests.swift), [TranscriptLayoutTests](../Tests/ChattyTests/TranscriptLayoutTests.swift).
- [x] **Recorded desktop check:** File replay through each engine pasted expected text into TextEdit and restored the clipboard, 2026-11-07. Local record: `build/native-verification.json`.
- [ ] **Manual:** Physical-microphone Stop into daily rich-text/web editors, focus changes, selected-text replacement and clipboard changes during recording.

## Cancel and immediately start again

- [x] **Auto UI:** Copy visible text, discard unsaved audio, reject released stale replies, cancel preparation and restart. `testCancelHeldReplyAndRestart`, `testPreparationCancelAndStopFailure`.
- [x] **Auto UI / keyboard IO:** External-app Escape cancels injected dictation, copies the tail and creates no recording. `testCrossApplicationShortcutAndEscape`.
- [x] **Auto IO + DI:** Session ownership and background-upload overlay leases, with real loopback HTTP/files and substituted capture/presentation. [DictationControllerTests](../Tests/ChattyTests/DictationControllerTests.swift), [RecordingTranscriptionControllerTests](../Tests/ChattyTests/RecordingTranscriptionControllerTests.swift).
- [ ] **Automated audio gap:** Real-recognition Cancel/restart and early Stop. Exercise recognition-service lifecycle without desktop UI; retain a representative native cancellation check when connected. Current native cancellation injects snapshots.
- [ ] **Manual / hardware:** Cancel actual capture, restart immediately and verify the old microphone stream stopped.

## Recover from recording or cleanup errors

- [x] **Auto UI + HTTP/files:** One incomplete response after a successful correction retains playable AAC/history, shows an error and prevents partial copy/paste. `testCleanupFailureKeepsAudioAndNeverPastesPartialText` uses real URLSession against loopback.
- [x] **Auto UI:** Preparation Cancel/restart and an injected Stop failure prove native actions and error presentation. `testPreparationCancelAndStopFailure` substitutes capture and retains playable audio.
- [x] **Auto IO + DI:** All eight HTTP/response failures (401, 429, 500, malformed, empty, refusal, incomplete, disconnect) after a successful correction retain playable AAC/error history, present errors and never copy or complete partial text. `cleanupFailuresKeepAudioAndNeverCopyOrCompletePartialText` in [DictationControllerTests](../Tests/ChattyTests/DictationControllerTests.swift) uses the production client with real loopback HTTP/files; capture/presentation are substituted.
- [x] **Auto IO + DI:** Preparation, stream, Stop and Cancel failures present errors and preserve available playable audio; preparation failure creates no history. `inputFailuresPresentErrorsAndPreserveAvailableAudio` in [DictationControllerTests](../Tests/ChattyTests/DictationControllerTests.swift). A failed Cancel still copies the visible text as intended, but never completes/pastes.
- [x] **Auto IO:** Posted payload, multipart bytes and held-request cancellation/reuse. [FakeOpenAIIntegrationTests](../Tests/ChattyTests/FakeOpenAIIntegrationTests.swift).
- [x] **Unit:** Response-shape variants reject partial/refused/empty/malformed output; authentication errors redact the key. [OpenAITranscriptCorrectorTests](../Tests/ChattyTests/OpenAITranscriptCorrectorTests.swift).
- [ ] **Manual / hardware:** Input-device change/disconnection, capture shutdown, error presentation, retained audio and recovery.
- [ ] **Manual / service IO:** Live OpenAI authentication, rate limiting, network loss, output quality and latency. Loopback establishes wire/lifecycle behavior.
- [ ] **Automated audio gap:** Silence-only/missing-source files through the recognition service belong in component audio tests. Controller/punctuation no-speech logic has focused checks; another full desktop workflow is not required for every file variant.

## Re-transcribe, retry and copy a saved recording

- [x] **Auto UI + HTTP/files:** Transcribe/Retry, Cancel upload, Copy, persisted error clearing, exact multipart AAC bytes/SHA256 and stale-upload isolation. `testSavedRecordingUploadRetryCancelAndCopy`.
- [x] **Auto IO:** Multipart vocabulary and reference-transcript parsing. [FakeOpenAIIntegrationTests](../Tests/ChattyTests/FakeOpenAIIntegrationTests.swift).
- [ ] **Manual:** Open saved audio in the system player, confirm audible contents and verify the transcription-vocabulary editor.
- [ ] **Manual / service IO:** Real saved-speech upload, transcript quality and saved-recording paste into another app. Fake uploads return a reference transcript.

## Edit sentence cleanup and the dictionary

- [x] **Auto UI + HTTP/files:** Validation, Save/Cancel, Reset with Save/Cancel, relaunch persistence and posted instructions/dictionary. `testCleanupSettingsValidationCancelResetAndPayload`.
- [x] **Unit:** Dictionary parsing/capitalization, invalid entries, context counts and instruction serialization. [CorrectionSettingsTests](../Tests/ChattyTests/CorrectionSettingsTests.swift).
- [ ] **Manual / service IO:** Real cleanup preserves tone/context and applies preferred spellings on representative speech.

## Configure and use recording shortcuts

- [x] **Auto UI / keyboard IO:** Native Control–Option–Command–9 capture, delivery from another app, Listening and Escape cancellation. `testCrossApplicationShortcutAndEscape` uses keyboard events.
- [x] **Unit:** Double-left-Shift timing/filtering and modifier/key parsing from constructed NSEvents. [ShortcutTests](../Tests/ChattyTests/ShortcutTests.swift).
- [x] **Manual:** User physically pressed Control–Option–Command–9 from another app and confirmed Listening, 2026-11-07.
- [ ] **Manual / desktop IO:** Default double-left-Shift start/stop in the production app across daily target apps. The automated desktop test uses the custom chord.

## Keep and recover stored data

- [x] **Auto UI + files:** Saved transcript/settings survive relaunch in isolated stores. `testStreamingQueueStopAndPersistence`, `testCleanupSettingsValidationCancelResetAndPayload`.
- [x] **Auto IO:** Expired-only retention, config isolation and corrupt/unwritable-store rejection without replacing metadata. [PersistenceTests](../Tests/ChattyTests/PersistenceAndCredentialsTests.swift) uses temporary files.
- [ ] **Automated UI gap:** Running-app storage error/recovery and startup retention. Store-level checks do not cover presentation and relaunch together.

## Evidence and maintenance

Last full gate: **2026-11-07**, `./scripts/check.sh --no-build`; 60 Swift test
functions in 14 suites, 10 native UI workflows, zero failures/skips, and signed
archive validation. The UI runner was rebuilt with `xcodebuild build-for-testing`
first; app sources were unchanged, so `--no-build` preserved the authorized
app's ad-hoc Accessibility identity.
Local result: `build/ChattyUI-20261107-205329.xcresult`.

The native run took 162 seconds, compared with 203 seconds in the previous
full gate (`build/ChattyUI-20261107-202359.xcresult`) on this Mac. The two failure
workflows took 22 seconds instead of 60. All eight cleanup and four input-failure
variants remain in the component suite with real files/loopback HTTP where
applicable. These are single-run timings, not a benchmark guarantee.

Keep checked items tied to named tests or dated records. When a flow changes,
update its coverage, actual I/O boundaries and remaining gaps. Execution procedures
belong in the [testing runbook](debug-verification.md).
