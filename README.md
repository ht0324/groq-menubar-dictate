# groq-menubar-dictate

Minimal macOS menu bar dictation app using Groq transcription.

## Behavior

- Option key only (no click required):
  - Tap Option once -> start recording
  - Tap Option again -> stop, transcribe, copy, auto-paste
  - Press Escape while recording -> abort recording (discard, no transcription, Esc is consumed)
- Custom words are appended to the Groq prompt for better spelling.
- Filter words remove case-insensitive chunks:
  - `word `, `word, `, `word. `, `word.`
- End-prune rules remove trailing spaces and trailing signoffs:
  - `thank you`, `thank you for watching`, `thanks for watching` (case-insensitive, optional period)
- Menu bar click is only for settings/status, not for recording control.

## Features

- Native AppKit menu bar app (`NSStatusBar`, accessory app)
- Audio capture (`AVAudioRecorder`) to temporary `.m4a`
- Groq API transcription (`/openai/v1/audio/transcriptions`)
- Custom words prompt loaded from:
  - `~/Library/Application Support/groq-menubar-dictate/custom-words.txt`
- Filter words loaded from:
  - `~/Library/Application Support/groq-menubar-dictate/filter-words.txt`
- End prune phrases loaded from:
  - `~/Library/Application Support/groq-menubar-dictate/end-prune-phrases.txt`
- Clipboard copy + optional Cmd+V auto-paste
- API key stored in app settings (`UserDefaults`)

## Requirements

- macOS 13+
- Swift 6.2+
- Groq API key

## Run

```bash
swift run
```

## Install to /Applications

```bash
./scripts/install_to_applications.sh
open -a "/Applications/Groq MenuBar Dictate.app"
```

## Test

```bash
swift test
```

## Permissions

The app may require:

- Microphone access (recording)
- Input Monitoring (global Option key detection)
- Post keyboard events permission (auto-paste event injection)

Use menu item `Test Permissions` to prompt/check status.
If auto-paste or Escape abort is unavailable, grant Input Monitoring / Post Keyboard Events when prompted.

## Notes

- API key is configured in `Open Settings`.
- Startup behavior is configurable in `Open Settings` via `Launch at login`.
- End-prune behavior is configurable in `Open Settings` via `Prune transcript ending phrases`.
- If auto-paste permission is missing, transcript is still copied to clipboard.
- App is single-instance protected. Launching it again will not create another active instance.
