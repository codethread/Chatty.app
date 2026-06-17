#!/usr/bin/env nu

swift build -c release
let app = "build/Chatty.app"
rm -rf $app
mkdir ($app | path join "Contents/MacOS")
cp .build/release/Chatty ($app | path join "Contents/MacOS/Chatty")
cp Sources/Chatty/Info.plist ($app | path join "Contents/Info.plist")
print $"Built ($app)"
