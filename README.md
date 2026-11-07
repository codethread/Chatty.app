# Chatty

Menu-bar-only macOS dictation helper.

## Features

- Runs as a menu bar app, not a normal Dock app.
- Double-tap **left Shift** to start recording from the default microphone.
- See live on-device transcription in a scrolling bottom-center overlay.
- Complete sentences are tidied with recent transcript context through OpenAI's Responses API using `gpt-5.4-mini` with reasoning disabled; blue marks the passage currently being corrected, yellow marks queued speech, and green marks corrected text.
- The overlay grows from one line to five wrapped lines, then scrolls older text upward. Its waveform follows your microphone level.
- Double-tap **left Shift** again to finalize, save the recording and transcript, copy and paste the text into the original app, and clear the overlay.
- Press **Escape** while recording to copy the currently visible text and clear the overlay, canceling pending cleanup and discarding the unsaved audio.
- Bottom-center overlay shows recording, sound detection, transcription progress, success, and errors.
- Full error text opens in a separate selectable error window.
- Set your OpenAI API key from the menu bar icon; it is saved in Keychain and used for sentence cleanup and retranscribing saved audio.

## Install with Homebrew

Tap this repository, then install Chatty:

```sh
brew tap codethread/chatty https://github.com/codethread/Chatty.app
brew install --cask codethread/chatty/chatty
```

The cask installs `/Applications/Chatty.app` and the `chatty` command. If you
installed the old formula, first remove it with `brew uninstall --formula chatty`.
Launch Chatty from Applications or with `open -a Chatty`.

The release is ad-hoc signed, not notarized. If macOS blocks its first launch,
allow it in **System Settings → Privacy & Security → Open Anyway**.
The app prompts for Microphone and Accessibility access
on first launch. Speech recognition uses Apple's on-device model, which downloads
on first use if it is not already installed. Sentence cleanup uses the OpenAI
API key saved in Chatty's Keychain entry.

To update after the cask is updated:

```sh
brew update
brew upgrade --cask codethread/chatty/chatty
```

## Build

```sh
./scripts/build-app.sh
```

The default builds a **debug harness with an incremental ID**, such as
`/Applications/Chatty 6.app`, with a unique bundle and signing identifier.
The counter is `~/Library/Application Support/Chatty/build-number`. Existing
numbered bundles remain installed; running Chatty processes are stopped before
the new build opens.

| Command | Result |
| --- | --- |
| `./scripts/build-app.sh` | Numbered debug app with typed input and request diagnostics. |
| `./scripts/build-app.sh --no-debug` | Numbered production app with real microphone input. |
| `./scripts/build-app.sh --no-build-id` | Debug app named `Chatty.app`, with the stable bundle ID. |
| `./scripts/build-app.sh --no-debug --no-build-id` | Production `/Applications/Chatty.app`, with the stable bundle ID. |

`--no-build-id` replaces `Chatty.app` and leaves the counter unchanged.
Production builds reset Microphone and Accessibility permissions by default;
grant access again when prompted. Debug builds skip the reset unless
`--reset-permissions` is supplied. `--no-open` installs without launching.

```sh
./scripts/build-app.sh --no-debug --no-build-id --no-open
./scripts/build-app.sh --reset-permissions
```

Debug builds compile `CHATTY_DEBUG_PANEL` and open a floating control panel,
available again through **Show Debug Panel…**, Command-0, or the Dock icon.
The panel drives the same `DictationController` and overlay as production.
Choose a **Speech recognition source**:

- **Injected transcript · synthetic recording** (default) accepts stable text and
  a separate provisional tail. **Inject snapshot** emits them through the real
  input stream. Stop saves a playable synthetic AAC recording.
- **Microphone · Nemotron 600M · 560 ms** uses a local quantized Core ML
  model through FluidAudio. **Prepare local model** downloads about 626 MB once
  and loads it into memory. Prepare before speaking; initial Core ML preparation
  can take several seconds. Weights stay loaded between sessions. Models live in
  `~/Library/Application Support/FluidAudio/Models/nemotron-streaming/560ms/`.
  A pause of about one second closes the sentence with a full stop and keeps
  listening. Existing question/exclamation marks are preserved; shorter pauses
  stay within the same utterance. Stop also punctuates the final statement.
- **Microphone · Apple SpeechAnalyzer** uses the production recognizer for comparison.
- **Typed text** enables the text editor and **Load sample → Stream text**.
- **Replay audio…** selects a local audio file and sends it through Nemotron in
  clock-paced 80 ms packets. The overlay updates during playback, then finalizes
  and copies the transcript automatically. File packets use the microphone's
  resampling, level metering and AAC recording path. This does not play sound.
  Stop flushes supplied audio; Cancel discards the recording.

Microphone modes request microphone permission on first use and save recordings
on Stop. Cancel copies visible text and discards unsaved audio. Both clear the
overlay. The demo uses a private clipboard and a real AppKit test paste window.
Debug builds skip startup microphone and Accessibility prompts. Global shortcuts
start disabled; enable them explicitly with the debug CLI when testing them.

Choose a **Correction backend** in the debug panel:

- **Local HTTP fake · SCREAMING_SNAKE_CASE** (default) receives the actual
  serialized OpenAI request on loopback and transforms its posted text. Saved
  audio uploads use a configurable reference transcript. No API token is needed.
- **Transcription only** displays recognition without network cleanup.
- **OpenAI REST** runs the same direct `gpt-5.4-mini` request as production,
  using your saved OpenAI API key. **Set API key…** replaces it in Keychain.
- **Pi** uses the same mini model without reasoning for timing comparisons.

The log shows local partial transcripts, decode time and final flush time. For
network cleanup it shows credential loading, sending, elapsed time, HTTP status,
actual service tier, request ID, input, output, errors, and cancellation. The activity timer keeps
running while a request is pending. Credentials are never logged. A macOS
Keychain trust prompt can delay credential loading; approve access for the debug
app if prompted. Reads happen off the UI thread and the key is cached in memory
for subsequent requests. Cancelling also interrupts the wait for credentials.

The local-recognition experiment and measurements are documented in
[Local speech research](docs/local-speech-research.md). The release demo also has
a file benchmark that emits JSON lines without opening the UI or calling cleanup:

```sh
qlock exec --lock /tmp/agent-cpu.lock -w 60 -- swift build -c release -Xswiftc -DCHATTY_DEBUG_PANEL
.build/release/Chatty --benchmark-asr --help
.build/release/Chatty --benchmark-asr nemotron sample.wav --realtime
.build/release/Chatty --benchmark-asr apple sample.wav --realtime
.build/release/Chatty --benchmark-asr parakeet sample.wav
```

The Apple packet benchmark requires 16 kHz mono input. Parakeet is a batch
accuracy reference; Nemotron is the local streaming backend in the demo.

Corrections run one request at a time while new speech keeps streaming. After
each reply, the next request combines recent corrected text with all newly
completed speech. Edits invalidate cleanup of revised source text, and Stop also
submits the last unfinished fragment before completing the session.

The panel uses AppKit's floating-window accessibility subrole so tiling window
managers such as AeroSpace can recognize it as a floating utility window.

The panel and its menu item are excluded from builds without the flag, including
ordinary Swift debug builds. To run it directly during development:

```sh
./scripts/run-debug.sh
```

The launcher reuses this checkout's `build/Chatty Debug.app` without installing a
production app or incrementing its build number. Config and recordings live in
`build/debug-data/`; the authenticated control connection is recorded in
`build/debug-control.json`. Installed debug builds use the separate
`~/Library/Application Support/Chatty Debug/` directory. It inherits `OPENAI_API_KEY` when already set
in your shell; otherwise the app uses Keychain. The key is kept in memory and
is never passed in command arguments or written to debug logs.

The panel exposes HTTP failures, held replies, input failures, request payloads,
saved-recording retry/cancel/copy, and the settings window. The CLI drives the
same running controllers and can operate actual AppKit controls by label:

```sh
python3 scripts/chatty-debug.py --help
python3 scripts/chatty-debug.py start
python3 scripts/chatty-debug.py wait --phase listening
python3 scripts/chatty-debug.py inject --committed 'A complete sentence.' --partial 'live words'
python3 scripts/chatty-debug.py stop
python3 scripts/chatty-debug.py wait --phase complete
./scripts/check.sh
```

`check.sh` runs locked Swift checks, a signed production archive build, and 27
scenarios in its own signed debug app and sandbox. It includes local-model audio
replay; `--skip-audio` omits the model-dependent scenarios. It writes a JSON report
and own-view PNG artifacts, quits only its app, and leaves user builds alone.
See [debug verification](docs/debug-verification.md) for evidence, commands and
external testing boundaries.

Production first launch front-loads setup:

- Microphone access
- Accessibility access, needed for the global double-left-shift shortcut

If the shortcut does not work, enable Chatty under **System Settings → Privacy & Security → Accessibility** and relaunch.

## Sentence cleanup

Normal builds call `POST https://api.openai.com/v1/responses` directly using
`gpt-5.4-mini`, `reasoning.effort: none`, low verbosity, `store: false`, and
Fast processing (`service_tier: priority`, which has premium per-token pricing).
Each passage gets the configured instructions and dictionary. A shared
URLSession reuses connections; Keychain is read off the UI thread once and the
credential is cached in memory. Saving a new API key updates the cache.
Pi is only a comparison option in the debug panel.

Open **Sentence Cleanup…** to edit the cleanup instructions, **Context lines**,
and word dictionary. Context defaults to the last **three wrapped transcript
lines**, using the overlay's font and width and expanding back to a complete
sentence. All new completed speech is included, even if it exceeds that window.
Older corrected text stays fixed. Replies can revise the recent passage using
spoken retries and spelled-out clarifications; no correction metadata is learned
or saved automatically.

Enter one dictionary mapping per line, for example:

```text
jason = JSON
open ai = OpenAI
```

Mappings are passed to the model with each passage, matching recognized words
or phrases case-insensitively while retaining the preferred capitalization.
Settings persist in `~/Library/Application Support/Chatty/config.json`; saved
changes apply to subsequent correction requests. Reset to Defaults changes the
editor's fields; Save applies them.

Only completed, stable recognized sentences are submitted during dictation.
Stopping flushes the remaining text and waits for corrections before saving and
pasting. A failed cleanup is shown as an error and prevents an incomplete paste;
the original audio remains saved for recovery.
Cancel cancels the active HTTP request and rejects late output; aborting an old
correction does not cancel a replacement batch or a new recording.

## Comparing recording quality

Use the [repeatable read-aloud check](docs/dictation-test.md) to compare transcription accuracy, recording size, and turnaround time after audio-setting changes.

## Recording diagnostics

Recording setup, microphone authorization, encoder errors, and start/stop results are logged to macOS's unified log. These logs include the audio input name and recording path, but not audio, transcripts, or API keys.

After reproducing a failure, inspect recent entries:

```sh
/usr/bin/log show --last 10m --style compact --predicate 'subsystem == "local.chatty.Chatty" AND category == "Recording"'
```

## Notes

See the [C4 architecture](docs/architecture.md) for system boundaries, components,
and the dictation lifecycle.

This requires macOS 26 or later on Apple Silicon. Building from source also
requires Swift 6.2 or later. Live dictation uses `SpeechAnalyzer` and
`SpeechTranscriber`; unsupported locales or unavailable models produce a visible error. No Apple Developer account is
required for local unsigned builds. Distribution outside your machine may need
signing/notarization.
