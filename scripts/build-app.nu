#!/usr/bin/env nu

def main [
    --no-open # Install without launching Chatty after copy
    --reset-permissions # Reset Chatty TCC permissions before replacing the installed app
] {
    let bundle_id = "local.chatty.Chatty"
    let app = "build/Chatty.app"
    let installed = "/Applications/Chatty.app"

    swift build -c release

    rm -rf $app
    mkdir ($app | path join "Contents/MacOS")
    cp .build/release/Chatty ($app | path join "Contents/MacOS/Chatty")
    cp Sources/Chatty/Info.plist ($app | path join "Contents/Info.plist")
    print $"Built ($app)"

    # Ignore failure when Chatty is not running.
    try { pkill Chatty }

    # tccutil is a macOS CLI, not part of Swift. Reset before deleting the installed
    # bundle; macOS resolves bundle IDs against apps that still exist on disk.
    if $reset_permissions and ($installed | path exists) {
        for service in [Microphone Accessibility ListenEvent] {
            try {
                tccutil reset $service $bundle_id
                print $"Reset ($service) permission for ($bundle_id)"
            }
        }
    }

    rm -rf $installed
    cp -r $app /Applications/
    print $"Installed ($installed)"

    if not $no_open {
        ^open $installed
        print $"Opened ($installed)"
    }
}
