# Testing guide for agents

Read this before changing code, tests, verification scripts or testing guidance.
Follow the steps in order. This is the procedure; [verification](verification.md)
records coverage/evidence, [permissions](permissions.md) lists access prerequisites,
and [the harness reference](debug-verification.md) explains native execution.

## 1. Define the affected behavior

Inspect the planned change, its callers and existing assertions. Trace shared
services through their consumers: one changed file can affect several workflows.
Read the affected entries in [verification](verification.md), including their
substituted I/O and open gaps. For responsibilities or data-flow changes, read
[architecture](architecture.md) too.

Before implementation, state a short verification plan: affected behavior, named
Swift suites, any native/manual/live boundary checks, and excluded lanes with a
reason. Revise it when the diff expands. This step is complete when every affected
behavior has a check that would detect its regression, or an explicit coverage gap.

## 2. Choose checks from the changed boundary

Keep a representative workflow across each real mechanism. Put text, format,
response and timing variants in the lowest layer that detects them. Existing
workflow coverage stays maintained; an unchanged boundary need not run for each
variant change. Use the union of relevant rows for a change spanning behaviors.
When moving variants down the pyramid, preserve their assertions for saved
output, errors, copy/paste and session ownership.

| Changed behavior / likely entry point | Start with these Swift suites | Add when the higher-level boundary changes |
| --- | --- | --- |
| Correction passage/context/layout: `TranscriptCorrections`, `TranscriptLayout`, `TranscriptEdit` | `TranscriptCorrectionsTests`, `TranscriptLayoutTests`, plus `DictationControllerTests` for application of edits | `--only testStreamingQueueStopAndPersistence` for controller/overlay wiring. |
| Dictation queue, Stop, Cancel, session ownership: `DictationController`, `CorrectionController` | `DictationControllerTests`; include affected transcript suites | Select the relevant streaming, Cancel/restart or preparation workflow from `test-ui.sh --all --list`. |
| Cleanup HTTP/schema/errors: `OpenAITranscriptCorrector`, `FakeOpenAI`, `LocalHTTPServer` | `OpenAITranscriptCorrectorTests`, `FakeOpenAIIntegrationTests`, `DictationControllerTests` | `--only testCleanupFailureKeepsAudioAndNeverPastesPartialText` for error presentation/completion wiring. Changed model instructions also need a deliberate live output check. |
| Cleanup preferences/dictionary/config persistence: `CorrectionSettings`, `Settings` | `CorrectionSettingsTests`, `PersistenceTests` | `--only testCleanupSettingsValidationCancelResetAndPayload` for editor, save/reset or relaunch wiring. |
| Saved-recording upload/retry/history: `OpenAITranscriber`, `RecordingTranscriptionController`, `RecordingStore` | `RecordingTranscriptionControllerTests`, `FakeOpenAIIntegrationTests`, `PersistenceTests` | `--only testSavedRecordingUploadRetryCancelAndCopy` for native actions/presentation. Add paste only when external delivery changes. |
| Credential loading/cache: `OpenAICredentials`, `KeychainStore` | `CredentialsTests` | An isolated real-Keychain check when item storage/access changes; injected loaders do not prove macOS trust. |
| Recognition revisions/punctuation/pauses: `RecognitionTranscript`, `LocalSpeechTranscript` | `RecognitionTranscriptTests`, `LocalSpeechTranscriptTests`, `SpeechPauseDetectorTests` | `--with-audio` when recognizer/service integration changes, rather than for each parsing variant. |
| Capture/conversion/AAC or inference lifecycle: `MicrophoneDictationService`, `SpeechRecognitionSession`, `LocalSpeechRecognizer` | `MicrophoneCaptureTests` and affected recognition/controller suites | `--with-audio` for shared audio/recognizer wiring. Actual tap/device acquisition/shutdown changes also require a capture check; file replay bypasses those. |
| Speech-engine settings/model readiness: `SpeechRecognitionEngine`, `SpeechSettingsWindowController` | `PersistenceTests` and affected recognition suites | `--only testSpeechSettingsDefaultCancelAndMissingModel` for controls/validation; `--with-audio` for engine switching/inference. Download behavior needs its own I/O check. |
| Shortcut timing/parsing/registration: `DoubleShiftShortcut`, `GlobalHotkey`, `EscapeShortcut`, shortcut capture | `ShortcutTests` | `--with-global-shortcuts` for cross-app registration/delivery/Escape. Default double-Shift delivery still needs its separate manual check. |
| External paste, focus, clipboard: production paste dispatch or `DebugSystemPaste` | Relevant completion tests in `DictationControllerTests`, `RecordingTranscriptionControllerTests` | `--with-paste` for real activation, Command-V, destination text and clipboard restoration. |
| AppKit presentation/startup/composition: window controllers, `main.swift` | Suites for every affected connected service | Relevant `--only` methods, or `--with-ui` for broad core wiring; add external I/O flags only for affected boundaries. |
| Build/signing/packaging or verification scripts | Shell syntax; `verify-test-selection.sh` for selectors | `--with-release` for production artifacts. Runner invocation changes need a representative selected native run. |

The table is a routing aid, not a replacement for reading the assertions. If
the impact cannot be bounded, run all Swift tests with `./scripts/check.sh`,
then select the affected external boundaries. Add a focused regression when
existing tests do not detect the change; record boundaries without a check as gaps.

For prose/link-only changes, check links, examples and `git diff --check`.
Exercise documented `--help`/`--list` commands when changing testing instructions;
application tests are needed only if application or test behavior also changes.

## 3. Preview the exact selection

Use actual CLI help for the complete flag inventory:

```sh
./scripts/check.sh --help
./scripts/test-ui.sh --help
```

An executing `check.sh` run checks shell/selector contracts, builds Swift, and
runs Swift tests. Its default is all Swift tests and **no native UI or archive**.
Narrow Swift tests with `--filter 'SuiteA|SuiteB'`. Add affected native groups with
`--with-ui`, `--with-paste`, `--with-global-shortcuts`, `--with-audio`, or select
exact methods with repeatable `--only METHOD`. Add archive validation with
`--with-release`.

`test-ui.sh` is UI-only. With no selection it runs core AppKit workflows; an
explicit selection runs only the union of requested groups/methods. `--only`
accepts a bare method or `ChattyUITests/DictationUITests/METHOD`. With `check.sh`,
`--only` narrows native tests, while `--filter` independently narrows Swift tests.

For a correction-context change with unchanged UI wiring:

```sh
./scripts/check.sh --filter 'TranscriptCorrectionsTests|TranscriptLayoutTests|DictationControllerTests' --list
```

For cleanup settings control/save wiring:

```sh
./scripts/check.sh --filter 'CorrectionSettingsTests|PersistenceTests' --only testCleanupSettingsValidationCancelResetAndPayload --list
```

For paste and shortcut changes together, preview
`./scripts/check.sh --with-paste --with-global-shortcuts --list`.
Add `--with-ui` only if core controls also changed.

The preview must match the plan: every intended native workflow is listed and
unrelated workflows are absent. A Swift regex is printed, not resolved by
`--list`; after execution, inspect `build/check-logs/tests.log` for the intended
suites and nonzero test count. An empty or mistaken selection is not verification.

## 4. Execute and resolve selected checks

Before a selected native, capture or live-service check, read the relevant row in
[permissions](permissions.md). For native setup and artifact reuse, read
[the harness reference](debug-verification.md#native-execution-and-authorized-artifacts).
Native runs share focus/keyboard/clipboard: keep them serial on an unlocked Mac.
Use `--no-build` only when the packaged app and runner already contain the source
under test; it preserves existing signatures and does not compile their changes.

After checking prerequisites, execute the previewed command without `--list`.
Run lower-level checks first; `check.sh` does this before its selected native
checks. After code edits, at least `swift build` must pass; `check.sh` includes it.
Full builds/test suites use `qlock` on `/tmp/agent-cpu.lock`; both wrappers lock
their expensive commands. Direct focused Swift tests need no lock and use
`swift test -Xswiftc -DCHATTY_DEBUG_PANEL --filter 'SuiteName'`. Tests in
`ChattyTests` include real loopback HTTP, files and supplied-buffer AVFoundation
processing; they require no desktop, live key, model weights or privacy grants.

If a selected check is blocked, retain its error/result bundle and exact app
identity, finish independent checks, then request only the missing access.
Preserve the signed artifacts during approval and retry that slice with
`--no-build`. An unrelated unselected lane does not block the changed slice;
a required blocked check remains unverified. Follow the permissions reference
for refreshing the exact grant; ordinary test runs preserve TCC decisions.

Use `./scripts/check.sh --all` for a release or explicitly required full regression
gate. It runs all Swift tests, the unfiltered native target and archive checks;
`--filter`/`--only` cannot narrow it. A release gate stays incomplete until its
required checks pass. This does not turn unrelated desktop tests into a requirement
for every scoped change.

Even `--all` substitutes physical capture, live OpenAI and real Keychain use.
File replay proves recognizers but bypasses the input tap; the shortcut workflow
uses a custom chord, not the default double-Shift monitor. For changes to those
boundaries, run a deliberate hardware/live/manual check with synthetic material
and the documented access, or report the exact gap. [Verification](verification.md)
records current evidence; [the read-aloud passage](dictation-test.md) supports
manual microphone comparisons. Keep keys out of arguments, files and logs.

## 5. Close with evidence

Recheck the final diff against the plan. Every affected behavior needs a passed
relevant check or a stated gap; broaden selection when new affected callers or
failures reveal a wider scope. Once checks pass, rerun only for subsequent relevant
changes or unresolved failures.

Update affected entries in [verification](verification.md) in the same change
when behavior, tests or coverage changes. Name the executed test/check, its real
I/O, substitutions and result; keep unexecuted checks unchecked. A historical
successful run is context, not evidence that today's artifacts passed.

Report: changed scope; commands and actual test counts/results; excluded lanes
with reasons; blocked/remaining gaps and artifact paths. Selected failures fail
the run. Classify new native workflows in `test-ui.sh`; the selector verifier
checks the catalogue, and native `--all` remains unfiltered.
