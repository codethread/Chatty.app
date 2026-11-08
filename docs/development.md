# Development

Build requirements: macOS 26 or later on Apple Silicon and Swift 6.2 or later.
The native UI tests additionally require full Xcode and an unlocked desktop.
For any code or test change, follow [the agent testing guide](testing.md).
See [architecture](architecture.md) for component boundaries and
[the harness reference](debug-verification.md) for native/debug operations.

## Build and install

To build the real menu-bar app with microphone input:

```sh
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- ./scripts/build-app.sh --no-debug
```

This installs and opens a numbered app such as `/Applications/Chatty 12.app`.
Each numbered build gets a unique bundle/signing identifier; the counter lives in
`~/Library/Application Support/Chatty/build-number`. Existing numbered bundles
remain installed. The installer stops running Chatty processes before replacing
and opening the requested build.

| Command suffix | Result |
| --- | --- |
| `--no-debug` | Numbered production app with microphone input. |
| No options | Numbered debug app with injected input and request diagnostics. |
| `--no-build-id` | Debug `/Applications/Chatty.app`, using the stable bundle ID. |
| `--no-debug --no-build-id` | Production `/Applications/Chatty.app`, using the stable bundle ID. |

`--no-build-id` replaces `Chatty.app` without advancing the counter.
`--no-open` installs without launching. Production installs reset Microphone and
Accessibility permissions; grant them again when prompted. Debug installs skip
that reset unless `--reset-permissions` is supplied. Permission details and
grant recovery live in [permissions](permissions.md).

## Debug panel

For development without installing into `/Applications`:

```sh
./scripts/run-debug.sh
```

This builds `CHATTY_DEBUG_PANEL`, packages `build/Chatty Debug.app` and opens its
floating control panel. It replaces only this checkout's debug app. Config,
recordings and artifacts live in `build/debug-data/`; the authenticated control
connection is recorded in `build/debug-control.json`. Installed debug builds
instead use `~/Library/Application Support/Chatty Debug/`.

The panel drives the same dictation, cleanup, recording and overlay components as
production. Choose a source and correction backend before starting:

| Source | Behavior |
| --- | --- |
| Injected transcript (default) | Supply stable and provisional text, then **Inject snapshot**. Stop saves a playable synthetic AAC recording. |
| Microphone · configured speech engine | Uses the recognizer selected in **Speech Recognition…**. |
| Explicit Nemotron / Apple microphone | Compare recognizers without changing the saved selection. **Prepare local model** downloads/loads the fixed local model. |
| Typed text | **Load sample → Stream text** supplies incremental text. |
| **Replay audio…** | Sends a local audio file through the configured recognizer in clock-paced packets, using the shared conversion, metering and AAC path. It does not play sound. End of file finishes automatically; Stop flushes supplied audio and Cancel discards it. |

Microphone modes request microphone permission on use. Startup microphone and
Accessibility prompts are skipped, and global shortcuts start disabled. Reopen
the panel with **Show Debug Panel…**, Command-0 or its Dock icon. The panel and
its menu item are excluded from builds without `CHATTY_DEBUG_PANEL`.

| Cleanup backend | Behavior |
| --- | --- |
| Local HTTP fake (default) | Receives actual serialized requests over loopback and transforms posted text into SCREAMING_SNAKE_CASE. Saved-audio uploads return a configurable reference transcript. No API key is needed. |
| Transcription only | Displays recognition without network cleanup. |
| OpenAI REST | Uses the production cleanup request and credentials. |
| Pi | CLI comparison backend for the production cleanup model. |

The debug launcher inherits `OPENAI_API_KEY` when set; otherwise live OpenAI uses
Keychain. Reads run off the UI thread and the key is cached in memory. A new build
may require Keychain trust. Keys are never passed as command arguments or logged.
The panel logs local partial/decode/flush timings and cleanup request stages,
status, input/output, errors and cancellation.

Debug uses a private clipboard and AppKit paste destination by default. External
paste, clipboard restoration, held replies, faults, saved-audio recovery and the
native Swift control CLI are covered in the
[interactive debug tools reference](debug-verification.md#interactive-debug-tools).

## Recognition benchmarks

The debug release binary can benchmark files without opening the UI or calling
sentence cleanup:

```sh
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- swift build -c release -Xswiftc -DCHATTY_DEBUG_PANEL
.build/release/Chatty --benchmark-asr --help
.build/release/Chatty --benchmark-asr nemotron sample.wav --realtime
.build/release/Chatty --benchmark-asr apple sample.wav --realtime
.build/release/Chatty --benchmark-asr parakeet sample.wav
```

Apple packet input requires 16 kHz mono audio. Parakeet is a batch accuracy
reference; Nemotron is the optional streaming backend. Model weights are cached
under `~/Library/Application Support/FluidAudio/Models/` and stay warm within the
app process after loading. See [local speech research](local-speech-research.md)
for measurements and their limits, and the
[read-aloud check](dictation-test.md) for repeatable manual comparisons.

## Recording diagnostics

Recording setup, microphone authorization, encoder failures and start/stop results
use macOS's unified log. Entries include recording paths and input format details,
not audio, transcripts or API keys. After reproducing a failure:

```sh
/usr/bin/log show --last 10m --style compact --predicate 'subsystem == "local.chatty.Chatty" AND category == "Recording"'
```
