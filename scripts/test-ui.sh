#!/bin/bash
# Requires an unlocked macOS desktop and Xcode's UI Automation authorization.
set -euo pipefail
cd "$(dirname "$0")/.."
skip_audio=false
no_build=false
for arg in "$@"; do
    case "$arg" in
        --skip-audio) skip_audio=true ;;
        --no-build) no_build=true ;;
        *) echo 'Usage: scripts/test-ui.sh [--skip-audio] [--no-build]' >&2; exit 2 ;;
    esac
done
mkdir -p build/check-logs
operation=test
if $no_build; then
    operation=test-without-building
    echo 'Reusing the previously built test app and UI bundle; code changes require a new build.'
else
    qlock exec --lock /tmp/agent-cpu.lock -w 60 -- swift build -Xswiftc -DCHATTY_DEBUG_PANEL > build/check-logs/ui-app-build.log 2>&1
    ./scripts/package-debug.sh "$PWD/build/Chatty UITest.app" local.chatty.Chatty.uitest
fi
result="$PWD/build/ChattyUI-$(date +%Y%m%d-%H%M%S).xcresult"
args=(-parallel-testing-enabled NO)
if $skip_audio; then
    echo 'Audio recognition contracts explicitly excluded (--skip-audio).'
    args+=(-skip-testing:ChattyUITests/DictationUITests/testAudioEngineSwitchAppliesToNextSession)
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
