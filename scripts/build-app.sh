#!/usr/bin/env bash
set -euo pipefail

no_open=false
reset_permissions=false

usage() {
    cat <<'EOF'
Usage: scripts/build-app.sh [--no-open] [--reset-permissions]

Options:
  --no-open            Install without launching Chatty after copy
  --reset-permissions  Reset Chatty TCC permissions before replacing the installed app
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

bundle_id="local.chatty.Chatty"
app="build/Chatty.app"
installed="/Applications/Chatty.app"

swift build -c release

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp ".build/release/Chatty" "$app/Contents/MacOS/Chatty"
cp "Sources/Chatty/Info.plist" "$app/Contents/Info.plist"
echo "Built $app"

# Ignore failure when Chatty is not running.
pkill Chatty 2>/dev/null || true

# tccutil is a macOS CLI, not part of Swift. Reset before deleting the installed
# bundle; macOS resolves bundle IDs against apps that still exist on disk.
if [[ "$reset_permissions" == true && -e "$installed" ]]; then
    for service in Microphone Accessibility ListenEvent; do
        if tccutil reset "$service" "$bundle_id"; then
            echo "Reset $service permission for $bundle_id"
        fi
    done
fi

rm -rf "$installed"
cp -R "$app" /Applications/
echo "Installed $installed"

if [[ "$no_open" != true ]]; then
    open "$installed"
    echo "Opened $installed"
fi
