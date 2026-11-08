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

## Select the changed slice

Start with the lowest layer that detects the regression. Preview the selection
before building or requesting access:

```sh
./scripts/check.sh --list
./scripts/check.sh --filter 'TranscriptCorrectionsTests|DictationControllerTests'
./scripts/check.sh
```

The default runs shell/selector checks, `swift build`, and all Swift logic and
component-I/O tests. It launches no desktop app and needs no privacy grants,
live OpenAI key or model weights. Controller tests still exercise real loopback
HTTP and temporary recordings; supplied-buffer tests still run AVFoundation.

Add only the boundaries affected by the task:

| Change | Additional selection |
| --- | --- |
| AppKit controls/settings, overlay or app lifecycle wiring | `--with-ui`, or one relevant UI method with `--only` |
| Paste dispatch, target activation/focus or general clipboard | `--with-paste` |
| Global shortcut registration, capture or Escape handling | `--with-global-shortcuts` |
| Real recognizer inference/selection or recognition data flow | `--with-audio` |
| Production packaging, signing or debug exclusion | `--with-release` |
| Explicit full regression/release gate | `--all` |

For example, a cleanup change can run its focused Swift suites and one settings
workflow without exercising external paste or global shortcuts:

```sh
./scripts/check.sh --filter 'CorrectionSettingsTests|OpenAITranscriptCorrectorTests|DictationControllerTests'
./scripts/test-ui.sh --only testCleanupSettingsValidationCancelResetAndPayload
./scripts/check.sh --with-paste --with-global-shortcuts --list
./scripts/check.sh --all
```

Flags combine as a union, not a dependency chain: `--with-paste` adds the paste
workflow alone, not all other UI workflows. `test-ui.sh` without a selection
runs core AppKit workflows; with an explicit selection it runs only those
groups/methods. `--only` is repeatable and accepts a method name or full XCTest
identifier. `--all` runs the native target unfiltered and rejects narrowing with
`--only` or a Swift `--filter`. CLI `--help`/`--list` are the selector inventory.

Keep tests organized around behavior. The small native group catalogue lives in
`test-ui.sh`; update it when adding a workflow. The selector checks reject
unclassified workflows. Native `--all` supplies no `-only-testing` filter, keeping
the entire target in the full gate.
Selected permission/model failures fail the run. Excluded groups are unexecuted
coverage, not passes. An unchanged, unselected shortcut lane does not block
verification of cleanup; an explicitly required release check remains required.

### Framework filters and annotations

SwiftPM supports `swift test --filter REGEX`, `--skip REGEX`, and `swift test list`.
For a single focused run, invoke it directly with `-Xswiftc -DCHATTY_DEBUG_PANEL`.
Swift Testing also supports `@Tag` and `.tags(...)` across suites/files; tags can
be selected in Xcode test plans. The current fast suites are selectable by name,
so no extra tag hierarchy or folder reshuffle is needed.
[Apple tags documentation](https://developer.apple.com/documentation/Testing/AddingTags).

The native suite uses XCTest/XCUIAutomation, not Swift Testing. Its wrapper uses
Xcode's `-only-testing:target/suite/method`; `-skip-testing` and saved test plans
are available for lower-level/custom invocation. A Swift Testing tag does not
annotate an XCTest UI method.
[Apple test plans](https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback).

## Native execution and authorized artifacts

Read [permissions and prerequisites](permissions.md) before selecting desktop,
capture or live-service tests. Native checks require an unlocked macOS 26 Apple
Silicon desktop and full Xcode. Run them serially without other desktop
automation: focus, keyboard and clipboard are shared resources.

`test-ui.sh` builds/signs `build/Chatty UITest.app` and uses the Xcode UI runner
and owned paste-target app. Each workflow uses fresh isolated storage, quits only
its own app, and leaves production data alone. Core workflows use empty isolated
model caches. The explicit audio workflow uses the cached fixed Nemotron model;
provision Apple speech assets too, since missing assets may trigger Apple's
initial download. File replay does not cross the microphone-input boundary.

To retry unchanged authorized artifacts, add `--no-build`:

```sh
./scripts/test-ui.sh --with-paste --no-build
./scripts/check.sh --all --no-build
```

This preserves both signed app and runner and does not compile their changes.
`check.sh` still builds/runs Swift checks and any selected archive check. App
source changes require rebuilding the app before accepting UI evidence. For
UI-test-only edits, rebuild the runner separately to preserve the app's grant:

```sh
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- xcodebuild build-for-testing \
  -project ChattyUITests.xcodeproj -scheme ChattyUITests \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/UITests
./scripts/test-ui.sh --only testCleanupSettingsValidationCancelResetAndPayload --no-build
```

Focused Swift tests need no CPU lock. Full suites/builds use `qlock` on
`/tmp/agent-cpu.lock`; the wrappers already lock expensive commands. Logs live in
`build/check-logs/`; `build/ChattyUI-*.xcresult` bundles include results, final
state and failure screenshots. Test workspace paths in the attached state let
you inspect retained synthetic AAC/config/metadata. Record the selected slices
and result when updating the coverage map, including any blocked boundary.

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
