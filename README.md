# Chatty

A macOS menu-bar dictation app with live on-device transcription, sentence cleanup
through OpenAI, and paste into the app you were using. Requires macOS 26 or later
on Apple Silicon.

## Install

```sh
brew tap codethread/chatty https://github.com/codethread/Chatty.app
brew install --cask codethread/chatty/chatty
open -a Chatty
```

Homebrew installs `/Applications/Chatty.app` and the `chatty` command. The app is
ad-hoc signed, not notarized. If macOS blocks its first launch, allow it in
**System Settings → Privacy & Security → Open Anyway**.

To update:

```sh
brew update
brew upgrade --cask codethread/chatty/chatty
```

## First launch

1. Grant **Microphone** and **Accessibility** access when prompted.
2. Open the 🎙️ menu and choose **Set OpenAI API Key…**. The key is saved in Keychain.
3. Focus the app where you want to insert text.

Chatty stays in the menu bar rather than the Dock. Apple speech recognition is
the default; macOS downloads its speech assets on first use if needed. Both
recognition options run locally, but sentence cleanup requires the OpenAI API.

## Dictate

| Action | Result |
| --- | --- |
| Double-tap **left Shift** | Start recording and see live words in the overlay. |
| Double-tap **left Shift** again | Finish cleanup, save audio and transcript, copy and paste into the original app. |
| Press **Escape** | Copy the visible text, cancel pending cleanup and discard the unsaved audio. |

The overlay marks active cleanup in blue, queued speech in yellow and corrected
text in green. Stop waits for outstanding cleanup before pasting. Errors prevent
an incomplete paste; available audio is kept for recovery.

Use **Set Recording Shortcut…** in the menu to choose another key combination.

## Speech recognition

Open **Speech Recognition…** to switch between:

- **Apple · built in** — the default on-device recognizer.
- **Nemotron 600M · local streaming** — an optional English model. Click
  **Download Model** (approximately 626 MB), wait for readiness, select Nemotron
  and **Save**. Pause for about a second to end a statement while keeping the
  recording open.

Changes apply to the next recording. The current recording keeps its original
recognizer. You can switch back to Apple in the same window.

## Sentence cleanup

Open **Sentence Cleanup…** to change the instructions, recent context size and
word dictionary sent to OpenAI. Context defaults to three wrapped lines of
previously corrected text, plus all newly completed speech. Preferred spellings use one
mapping per line:

```text
jason = JSON
open ai = OpenAI
```

**Save** applies changes to subsequent cleanup requests. **Reset to Defaults**
changes the editor's fields; save to apply them. Chatty does not learn dictionary
entries automatically.

Address spoken editing requests to “the tape” or “the transcription”, for example
“for the tape, remove the last two sentences”. Cleanup can rewrite or delete
multiple sentences in the supplied passage. Older text outside the context
window stays fixed. If you delete the entire passage, you can keep dictating;
stopping with no text left saves the recording without copying or pasting.

## Recordings and privacy

The **Recordings** menu lets you open saved audio, copy transcripts and recover
failed transcriptions with **Transcribe Now** or **Try Again**. **Set Transcription
Vocabulary…** supplies names or terms for those saved-audio requests.

Live speech recognition runs on your Mac. Completed transcript passages, cleanup
instructions and the dictionary are sent to OpenAI for cleanup. Choosing to
transcribe a saved recording uploads its audio to OpenAI.

Config, saved audio and transcripts live in
`~/Library/Application Support/Chatty/`. Recordings older than five days are
removed when Chatty starts.

## Troubleshooting

If the recording shortcut fails, enable Chatty in **System Settings → Privacy &
Security → Accessibility**, then relaunch. Use **Show Last Error…** for full error
text. [Recording diagnostics](docs/development.md#recording-diagnostics) explains
how to collect audio setup logs.

## Further reading

- [Repeatable recording-quality check](docs/dictation-test.md)
- [Building from source and development tools](docs/development.md)
- [Verification checklist](docs/verification.md)
- [Architecture](docs/architecture.md)
