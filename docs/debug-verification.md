# Native test harness and debug tools

For test selection, required checks and reporting, start with
[the agent testing guide](testing.md). Read this reference when running a selected
native workflow, rebuilding its authorized artifacts or using interactive debug
tools. Access prerequisites and grant recovery live in [permissions](permissions.md).

The native XCUITest bundle drives real AppKit controls in a separate process.
The authenticated harness API supplies fixtures/faults and observes state and
posted HTTP bytes. It also opens the shortcut-capture panel for the keyboard
contract. It does not click controls on the UI suite's behalf.

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

Logs live in `build/check-logs/`; `build/ChattyUI-*.xcresult` bundles include results, final
state and failure screenshots. Test workspace paths in the attached state let
you inspect retained synthetic AAC/config/metadata.

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

## Framework filters and annotations

Use the wrappers for maintained selections. For a custom investigation, SwiftPM
also exposes `swift test list`, `--filter` and `--skip`; Swift Testing supports
`@Tag`/`.tags(...)` and tag selection in Xcode test plans. Native XCTest UI methods
use Xcode `-only-testing:target/suite/method`, `-skip-testing` or test plans, rather
than Swift Testing tags. Keep behavior-based suites and use selectors instead of
reorganizing files by permission needs.
[Apple tags](https://developer.apple.com/documentation/Testing/AddingTags),
[Apple test plans](https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback).
