# Verification checklist

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

## Install, launch and grant access

- [x] **Auto IO:** Production ZIP signing, menu-bar identity and debug exclusion. [Archive check](../scripts/verify-release.swift).
- [x] **Auto UI:** Fresh debug storage, relaunch and isolation from production. `testStreamingQueueStopAndPersistence`, `testCleanupSettingsValidationCancelResetAndPayload`.
- [ ] **Manual:** Homebrew install/upgrade, installed menu-bar launch and the `chatty` launcher.
- [ ] **Manual:** Production Microphone/Accessibility allow/deny, visible failures and recovery after permission changes.
- [ ] **Manual:** API-key menu, real Keychain save/trust, replacement and relaunch. The debug suite supplies a fake key.
- [x] **Unit/DI:** Shared credential loading/cache, cancellation, replacement and retry with an injected loader. [CredentialsTests](../Tests/ChattyTests/PersistenceAndCredentialsTests.swift).

## Choose a speech engine and download its model

- [x] **Auto UI:** Apple default, Cancel and missing-model Save validation. `testSpeechSettingsDefaultCancelAndMissingModel`.
- [x] **Auto UI + audio:** Cached Nemotron load, persisted selection, both recognizers and switching only the next session. `testAudioEngineSwitchAppliesToNextSession`.
- [x] **One-off Auto IO / desktop check:** Cold download, progress, interrupted/resumed cache, readiness and native Save for both engines, 2026-11-07. Local records: `build/native-verification.json`, `build/speech-download-resume-verification.json`.
- [ ] **Automated gap:** Maintained cold-download/resume and download-failure recovery lane. The ordinary suite uses cached weights.

## Start dictation and watch words arrive

- [x] **Auto UI:** Start/Inject, stable/provisional text, active/queued highlights and serial cleanup. `testStreamingQueueStopAndPersistence` injects text and synthetic AAC.
- [x] **Auto UI + audio:** Apple/Nemotron inference, shared conversion/AAC, pause endpointing and cleanup from a clock-paced WAV. `testAudioEngineSwitchAppliesToNextSession` bypasses the microphone tap.
- [x] **Auto IO:** Owned capture-buffer copies off-main; right-channel-only stereo at 16/44.1/48 kHz becomes mono analysis/playable AAC with levels/file sizes. [MicrophoneCaptureTests](../Tests/ChattyTests/MicrophoneCaptureTests.swift) supplies buffers directly.
- [x] **Unit:** Recognition revisions, sentence/tail splitting, pause punctuation and final-word deduplication. [RecognitionTranscriptTests](../Tests/ChattyTests/RecognitionTranscriptTests.swift), [LocalSpeechTranscriptTests](../Tests/ChattyTests/LocalSpeechTranscriptTests.swift).
- [ ] **Manual / hardware:** Speak through each recognizer; check first-word delay, live updates, saved audible recording and warm restart.
- [ ] **Automated IO gap:** Virtual Core Audio fixture feed through the actual input tap. [Proposed lane](macos-io-testing.md).
- [ ] **Manual:** Compare accuracy and perceived latency on representative speech beyond the synthetic fixture.

## Stop and insert the finished text

- [x] **Auto UI:** Tail flush, cleanup completion, one copy/completion, playable AAC/transcript and history reload. `testStreamingQueueStopAndPersistence`.
- [x] **Auto UI / desktop IO:** Production activation/CGEvent Command-V, exact separate-editor text and restoration of every clipboard representation. `testExternalApplicationPasteAndClipboardRestoration`.
- [x] **Unit:** Context/pending speech/final-fragment handling preserves older corrected text. [TranscriptCorrectionsTests](../Tests/ChattyTests/TranscriptCorrectionsTests.swift), [TranscriptLayoutTests](../Tests/ChattyTests/TranscriptLayoutTests.swift).
- [x] **Recorded desktop check:** File replay through each engine pasted expected text into TextEdit and restored the clipboard, 2026-11-07. Local record: `build/native-verification.json`.
- [ ] **Manual:** Physical-microphone Stop into daily rich-text/web editors, focus changes, selected-text replacement and clipboard changes during recording.

## Cancel and immediately start again

- [x] **Auto UI:** Copy visible text, discard unsaved audio, reject released stale replies, cancel preparation and restart. `testCancelHeldReplyAndRestart`, `testPreparationCancelAndInputFailures`.
- [x] **Auto UI / keyboard IO:** External-app Escape cancels injected dictation, copies the tail and creates no recording. `testCrossApplicationShortcutAndEscape`.
- [x] **Unit/DI:** Session ownership and background-upload overlay leases. [DictationControllerTests](../Tests/ChattyTests/DictationControllerTests.swift), [RecordingTranscriptionControllerTests](../Tests/ChattyTests/RecordingTranscriptionControllerTests.swift).
- [ ] **Automated audio gap:** Real-recognition Cancel/restart and early Stop in the maintained native suite; current native cancellation injects snapshots.
- [ ] **Manual / hardware:** Cancel actual capture, restart immediately and verify the old microphone stream stopped.

## Recover from recording or cleanup errors

- [x] **Auto UI + HTTP/files:** Eight HTTP/response failures retain playable AAC/history, show errors and prevent partial paste. `testHTTPFailuresKeepAudioAndNeverPastePartialText` uses real URLSession against loopback.
- [x] **Auto UI:** Injected preparation, stream, Stop and Cancel failures preserve available audio and show errors. `testPreparationCancelAndInputFailures` substitutes capture.
- [x] **Auto IO:** Payload encoding, response parsing and held-request cancellation/reuse. [FakeOpenAIIntegrationTests](../Tests/ChattyTests/FakeOpenAIIntegrationTests.swift).
- [ ] **Manual / hardware:** Input-device change/disconnection, capture shutdown, error presentation, retained audio and recovery.
- [ ] **Manual / service IO:** Live OpenAI authentication, rate limiting, network loss, output quality and latency. Loopback establishes wire/lifecycle behavior.
- [ ] **Automated audio gap:** Silence-only/missing-source files through the recognizer in the maintained native suite. Controller/punctuation no-speech logic has focused checks.

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

Last full gate: **2026-11-07**, `./scripts/check.sh --no-build`; 10 native UI workflows,
zero failures/skips, plus Swift logic/component-I/O checks and signed archive validation.
Local result: `build/ChattyUI-20261107-202359.xcresult`. UI artifacts were built and
authorized first; `--no-build` preserves their ad-hoc Accessibility identity.

Keep checked items tied to named tests or dated records. When a flow changes,
update its coverage, actual I/O boundaries and remaining gaps. Execution procedures
belong in the [testing runbook](debug-verification.md).
