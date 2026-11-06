#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

qlock exec --lock /tmp/agent-cpu.lock -w 60 -- swift build -Xswiftc -DCHATTY_DEBUG_PANEL

# Only replace the debug app. Production installs and build numbers are untouched.
swift -e 'import AppKit; for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "local.chatty.Chatty.debug" { app.terminate() }'
app="$PWD/build/Chatty Debug.app"
mkdir -p "$app/Contents/MacOS"
cp .build/debug/Chatty "$app/Contents/MacOS/Chatty"
cp Sources/Chatty/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.chatty.Chatty.debug' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Chatty Debug' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Chatty Debug' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSUIElement false' "$app/Contents/Info.plist"
codesign --force --sign - --identifier local.chatty.Chatty.debug "$app"
codesign --verify --strict "$app"

# Launch directly to inherit OPENAI_API_KEY when supplied by the calling shell.
# Never place credentials in command arguments, files, or log output.
exec "$app/Contents/MacOS/Chatty"
