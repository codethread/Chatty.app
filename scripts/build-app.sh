#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

no_open=false
reset_permissions=false
debug_panel=true
with_build_id=true

usage() {
    cat <<'EOF'
Usage: scripts/build-app.sh [--no-debug] [--no-build-id] [--no-open] [--reset-permissions]

Default: build and install a numbered app with the debug panel.

Options:
  --no-debug           Build the menu-bar app with real microphone input; reset TCC permissions
  --no-build-id        Use Chatty.app and its stable bundle ID without advancing the counter
  --no-open            Install without launching Chatty after copy
  --reset-permissions  Also reset Microphone/Accessibility permissions for debug builds
  -h, --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-open)
            no_open=true
            shift
            ;;
        --reset-permissions)
            reset_permissions=true
            shift
            ;;
        --no-debug)
            debug_panel=false
            shift
            ;;
        --no-build-id)
            with_build_id=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

app_name="Chatty"
bundle_id="local.chatty.Chatty"
if [[ "$with_build_id" == true ]]; then
    state_dir="$HOME/Library/Application Support/Chatty"
    counter_file="$state_dir/build-number"
    previous_number=0
    if [[ -f "$counter_file" ]]; then
        previous_number="$(cat "$counter_file")"
    fi
    if [[ ! "$previous_number" =~ ^[0-9]+$ ]]; then
        echo "Invalid build number in $counter_file" >&2
        exit 1
    fi
    build_number=$((10#$previous_number + 1))
    app_name="Chatty $build_number"
    bundle_id="local.chatty.Chatty.build$build_number"
fi
app="build/$app_name.app"
installed="/Applications/$app_name.app"
if [[ "$with_build_id" == true && ( -e "$app" || -e "$installed" ) ]]; then
    echo "Build $build_number already exists; check $counter_file" >&2
    exit 1
fi

build_flags=(-c release)
if [[ "$debug_panel" == true ]]; then
    build_flags+=(-Xswiftc -DCHATTY_DEBUG_PANEL)
fi
swift build "${build_flags[@]}"

if [[ "$with_build_id" == true ]]; then
    mkdir -p "$state_dir"
    printf '%s\n' "$build_number" > "$counter_file"
fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp ".build/release/Chatty" "$app/Contents/MacOS/Chatty"
cp "Sources/Chatty/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$app/Contents/Info.plist"
if [[ "$with_build_id" == true ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
fi
if [[ "$debug_panel" == true ]]; then
    /usr/libexec/PlistBuddy -c 'Set :LSUIElement false' "$app/Contents/Info.plist"
fi
if [[ "$debug_panel" == false ]]; then
    reset_permissions=true
fi
codesign --force --sign - --identifier "$bundle_id" "$app"
codesign --verify --strict "$app"
echo "Built $app"

# Ignore failure when Chatty is not running.
pkill -x Chatty 2>/dev/null || true

rm -rf "$installed"
cp -R "$app" "$installed"
echo "Installed $installed (bundle ID: $bundle_id)"

# tccutil needs the app bundle to exist when resolving its bundle identifier.
if [[ "$reset_permissions" == true ]]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$installed"
    for service in Microphone Accessibility; do
        tccutil reset "$service" "$bundle_id"
        echo "Reset $service permission for $bundle_id"
    done
fi

if [[ "$no_open" != true ]]; then
    open "$installed"
    echo "Opened $installed"
fi
