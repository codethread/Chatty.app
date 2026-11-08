#!/bin/bash
# Exercise the public selection plans without building or touching the desktop.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "Test selection: $1" >&2; exit 1; }
equal() { [[ "$1" == "$2" ]] || fail "$3"; }
tests() { sed -n 's|^  ChattyUITests/DictationUITests/||p' | LC_ALL=C sort; }
usage_error() {
    local status script="$1"
    shift
    # Establish plan-only mode before malformed arguments, so a parser regression
    # cannot start builds or recursively invoke this verifier.
    if "$script" --list "$@" >/dev/null 2>&1; then
        fail "Expected usage error: $*"
    else
        status=$?
        equal "$status" 2 "Wrong exit status for $*"
    fi
}

paste=testExternalApplicationPasteAndClipboardRestoration
shortcuts=testCrossApplicationShortcutAndEscape
audio=testAudioEngineSwitchAppliesToNextSession
cleanup=testCleanupSettingsValidationCancelResetAndPayload
all_expected="$(sed -n 's/^[[:space:]]*func \(test[^ (]*\)().*/\1/p' Tests/ChattyUITests/DictationUITests.swift | LC_ALL=C sort)"
all_actual="$(./scripts/test-ui.sh --all --list | tests)"
equal "$all_actual" "$all_expected" 'Native catalogue differs from the workflow methods; classify new tests'
core_expected="$(echo "$all_expected" | grep -v -e "^$paste$" -e "^$shortcuts$" -e "^$audio$")"
equal "$(./scripts/test-ui.sh --list | tests)" "$core_expected" 'Default UI selection includes an unrelated boundary or omits core coverage'
equal "$(./scripts/test-ui.sh --with-ui --list | tests)" "$core_expected" 'Explicit core differs from default core'
equal "$(./scripts/test-ui.sh --with-paste --list | tests)" "$paste" 'Paste selects unrelated workflows'
equal "$(./scripts/test-ui.sh --with-global-shortcuts --list | tests)" "$shortcuts" 'Shortcuts select unrelated workflows'
equal "$(./scripts/test-ui.sh --with-audio --list | tests)" "$audio" 'Audio selects unrelated workflows'
pair="$(printf '%s\n' "$paste" "$shortcuts" | LC_ALL=C sort)"
equal "$(./scripts/test-ui.sh --with-paste --with-global-shortcuts --list | tests)" "$pair" 'Native groups do not combine as a union'
equal "$(./scripts/check.sh --with-paste --with-global-shortcuts --no-build --list | tests)" "$pair" 'Check wrapper changes native selection'
equal "$(./scripts/test-ui.sh --only "$cleanup" --list | tests)" "$cleanup" 'Single method selection is not focused'
equal "$(./scripts/test-ui.sh --only "ChattyUITests/DictationUITests/$cleanup" --list | tests)" "$cleanup" 'Full XCTest identifier selects differently'
equal "$(./scripts/test-ui.sh --with-ui --only "$cleanup" --list | tests)" "$core_expected" 'Duplicate selection runs a workflow twice'
equal "$(./scripts/test-ui.sh --only "$paste" --only "$shortcuts" --list | tests)" "$pair" 'Repeated --only loses a method'

headless="$(./scripts/check.sh --list)"
equal "$headless" $'Swift tests: all\nNative UI: none\nRelease archive: false' 'Default check requires UI or archive work'
focused="$(./scripts/check.sh --filter 'TranscriptCorrectionsTests|DictationControllerTests' --list)"
equal "$focused" $'Swift tests: TranscriptCorrectionsTests|DictationControllerTests\nNative UI: none\nRelease archive: false' 'Swift filter changes unrelated boundaries'
full="$(./scripts/check.sh --all --list)"
equal "$(echo "$full" | tests)" "$all_expected" 'Full gate omits native coverage'
[[ "$full" == *'Release archive: true'* ]] || fail 'Full gate omits archive validation'
equal "$(./scripts/check.sh --with-release --list)" $'Swift tests: all\nNative UI: none\nRelease archive: true' 'Archive checks require desktop UI'

usage_error ./scripts/test-ui.sh --only notATest
usage_error ./scripts/test-ui.sh --only
usage_error ./scripts/test-ui.sh --only --list
usage_error ./scripts/test-ui.sh --all --only "$paste"
usage_error ./scripts/test-ui.sh --unknown
usage_error ./scripts/check.sh --only notATest
usage_error ./scripts/check.sh --filter
usage_error ./scripts/check.sh --filter --list
usage_error ./scripts/check.sh --only --list
usage_error ./scripts/check.sh --all --filter TranscriptCorrectionsTests
usage_error ./scripts/check.sh --all --only "$paste"
usage_error ./scripts/check.sh --no-build
usage_error ./scripts/check.sh --unknown
echo 'Test selection: defaults, groups, exact methods, full coverage and errors verified'
