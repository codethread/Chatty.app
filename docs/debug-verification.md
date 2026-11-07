# Debug verification

Acceptance combines representative workflows in the running application with
variant coverage in faster logic and component-I/O tests. Keep the workflow
checks for each mechanism; test response, format and state variants below UI
once its wiring is established. The [verification map](verification.md#choose-the-lowest-layer-that-proves-the-behavior)
assigns each behavior to its layer and records unproved boundaries.
The native XCUITest bundle drives real AppKit controls in a separate process.
The authenticated harness API supplies fixtures/faults and observes state and
posted HTTP bytes. It also opens the shortcut-capture panel for the keyboard
contract. It does not click controls on the UI suite's behalf.

## Run the native suite

On an unlocked macOS 26 Apple Silicon Mac with full Xcode selected:

```sh
./scripts/check.sh
```

For a native-UI-only pass, use `./scripts/test-ui.sh`. The full gate above already
runs it; there is no need to run both for the same change.

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
those UI artifacts. A normal run is required after changing the app. For
UI-test-only changes, rebuild the runner separately before using `--no-build`;
this compiles the changed tests while preserving the unchanged app's grant:

```sh
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- xcodebuild build-for-testing \
  -project ChattyUITests.xcodeproj -scheme ChattyUITests \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/UITests
./scripts/check.sh --no-build
```

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

## Use focused tests during development

Run the smallest suite owning the changed behavior first. For example:

```sh
swift test -Xswiftc -DCHATTY_DEBUG_PANEL --filter DictationControllerTests
swift test -Xswiftc -DCHATTY_DEBUG_PANEL --filter MicrophoneCaptureTests
swift test -Xswiftc -DCHATTY_DEBUG_PANEL --filter CorrectionSettingsTests
```

The controller suite uses real loopback HTTP and temporary recording files with
scripted input and a presentation probe. It covers the HTTP/input failure
matrices without launching a desktop app. The capture suite runs AVFoundation
processing on supplied buffers; it does not acquire an input device. Pure
transcript/settings tests need neither recognizers nor models.

Focused tests need no CPU lock. Run full suites through `qlock` on
`/tmp/agent-cpu.lock`; `check.sh` and `test-ui.sh` already lock their expensive
commands. Use the complete gate for the finished change, including the native
audio and desktop contracts. A green focused run does not close hardware,
permissions or live-service gaps, and `--skip-audio` must remain explicit.

## Coverage

The [verification checklist](verification.md) is the coverage map for user
interactions, automated I/O, unit logic, manual checks and remaining gaps.
Use it when deciding what a change needs to verify. Exact assertions live in
[DictationUITests](../Tests/ChattyUITests/DictationUITests.swift) and
[ChattyTests](../Tests/ChattyTests).

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

## Further coverage

Manual checks and unverified boundaries are tracked in the
[verification checklist](verification.md). The proposed real-input-device lane is
in [macOS I/O testing research](macos-io-testing.md).
