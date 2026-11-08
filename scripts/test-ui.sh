#!/bin/bash
# Native workflow selection. Selected tests still require an unlocked desktop.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    cat <<'EOF'
Usage: scripts/test-ui.sh [selection] [--no-build] [--list]

With no selection, run core AppKit workflows using injected speech and loopback
HTTP. They need UI Automation, but no microphone, live key or downloaded model.
Selection flags combine; an explicit selection runs only the requested groups.

  --with-ui                Core AppKit workflows (settings, lifecycle, history)
  --with-paste             External-app paste and clipboard restoration
  --with-global-shortcuts  Cross-app shortcut capture, delivery and Escape
  --with-audio             Both real recognizers using cached models/file replay
  --only TEST              One method name or full XCTest identifier; repeatable
  --all                    Every native test, without a test filter
  --no-build               Reuse existing app/runner; does not compile changes
  --list                   Print selection without building or launching
  -h, --help               Show this help

Examples:
  scripts/test-ui.sh --only testCleanupSettingsValidationCancelResetAndPayload
  scripts/test-ui.sh --with-paste --with-global-shortcuts --no-build
  scripts/test-ui.sh --all --list

Missing permissions/models fail selected tests. Unselected groups are not passes.
Scope: docs/testing.md. Access: docs/permissions.md.
Native setup and artifact reuse: docs/debug-verification.md.
EOF
}

fail() { echo "$1" >&2; exit 2; }
core=false; paste=false; shortcuts=false; audio=false; all=false
explicit=false; no_build=false; list=false
only=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-ui) core=true; explicit=true ;;
        --with-paste) paste=true; explicit=true ;;
        --with-global-shortcuts) shortcuts=true; explicit=true ;;
        --with-audio) audio=true; explicit=true ;;
        --all) all=true; explicit=true ;;
        --only)
            [[ $# -gt 1 && -n "$2" && "$2" != --* ]] || fail '--only requires a test method name or identifier'
            only+=("${2#ChattyUITests/DictationUITests/}")
            explicit=true
            shift
            ;;
        --no-build) no_build=true ;;
        --list) list=true ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1 (see --help)" ;;
    esac
    shift
done
$explicit || core=true
if $all; then
    [[ ${#only[@]} -eq 0 ]] || fail '--all cannot be combined with --only'
    core=true; paste=true; shortcuts=true; audio=true
fi

# Classify new workflows here. --all still runs the unfiltered Xcode target;
# the selector verifier rejects unclassified workflows.
core_tests=(
    testStreamingQueueStopAndPersistence
    testCancelHeldReplyAndRestart
    testPreparationCancelAndStopFailure
    testCleanupFailureKeepsAudioAndNeverPastesPartialText
    testSavedRecordingUploadRetryCancelAndCopy
    testCleanupSettingsValidationCancelResetAndPayload
    testSpeechSettingsDefaultCancelAndMissingModel
)
paste_tests=(testExternalApplicationPasteAndClipboardRestoration)
shortcut_tests=(testCrossApplicationShortcutAndEscape)
audio_tests=(testAudioEngineSwitchAppliesToNextSession)
known=("${core_tests[@]}" "${paste_tests[@]}" "${shortcut_tests[@]}" "${audio_tests[@]}")
selected=()
add_test() {
    local existing
    if [[ ${#selected[@]} -gt 0 ]]; then
        for existing in "${selected[@]}"; do
            [[ "$existing" != "$1" ]] || return 0
        done
    fi
    selected+=("$1")
}
if [[ ${#only[@]} -gt 0 ]]; then
    for test in "${only[@]}"; do
        found=false
        for candidate in "${known[@]}"; do
            if [[ "$test" == "$candidate" ]]; then found=true; break; fi
        done
        $found || fail "Unknown test: $test (use --all --list for method names)"
    done
fi
if $core; then for test in "${core_tests[@]}"; do add_test "$test"; done; fi
if $paste; then for test in "${paste_tests[@]}"; do add_test "$test"; done; fi
if $shortcuts; then for test in "${shortcut_tests[@]}"; do add_test "$test"; done; fi
if $audio; then for test in "${audio_tests[@]}"; do add_test "$test"; done; fi
if [[ ${#only[@]} -gt 0 ]]; then
    for test in "${only[@]}"; do add_test "$test"; done
fi

if $all; then
    echo 'Native UI: all tests in ChattyUITests (unfiltered); current catalogue:'
else
    echo "Native UI: ${#selected[@]} selected workflows; all other workflows excluded:"
fi
for test in "${selected[@]}"; do echo "  ChattyUITests/DictationUITests/$test"; done
if $no_build; then echo 'UI artifacts: reuse existing signed app and runner'; fi
$list && exit 0

mkdir -p build/check-logs
operation=test
if $no_build; then
    operation=test-without-building
else
    qlock exec --lock /tmp/agent-cpu.lock -w 60 -- swift build -Xswiftc -DCHATTY_DEBUG_PANEL > build/check-logs/ui-app-build.log 2>&1
    ./scripts/package-debug.sh "$PWD/build/Chatty UITest.app" local.chatty.Chatty.uitest
fi
result="$PWD/build/ChattyUI-$(date +%Y%m%d-%H%M%S)-$$.xcresult"
args=(-parallel-testing-enabled NO)
if ! $all; then
    for test in "${selected[@]}"; do args+=("-only-testing:ChattyUITests/DictationUITests/$test"); done
fi
echo "XCUITest results: $result"
status=0
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- xcodebuild "$operation" \
    -project ChattyUITests.xcodeproj -scheme ChattyUITests \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build/UITests \
    -resultBundlePath "$result" \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 180 \
    -maximum-test-execution-time-allowance 240 "${args[@]}" \
    > build/check-logs/ui-tests.log 2>&1 || status=$?
if [[ -d "$result" ]]; then
    xcrun xcresulttool get test-results summary --path "$result" --format json
fi
exit "$status"
