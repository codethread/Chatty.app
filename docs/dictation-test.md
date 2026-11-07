# Repeatable dictation check

Use the same microphone, distance, and natural speaking pace each time. Start recording, read the passage below, then stop immediately after the last word. Skip the heading and instructions.

## Read aloud

This is a quick recording test for Chatty. I'm speaking at my normal office volume, with the microphone in its usual position. I'm working on a Swift app that uses AppKit, async await, and local speech recognition through Apple or Nemotron.

Have a look at docs slash verification dot M D. Then open sources slash Chatty slash Microphone Dictation Service dot Swift. Check the AV Audio Engine tap, the sample rate, and the mono A A C recording. Keep model inference off the main actor, and make sure cancelling an async task doesn't overwrite a newer session.

The cleanup request goes through URL Session to the OpenAI API. Send the transcript as JSON, keep the API key in Keychain, and handle HTTP four oh one, four twenty-nine, and five hundred. We need to distinguish fifteen requests from fifty requests. Use camel case for Swift properties and snake case for JSON keys. Pass nil rather than an empty string.

Add the regression test in tests slash Chatty Tests slash Dictation Controller Tests dot Swift, then run swift test. For a manual build, run dot slash scripts slash build dash app dot S H, with dash dash no dash debug. The saved audio should be under tilde slash Library slash Application Support slash Chatty slash Recordings. Check the git diff before pushing to codex slash local dash speech dash settings. That's the end of this recording test.

## Compare runs

- Note the recording duration and displayed size just before stopping. Compare similar durations; live size can lag buffered writes.
- Check for missing or substituted words, especially fifteen versus fifty, programming terms, and quiet words at the beginning or end. Punctuation and number formatting can vary.
- Check identifiers and paths against the references below. Note dropped path components, confused file extensions, or missing hyphens in command flags. Record capitalization and spoken-separator formatting separately from word recognition errors.
- Note the wait between stopping and receiving the transcript. Network and service processing times vary, so one run isn't conclusive.
- For exact final file size, inspect the newest `.m4a` in `~/Library/Application Support/Chatty/Recordings/` after stopping.

The current target is 32 kbps mono AAC: roughly 240 KB per minute, plus container overhead. Silence still occupies space.

## Written references — do not read aloud

- Terms: `Swift`, `AppKit`, `async/await`, `Nemotron`, `AVAudioEngine`, `MainActor`, `AAC`, `URLSession`, `OpenAI`, `API`, `JSON`, `Keychain`, `HTTP`, `nil`, camelCase, snake_case.
- Files: `docs/verification.md`, `Sources/Chatty/MicrophoneDictationService.swift`, `Tests/ChattyTests/DictationControllerTests.swift`.
- Commands: `swift test`, `./scripts/build-app.sh --no-debug`, `git diff`.
- Directory: `~/Library/Application Support/Chatty/Recordings/`.
- Branch: `codex/local-speech-settings`.
