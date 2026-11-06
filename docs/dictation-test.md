# Repeatable dictation check

Use the same microphone, distance, and natural speaking pace each time. Start recording, read the passage below, then stop immediately after the last word. Skip the heading and instructions.

## Read aloud

This is a quick recording test for Chatty. I'm speaking at my normal office volume, with the microphone in its usual position. Please schedule the project review for Tuesday at nine thirty. We need fifteen notebooks, fifty pencils, and three hundred paper clips. Sarah checked the shipping address, while James updated the spreadsheet. The first version wasn't quite right, so we'll fix it before Friday. That's the end of this recording test.

## Compare runs

- Note the recording duration and displayed size just before stopping. Compare similar durations; live size can lag buffered writes.
- Check for missing or substituted words, especially fifteen versus fifty, names, and quiet words at the beginning or end. Punctuation and number formatting can vary.
- Note the wait between stopping and receiving the transcript. Network and service processing times vary, so one run isn't conclusive.
- For exact final file size, inspect the newest `.m4a` in `~/Library/Application Support/Chatty/Recordings/` after stopping.

The current target is 32 kbps mono AAC: roughly 240 KB per minute, plus container overhead. Silence still occupies space; this change lowers bitrate rather than removing pauses.
