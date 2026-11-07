#!/usr/bin/env bash
# Package an already-built debug binary; never install, kill apps or reset TCC.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 2 || "$1" != /* || "$1" != *.app ]]; then
    echo 'Usage: scripts/package-debug.sh /absolute/path/Chatty.app bundle.identifier' >&2
    exit 2
fi
app="$1"
bundle_id="$2"
mkdir -p "$app/Contents/MacOS"
cp .build/debug/Chatty "$app/Contents/MacOS/Chatty"
cp Sources/Chatty/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Chatty Debug' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Chatty Debug' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSUIElement false' "$app/Contents/Info.plist"
codesign --force --sign - --identifier "$bundle_id" "$app"
codesign --verify --strict "$app"
