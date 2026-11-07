# Debug verification

Acceptance means complete workflows in the running application. Swift tests
support specific logic; their count does not establish integration correctness.
The native XCUITest bundle drives real AppKit controls in a separate process.
The authenticated harness API supplies fixtures/faults and observes state and
posted HTTP bytes. It also opens the shortcut-capture panel for the keyboard
contract. It does not click controls on the UI suite's behalf.

## Run the native suite

On an unlocked macOS 26 Apple Silicon Mac with full Xcode selected:

```sh
./scripts/test-ui.sh
./scripts/check.sh
```

`test-ui.sh` builds and signs `build/Chatty UITest.app`, then runs
`ChattyUITests.xcodeproj` with `xcodebuild test`. The main app stays a Swift
package; the small Xcode project contains the UI testing bundle and an owned
external paste destination. No project generator or scripting runtime is needed.
Each test launches Chatty with a fresh directory in the UI runner's sandbox temp folder, then
quits only its own app. Installed user builds and production storage stay separate.

On first run, macOS asks to **Enable UI Automation** using password/Touch ID.
Approve that system prompt. The test app also needs Accessibility permission for
its production CGEvent paste path: add `build/Chatty UITest.app` in System Settings
→ Privacy & Security → Accessibility. Neither script resets or edits TCC. A missing
authorization, locked desktop or unavailable model causes failure, not a passed
or silently skipped test. Run serially without other desktop automation: focus,
keyboard and clipboard are shared system resources.

Local builds use ad-hoc signing. A rebuilt app can invalidate its Accessibility
grant because macOS identifies that signature by its code hash. Reauthorize the
rebuilt app (remove and re-add its entry if the switch is on but access is still
denied), then use `./scripts/test-ui.sh --no-build` to run the previously
built app and UI bundle without replacing either. That mode intentionally does
not compile code changes. For an unattended test Mac, provision a stable signing
certificate and set `CHATTY_DEBUG_SIGN_IDENTITY` to its identity when packaging;
the script fails if that identity is unavailable. No certificate is created and
no code-signing requirement or TCC check is weakened by the tooling.
`./scripts/check.sh --no-build` still runs the Swift/release checks, then reuses
those UI artifacts. A normal run is required after changing the app or UI tests.

The default audio contract requires the already downloaded fixed Nemotron model
in Chatty's shared cache. Use the debug panel's Speech Recognition settings to
download it first (approximately 626 MB). The ordinary suite never initiates a
network download. `--skip-audio` explicitly excludes the named audio contract;
all remaining tests use an empty isolated model cache.

`check.sh` additionally runs locked Swift build/logic checks and packages a signed
production ZIP. Native Foundation code checks the extracted archive's identity,
menu-bar flag and absence of the debug harness. Expensive commands use
`qlock` on `/tmp/agent-cpu.lock`. Logs live in `build/check-logs/`; timestamped
`build/ChattyUI-*.xcresult` bundles contain results, final state attachments and
Xcode failure screenshots. Open a result with `open build/ChattyUI-….xcresult`.
Test workspaces remain available for inspecting config, metadata and AAC files;
their absolute paths are recorded in the attached final state.
They contain only the synthetic fixtures unless explicitly changed by a developer.

## Contracts

See [the UI tests](../Tests/ChattyUITests/DictationUITests.swift) for exact assertions.

On 2026-11-07, `./scripts/check.sh --no-build` passed the complete gate:
10 native UI workflows, zero failures and zero skips, including both recognizers,
cross-app keys and exact external paste with clipboard restoration. Swift checks
and signed production archive validation also passed. The local result is
`build/ChattyUI-20261107-202359.xcresult`; the authorized UI artifacts had already
been built before that run. A preceding full UI run also passed all ten workflows.

| Workflow | Observed contract |
| --- | --- |
| Stream, queue, Stop | Real Start/Inject/Stop buttons, visible stable/provisional text, active/queued text-storage highlights, serialized HTTP, tail flush, exactly one completion/copy, paste destination, playable AAC and transcript after relaunch. |
| Cancel and restart | Cancel copies visible text, discards unsaved audio, and a released late reply cannot change the next session. Held preparation can also be cancelled and restarted. |
| Capture failures | Preparation, stream, Stop and Cancel faults show an error and preserve available audio without completing a transcript. |
| HTTP failures | Actual URLSession requests/responses for 401, 429, 500, malformed, empty, refused, incomplete and disconnected responses; visible error controls, saved playable audio and no partial paste. |
| Saved recording | Upload/retry/cancel/copy through real controls; exact multipart audio byte count/SHA256, persisted error clearing and no late reply replacing live dictation. |
| Cleanup settings | Actual validation, Cancel, Save, relaunch persistence, Reset-then-Cancel, Reset-then-Save, and prompt/dictionary in the posted payload. |
| Speech settings | Apple default, missing-model validation, Download availability and Cancel preserving selection after relaunch. |
| Recognition switch | Cached model load and Nemotron Save through settings, persisted selection, clock-paced WAV through production conversion/recognition/cleanup/AAC/history/paste; switching to Apple during recording applies only to the next session. Silence closes a statement before capture ends. |
| External paste | Separate native editor app receives the exact text through production app activation and CGEvent Command-V; inspect text before restoring and comparing all clipboard representations. |
| Cross-app keys | Native shortcut capture, actual keyboard chord with another app focused, visible live text, then Escape from that app cancels and copies without saving. Direct Carbon dispatch is not substituted for keyboard delivery. |

Focused Swift tests retain coverage of pure parsing/context/UTF-16 logic,
asynchronous credential loading, storage failure policy and audio conversion.
They supplement these workflows. They do not claim hardware or desktop coverage.

## Interactive debug tools

```sh
./scripts/run-debug.sh
./scripts/chatty-debug --help
./scripts/chatty-debug fake hold
./scripts/chatty-debug start
./scripts/chatty-debug wait --phase listening
./scripts/chatty-debug inject --committed 'First sentence.' --partial 'live tail'
./scripts/chatty-debug wait --requests 1
./scripts/chatty-debug requests
./scripts/chatty-debug release
./scripts/chatty-debug stop
./scripts/chatty-debug wait --phase complete
```

`chatty-debug` is a Swift executable built by SwiftPM. The shell entry point only
locates it. JSON goes to stdout; errors are JSON on stderr with a nonzero exit.
Use `schema` for wait fields and `command --file FILE` for a full typed command
without shell escaping. Commands acknowledge acceptance; `wait` subscribes to app
events with a deadline. UI expectations use XCTest predicates. No scenario uses
fixed sleeps for synchronization; audio replay deliberately follows the audio clock.

`requests` returns 20 summaries by default (maximum 100). `--id` expands one
actual posted payload. Cleanup's HTTP fake returns the production encoder's
posted input in SCREAMING_SNAKE_CASE. Saved-audio uploads return a reference
transcript: that HTTP fake does not perform speech recognition. `ui settings
--show` opens the real window and reports labels/values/enabled states; `render
panel` and `render overlay` write PNGs of the app's own views.

The control file contains an ephemeral token and is mode 0600. Never commit or
share it. Every endpoint checks `X-Chatty-Debug-Token`. Debug storage must be
separate from production. Global shortcuts start disabled. `reset --clear-data`
removes only indexed debug recordings. The explicit `system-paste --target-bundle
ID` path stages the general clipboard; wait for `--paste-dispatches N`, inspect
the actual destination, then `restore-clipboard`. Dispatch alone does not prove
paste delivery. Clipboard contents stay in memory and are never returned by the API.

## Remaining external boundaries

File replay crosses conversion and recognition but bypasses Core Audio's actual
microphone input tap. Physical microphone acquisition, device/route changes,
first-run microphone allow/deny, room acoustics and Keychain trust still need a
separate lane. Live OpenAI authentication/output/latency and comparative ASR
accuracy are not established by local HTTP and synthetic audio fixtures.
The desktop keyboard test uses Control–Option–Command–9; default double-left-Shift
timing remains covered by focused NSEvent logic checks.

The user previously confirmed a physical Control–Option–Command–9 shortcut with
another app focused. That is independent evidence from the repeatable native
keyboard contract. See [macOS I/O research](macos-io-testing.md) for the proposed
virtual Core Audio input lane. No audio driver or virtual device is installed by
these checks. A real cold download/interruption/resume was verified during the
model integration; the ordinary UI suite deliberately reuses that cached model.
