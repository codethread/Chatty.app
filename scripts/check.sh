#!/bin/bash
# Headless checks by default; add the I/O boundaries changed by the task.
set -euo pipefail
cd "$(dirname "$0")/.."
usage() {
    cat <<'EOF'
Usage: scripts/check.sh [selection] [--no-build] [--list]

Default: shell syntax, Swift build, and all Swift logic/component-I/O tests.
No desktop UI, microphone, live OpenAI key or downloaded model is required.

  --filter REGEX           Focus Swift tests by suite/method name
  --with-ui                Add core AppKit workflows (fake speech/HTTP)
  --with-paste             Add external paste/clipboard workflow
  --with-global-shortcuts  Add cross-app shortcut/Escape workflow
  --with-audio             Add cached-model/file-replay recognizer workflow
  --only TEST              Add one native UI method; repeatable
  --with-release           Add signed production archive validation
  --all                    Full Swift, native UI/audio/desktop and archive gate
  --no-build               Reuse UI app/runner only; Swift checks still build
  --list                   Print selection without building or launching
  -h, --help               Show this help

Examples:
  scripts/check.sh --filter 'TranscriptCorrectionsTests|DictationControllerTests'
  scripts/check.sh --with-paste --with-global-shortcuts --no-build
  scripts/check.sh --all --list

Choose tests from the changed behavior; follow docs/testing.md.
Run scripts/test-ui.sh directly for UI-only work. Selected failures fail the run;
excluded boundaries are not claimed as verified. Permissions: docs/permissions.md.
EOF
}

fail() { echo "$1" >&2; exit 2; }
native=false; release=false; all=false; no_build=false; list=false
filter=''
native_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --filter)
            [[ $# -gt 1 && -n "$2" && "$2" != --* ]] || fail '--filter requires a Swift test name regular expression'
            filter="$2"; shift
            ;;
        --with-ui|--with-paste|--with-global-shortcuts|--with-audio)
            native=true; native_args+=("$1")
            ;;
        --only)
            [[ $# -gt 1 && -n "$2" && "$2" != --* ]] || fail '--only requires a native UI test method name or identifier'
            native=true; native_args+=("$1" "$2"); shift
            ;;
        --with-release) release=true ;;
        --all) all=true; native=true; release=true; native_args+=(--all) ;;
        --no-build) no_build=true; native_args+=(--no-build) ;;
        --list) list=true ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1 (see --help)" ;;
    esac
    shift
done
if $all && [[ -n "$filter" ]]; then fail '--all cannot be combined with --filter'; fi
if $no_build && ! $native; then fail '--no-build requires a native UI selection'; fi
native_plan='Native UI: none'
if $native; then native_plan="$(./scripts/test-ui.sh "${native_args[@]}" --list)"; fi
echo "Swift tests: ${filter:-all}"
echo "$native_plan"
echo "Release archive: $release"
$list && exit 0

mkdir -p build/check-logs
trap 'echo "Check failed; inspect build/check-logs and build/ChattyUI-*.xcresult" >&2' ERR
for script in scripts/*.sh scripts/chatty-debug; do /bin/bash -n "$script"; done
./scripts/verify-test-selection.sh
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- swift build > build/check-logs/build.log 2>&1
test_args=(-Xswiftc -DCHATTY_DEBUG_PANEL)
if [[ -n "$filter" ]]; then test_args+=(--filter "$filter"); fi
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- swift test "${test_args[@]}" > build/check-logs/tests.log 2>&1
tail -n 3 build/check-logs/tests.log
if $release; then
    qlock exec --lock /tmp/agent-cpu.lock -w 60 -- ./scripts/package-release.sh 0.0.0 > build/check-logs/release.log 2>&1
    archive_check="$(mktemp -d "$PWD/build/archive-check.XXXXXX")"
    trap 'rm -rf "$archive_check"' EXIT
    ditto -x -k build/Chatty-0.0.0-arm64.zip "$archive_check"
    swift scripts/verify-release.swift "$archive_check/Chatty.app"
    codesign --verify --strict "$archive_check/Chatty.app"
fi
if $native; then ./scripts/test-ui.sh "${native_args[@]}"; fi
