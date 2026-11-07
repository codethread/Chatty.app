# Audio fixture

`statements-with-pauses.wav` is generated speech, not a microphone recording.
It uses macOS's Daniel voice at 165 words/minute, 16 kHz mono PCM, with 1.6 seconds
of digital silence after each statement:

1. This is a statement without a question
2. Now I am starting another topic

The fixture verifies streaming recognition, pause punctuation, continuation,
recording conversion, cleanup payloads and saved audio without physical microphone
input. Expected normalized text:
`THIS_IS_A_STATEMENT_WITHOUT_A_QUESTION_NOW_I_AM_STARTING_ANOTHER_TOPIC`.
