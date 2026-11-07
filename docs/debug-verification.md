# Debug verification

Acceptance is based on complete user workflows in the running application.
Targeted Swift tests support specific logic; their count does not establish
integration correctness. The scenario runner launches a real signed app and
observes its controllers, native views, files and HTTP traffic together.

Run `./scripts/check.sh` from a macOS 26 Apple Silicon checkout. It acquires
`/tmp/agent-cpu.lock` for Swift builds, tests, release packaging and the AppKit
scenario suite. It builds both production and `CHATTY_DEBUG_PANEL`, signs and
verifies a production archive, then packages a unique verification app, launches
it with fresh storage, exercises it, renders its own views and quits it. It does
not install into `/Applications`, reset TCC, alter the production clipboard or
kill another checkout's app. Logs are in `build/check-logs/`; the machine-readable
report is `build/check-verification.json`.

The default includes a downloaded local Nemotron model and real-time file audio.
`--skip-audio` skips only the four model-dependent scenarios. Model preparation
can download roughly 626 MB once. No OpenAI token is required: the default
backend is a real HTTP server bound to `127.0.0.1` on an ephemeral port.

## Interactive controls

`./scripts/run-debug.sh` opens this checkout's debug panel. Its config, recordings
and rendered artifacts live in `build/debug-data/`. The panel exposes:

- Stable and provisional recognition snapshots, waveform levels and AAC files.
- Typed streaming, local audio replay, Apple and Nemotron microphone sources.
- HTTP success, held replies, authentication/rate/server errors, disconnection,
  malformed JSON, refusal, incomplete response and empty output.
- Preparation, stream, Stop and Cancel failures, including held preparation.
- Posted payload inspection, request timing, a private clipboard and AppKit paste
  destination, saved-recording upload/retry/cancel/copy, and sentence settings.

`python3 scripts/chatty-debug.py --help` lists the CLI operations. Mutations
acknowledge acceptance; follow them with `wait` to assert the resulting state.
Waits subscribe to controller events, with a 15-second deadline. The scenarios do
not synchronize with fixed sleeps. Audio replay deliberately follows a clock to
exercise streaming; overlay success deliberately dismisses after one second.

```sh
python3 scripts/chatty-debug.py fake hold
python3 scripts/chatty-debug.py start
python3 scripts/chatty-debug.py wait --phase listening
python3 scripts/chatty-debug.py inject --committed 'First sentence.' --partial 'live tail'
python3 scripts/chatty-debug.py wait --requests 1
python3 scripts/chatty-debug.py requests
python3 scripts/chatty-debug.py release
python3 scripts/chatty-debug.py stop
python3 scripts/chatty-debug.py wait --phase complete
```

`requests` returns at most 20 summaries by default (maximum 100). `--id` expands
one actual posted payload, including instructions/input/model, or the audio
upload's byte count, SHA256 and vocabulary. The fake receives the production
encoder's JSON or multipart bytes and the production URLSession parses its
response. Cleanup returns the posted input in SCREAMING_SNAKE_CASE; audio uploads
return a configurable reference transcript, since the fake does not transcribe.

`ui settings --show` opens the actual settings window. Use `--control-label`,
`--value` and `--click` to edit real controls and invoke their target/action
handlers. `ui panel` reports Accessibility labels, values and enabled states.
These are the same windows used interactively, not parallel test forms.
`render panel` and `render overlay` write PNGs of the app's own view tree; they
exclude window chrome and desktop/background blur.

The control file contains an ephemeral token and is mode 0600. Do not commit or
share it. Every control endpoint checks `X-Chatty-Debug-Token`. The debug workspace
must be separate from the production data directory. Global shortcuts start off;
`globals --enabled` enables native registration when explicitly testing it.
`reset --clear-data` clears only the debug workspace's indexed recordings.

For an existing running app, `python3 scripts/verify-debug.py --audio` runs the
same scenarios and resets its sandbox. `--launch` instead packages the existing
Swift debug binary and owns a fresh process and workspace. Build with
`swift build -Xswiftc -DCHATTY_DEBUG_PANEL` before using `--launch` directly.

## External application paste check

With an unlocked desktop, create an empty TextEdit document and focus its editor.
Run `python3 scripts/chatty-debug.py system-paste --target-bundle com.apple.TextEdit`
and check that
`state.systemPasteTarget` is `com.apple.TextEdit`. Note the current
`systemPasteDispatches` count. Start injected dictation or replay the speech
fixture, observe Listening, then Stop. Wait for Complete and for
`wait --paste-dispatches N` with the previous count plus one. Inspect the actual TextEdit document through
the native UI; the text must match the completed transcript exactly. This path
runs production app activation and CGEvent Command-V, rather than the private
NSTextView paste shortcut. Finish with `restore-clipboard`; the snapshot reports
`clipboardRestored: true` only after every saved representation compares equal.
Clipboard data stays in memory and is never returned by the control API.
Restoration is rejected while keyboard paste is still queued. Dispatch completion
proves that events were posted; the destination's actual text remains the final
acceptance check.
The mode is one-shot and must be explicitly rearmed for another test. If someone
copies new content during the check, restoration keeps those newer contents and
reports that the clipboard changed.

## Evidence and limits

The 29 AppKit-process scenarios and focused Swift tests cover the following
boundaries. The JSON report records each scenario's evidence or failure state.

| Surface | Verification |
| --- | --- |
| Streaming lifecycle | Preparation, stable/provisional updates, queued cleanup, Stop, Escape, cancel/restart and stale replies through the actual controller. |
| Cleanup HTTP | Actual serialized payload, context, prompt/dictionary, all fake response/error modes and cancellation; real response parser. |
| Saved audio HTTP | Real playable AAC multipart upload, exact bytes and SHA256, vocabulary, saved transcript/error, retry, clear error, copy and cancellation. |
| Concurrent presentation | Background uploads still persist, but cannot replace/close live dictation or steal its clipboard. Delayed dismissal uses an operation-scoped overlay lease. |
| Overlay | Actual text storage, UTF-16 color spans, live/queued/corrected state, Unicode, five-line height cap, bottom scrolling, processing/error controls and PNG renders. |
| Settings | Actual speech-engine window defaults, download/load, Save, Cancel, persisted selection and switching both recognizers; cleanup window Save, validation, Cancel and Reset-then-Save actions, config reload, and settings in the posted API payload. |
| Persistence | Fresh store reload, retention, corrupt/unwritable storage, audio preserved on failure and restart after repair. |
| Credentials | Injected asynchronous Keychain loader: shared reads, caller cancellation, cache, replacement and failure/retry. No test writes a real API key. |
| Shortcuts | Modifier parsing and double-left-Shift timing with NSEvents; actual shortcut capture, reject bare letter, cancel, Carbon registration/unregistration, event dispatch and Escape lifecycle in the app. |
| Audio conversion | Shared capture processor: right-channel-only stereo at 16/44.1/48 kHz, downmix, analysis resampling, AAC decode, levels and file size. |
| Recognition integration | Clock-paced speech fixture through that processor, model, pause punctuation, HTTP cleanup, recording history, copy and AppKit paste. Cancel/restart, early Stop, silence and missing file. |
| Build/distribution | Ordinary Swift build, debug test build, production release archive, code signing/verification and a separately signed runnable harness bundle. |

On 2026-11-07 the 29 process scenarios passed. Targeted Swift logic checks also
passed. After unlocking, native UI operation verified panel Start/Inject/Stop,
settings validation/Cancel and the private paste destination. The speech fixture
then traversed capture conversion, local recognition, HTTP cleanup, AAC/history
persistence and the production activation/CGEvent paste path into a real TextEdit
document. Its exact visible text matched the completed transcript; restoring the
clipboard compared every representation successfully. Native evidence is recorded
in `build/native-verification.json` and `build/Chatty-native-paste.rtf`.

On 2026-11-07 the user confirmed that a physical Control–Option–Command–9
keypress with another app focused opens Chatty's listening overlay. This verifies
the custom shortcut across applications. Automated keypresses had not triggered
it; registration and direct Carbon dispatch alone were not accepted as proof.
The temporary binding was removed and debug global shortcuts disabled afterward.
Actual microphone hardware and TCC prompts require a human. The API fake verifies
wire/lifecycle behavior; real OpenAI output, authentication, latency and Keychain
trust dialogs remain external checks for the later token. Apple recognition
accuracy, optional Pi service output and noisy-environment accuracy are not
established by the deterministic local-model fixture.

## Production speech settings acceptance

`verify-debug.py --launch --audio` includes the real speech settings window:
Apple default, Cancel preserving the selection, actual model preparation, Save
and reload, Nemotron replay through the shared production recognizer, and switch
back to Apple with recording/paste verification. `--cold-model` gives the launched
app an empty model cache and exercises the actual download and missing-model
validation. It can download approximately 626 MB. Model waits observe state and
have an explicit 900-second deadline. The ordinary suite uses the shared cache.

See [macOS I/O testing research](macos-io-testing.md) for the proposed virtual-input
and XCUITest lane that would additionally cross the real microphone input tap.

On 2026-11-07 the empty-cache check rejected Save before download, displayed the
real network download, and completed after an interruption/restart using the
partial cache: approximately 626 MB, no partial files remaining. All 29 app
workflows passed against that model. Native controls also saved both engine
choices and both paths were observed pasting into TextEdit. The final Apple
check used a clean document and waited for actual paste dispatch before inspecting
its text. Premature clipboard restoration was rejected, and restoration after
inspection compared all representations successfully. Local artifacts are
`build/speech-download-resume-verification.json`, `build/native-verification.json`
and `build/Chatty-production-engines.rtf`.
