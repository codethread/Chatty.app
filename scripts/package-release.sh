#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: scripts/package-release.sh <major.minor.patch>" >&2
    exit 2
fi
version="$1"

swift build -c release --arch arm64
bin_dir="$(swift build -c release --arch arm64 --show-bin-path)"

mkdir -p build
staging="$(mktemp -d "$PWD/build/release.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Chatty.app"
archive="$PWD/build/Chatty-$version-arm64.zip"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/Chatty" "$app/Contents/MacOS/Chatty"
cp Sources/Chatty/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"
codesign --force --sign - --identifier local.chatty.Chatty "$app"
codesign --verify --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
shasum -a 256 "$archive"
