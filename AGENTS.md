# AGENTS.md

## Project

Chatty is a Swift/AppKit macOS menu-bar-only dictation app. It targets recent Apple Silicon macOS and is built with Swift Package Manager.

## Build / install

```sh
./scripts/build-app.sh
```

This builds `build/Chatty.app`, quits any running Chatty process, replaces `/Applications/Chatty.app`, and opens it unless `--no-open` is passed. Use `--reset-permissions` to reset Chatty TCC permissions before replacing the installed app.

After any code edit, run at least:

```nu
swift build
```

## Architecture

- `Sources/Chatty/main.swift`
  - App entrypoint and `NSApplicationDelegate`.
  - Sets accessory/menu-bar mode, builds the status item menu, wires recording/shortcut/transcription flow.

- `Sources/Chatty/DoubleShiftShortcut.swift`
  - Global left-shift double-tap detector using `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)`.
  - Requires macOS Accessibility permission.

- `Sources/Chatty/AudioRecorder.swift`
  - Records default microphone input via `AVAudioRecorder` to a temporary `.m4a` file.
  - Emits debounced sound-level state for the overlay.
  - Requires Microphone permission.

- `Sources/Chatty/OpenAITranscriber.swift`
  - Multipart upload to OpenAI `/v1/audio/transcriptions` using `gpt-4o-transcribe`.
  - Returns trimmed transcript text.

- `Sources/Chatty/KeychainStore.swift`
  - Stores/loads the OpenAI API key from macOS Keychain.

- `Sources/Chatty/OverlayWindowController.swift`
  - Floating bottom-center non-activating overlay.
  - Shows recording, sound detected, transcribing, success, and error states.

- `Sources/Chatty/Settings.swift`
  - Small constants for shortcut timing and meter behavior.

- `Sources/Chatty/Info.plist`
  - App bundle metadata, `LSUIElement`, and microphone usage description.

## Flow

Double left Shift starts recording. Double left Shift again stops recording, shows processing, uploads audio to OpenAI, copies the transcript to the clipboard, shows success, then closes the overlay. Errors stay visible until replaced or the app quits.

## Permissions

- Microphone: required for `AVAudioRecorder`.
- Accessibility: required for the global modifier-key monitor.
- Avoid Input Monitoring unless reintroducing `CGEventTap`; listen-only event taps can trigger that broader permission.
- Apps cannot programmatically grant TCC permissions. `tccutil` is a macOS developer/admin CLI for resetting permission state only.
- `runInitialSetup()` prompts early for Microphone/Accessibility and reads Keychain once so any Keychain trust prompt happens at startup. If no API key exists, it opens the API-key dialog.

## Notes

- Prefer fail-loud behavior over silent fallbacks.
- Keep this app menu-bar-only; do not add a Dock/main-window app model unless explicitly requested.
- API keys belong in Keychain, not config files.
