#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

export CHATTY_DEBUG_DIRECTORY="$PWD/build/debug-data"
export CHATTY_DEBUG_CONTROL_FILE="$PWD/build/debug-control.json"

qlock exec --lock /tmp/agent-cpu.lock -w 60 -- swift build -Xswiftc -DCHATTY_DEBUG_PANEL

# Replace only this checkout's debug bundle. Other worktrees and user builds stay running.
app="$PWD/build/Chatty Debug.app"
CHATTY_DEBUG_BUNDLE="$app" swift -e 'import AppKit; import Foundation; let path = ProcessInfo.processInfo.environment["CHATTY_DEBUG_BUNDLE"]!; for app in NSWorkspace.shared.runningApplications where app.bundleURL?.path == path { app.terminate() }'
./scripts/package-debug.sh "$app" local.chatty.Chatty.debug

# Launch directly to inherit OPENAI_API_KEY when supplied by the calling shell.
# Never place credentials in command arguments, files, or log output.
exec "$app/Contents/MacOS/Chatty"
