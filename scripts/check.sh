#!/usr/bin/env bash
# Reproducible gate: tests, signed production archive, then isolated AppKit flows.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --skip-audio ) ]]; then
    echo 'Usage: scripts/check.sh [--skip-audio]' >&2
    exit 2
fi
mkdir -p build/check-logs
trap 'echo "Check failed; inspect build/check-logs and build/check-verification.json" >&2' ERR
for script in scripts/*.sh; do bash -n "$script"; done
python3 -m py_compile scripts/chatty-debug.py scripts/verify-debug.py
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- swift build > build/check-logs/build.log 2>&1
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- swift test -Xswiftc -DCHATTY_DEBUG_PANEL > build/check-logs/tests.log 2>&1
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- ./scripts/package-release.sh 0.0.0 > build/check-logs/release.log 2>&1
python3 - <<'PYTHON'
from pathlib import Path
import plistlib
import zipfile
with zipfile.ZipFile('build/Chatty-0.0.0-arm64.zip') as archive:
    info = plistlib.loads(archive.read('Chatty.app/Contents/Info.plist'))
    assert info['LSUIElement'] is True
    assert info['CFBundleIdentifier'] == 'local.chatty.Chatty'
    binary = archive.read('Chatty.app/Contents/MacOS/Chatty')
    assert b'CHATTY_HARNESS_READY' not in binary
    assert b'chatty-local-fake' not in binary
PYTHON
# Release and debug have separate outputs. Re-establish the exact debug flags
# before packaging, so the verifier never accidentally starts a production app.
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- swift build -Xswiftc -DCHATTY_DEBUG_PANEL > build/check-logs/debug-build.log 2>&1
args=(--launch --report "$PWD/build/check-verification.json")
if [[ $# -eq 0 ]]; then args+=(--audio); fi
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- python3 scripts/verify-debug.py "${args[@]}"
