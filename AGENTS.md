# AGENTS.md

## Project

Chatty is a Swift/AppKit macOS menu-bar-only dictation app. It targets recent Apple Silicon macOS and is built with Swift Package Manager.

## Verification — critical

**Before changing code, tests, verification scripts or testing guidance, read and follow [the agent testing guide](docs/testing.md).** State the affected behavior and verification plan before implementation; use its behavior-to-suite routing, selection flags and completion criteria. Update the plan when scope expands and record affected coverage in [verification](docs/verification.md).

## User profile and design scope

- Single-user desktop tool used in a quiet office with little background noise; simple volume-based silence detection is an acceptable starting assumption.
- Prefer small, reliable implementations using native APIs and minimal dependencies over general-purpose audio processing.
- Silence trimming is intended to reduce upload payload size and upload time. Preserve speech over maximizing compression; handling noisy environments is outside the current scope.

## Build / install

A **test build for the user** is the real menu-bar app with microphone input and an incremented build ID:

```sh
./scripts/build-app.sh --no-debug
```

This installs and opens `/Applications/Chatty <N>.app`. Open requested test builds by default; use `--no-open` only when the user asks to leave the build unopened.

When interactive typed-input debugging is needed, use `./scripts/run-debug.sh`. Provide a debug-panel build to the user only when explicitly requested. The build script's bare default enables that panel, so always pass `--no-debug` for user test builds.

Add `--no-build-id` only when the user requests plain `/Applications/Chatty.app`. Production builds reset Microphone/Accessibility permissions by default. See [build options](docs/development.md#build-and-install) for other combinations.

## Architecture

Read the [C4 architecture](docs/architecture.md) before changing component responsibilities, service interfaces, dependencies, or dictation data flow. Update it in the same change when those boundaries or runtime contracts change. Keep it lean: C1–C3 diagrams, key source links, and current contracts; replace stale details rather than accumulating history or duplicating code inventories here.

## Permissions

Before selected desktop, microphone or live-service checks, read [permissions and test prerequisites](docs/permissions.md) for the exact app's access and grant-recovery procedure.

## Notes

- Prefer fail-loud behavior over silent fallbacks.
- Keep production menu-bar-only; the compile-time debug harness uses a regular floating control window.
- API keys belong in Keychain, not config files.
