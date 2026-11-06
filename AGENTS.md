# AGENTS.md

## Project

Chatty is a Swift/AppKit macOS menu-bar-only dictation app. It targets recent Apple Silicon macOS and is built with Swift Package Manager.

## User profile and design scope

- Single-user desktop tool used in a quiet office with little background noise; simple volume-based silence detection is an acceptable starting assumption.
- Prefer small, reliable implementations using native APIs and minimal dependencies over general-purpose audio processing.
- Silence trimming is intended to reduce upload payload size and upload time. Preserve speech over maximizing compression; handling noisy environments is outside the current scope.

## Build / install

```sh
./scripts/build-app.sh
```

The default installs a numbered debug app. Use `--no-debug` for real microphone input, and add `--no-build-id` for plain `/Applications/Chatty.app`. Production builds reset Microphone/Accessibility permissions by default. See [README build options](README.md#build) for combinations and the debug launcher.

After any code edit, run at least:

```nu
swift build
```

## Architecture

Read the [C4 architecture](docs/architecture.md) before changing component responsibilities, service interfaces, dependencies, or dictation data flow. Update it in the same change when those boundaries or runtime contracts change. Keep it lean: C1–C3 diagrams, key source links, and current contracts; replace stale details rather than accumulating history or duplicating code inventories here.

## Permissions

- Microphone: required for `AVAudioEngine` capture.
- Accessibility: required for the global modifier-key monitor.
- Avoid Input Monitoring unless reintroducing `CGEventTap`; listen-only event taps can trigger that broader permission.
- Apps cannot programmatically grant TCC permissions. `tccutil` is a macOS developer/admin CLI for resetting permission state only.
- Production startup requests Microphone/Accessibility. Sentence cleanup loads its key asynchronously on first use and caches it; macOS may request Keychain trust for a new build. Debug startup skips microphone and Accessibility prompts.

## Notes

- Prefer fail-loud behavior over silent fallbacks.
- Keep production menu-bar-only; the compile-time debug harness uses a regular floating control window.
- API keys belong in Keychain, not config files.
