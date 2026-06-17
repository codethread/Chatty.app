# Chatty

Menu-bar-only macOS dictation helper.

## Features

- Runs as a menu bar app, not a normal Dock app.
- Double-tap **left Shift** to start recording from the default microphone.
- Double-tap **left Shift** again to stop, upload to OpenAI transcription, and copy the returned text to the clipboard.
- Bottom-center overlay shows recording, sound detection, transcription progress, success, and errors.
- OpenAI API key is saved in Keychain from the menu bar icon.

## Build

```nu
./scripts/build-app.nu
open build/Chatty.app
```

On first launch macOS will ask for:

- Microphone access
- Accessibility access, needed for the global double-left-shift shortcut

If the shortcut does not work, enable Chatty under **System Settings → Privacy & Security → Accessibility** and relaunch.

## Notes

This targets recent Apple Silicon macOS via Swift Package Manager/AppKit. No Apple Developer account is required for local unsigned builds. Distribution outside your machine may need signing/notarization.
