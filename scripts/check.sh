#!/bin/bash
# Reproducible gate: Swift logic checks, signed archive, native UI workflows.
set -euo pipefail
cd "$(dirname "$0")/.."
for arg in "$@"; do
    case "$arg" in
        --skip-audio|--no-build) ;;
        *) echo 'Usage: scripts/check.sh [--skip-audio] [--no-build (UI artifacts only)]' >&2; exit 2 ;;
    esac
done
mkdir -p build/check-logs
trap 'echo "Check failed; inspect build/check-logs and build/ChattyUI-*.xcresult" >&2' ERR
for script in scripts/*.sh scripts/chatty-debug; do /bin/bash -n "$script"; done
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- swift build > build/check-logs/build.log 2>&1
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- swift test -Xswiftc -DCHATTY_DEBUG_PANEL > build/check-logs/tests.log 2>&1
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- ./scripts/package-release.sh 0.0.0 > build/check-logs/release.log 2>&1
archive_check="$(mktemp -d "$PWD/build/archive-check.XXXXXX")"
trap 'rm -rf "$archive_check"' EXIT
ditto -x -k build/Chatty-0.0.0-arm64.zip "$archive_check"
swift scripts/verify-release.swift "$archive_check/Chatty.app"
codesign --verify --strict "$archive_check/Chatty.app"
./scripts/test-ui.sh "$@"
