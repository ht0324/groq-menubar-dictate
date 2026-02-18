# groq-menubar-dictate

Super-fast, lightweight macOS menu bar dictation using Groq transcription.
Bare-bones by design: tap Option, speak, and get text. It just works.

## Behavior

- Option key only (no click required):
  - Tap Option once -> start recording
  - Tap Option again -> stop, transcribe, copy, auto-paste
  - Press Escape while recording -> abort recording (discard, no transcription, Esc is consumed)
- Option trigger key can be configured in Settings:
  - `Any Option key`
  - `Left Option key only`
  - `Right Option key only`
- Custom words are appended to the Groq prompt for better spelling.
- Filter words remove case-insensitive chunks:
  - `word `, `word, `, `word. `, `word.`
- End-prune rules remove trailing spaces and trailing signoffs:
  - `thank you`, `thank you for watching`, `thanks for watching` (case-insensitive, optional period)
- Menu bar click is only for settings/status, not for recording control.

## Performance Snapshot (MacBook M1 Pro)

- CPU: mostly `0.0%`, peak `1.0%`
- Memory (`top MEM`): about `23 MB`
- Memory (`ps RSS`): `64000 KB` (about `62.5 MB`, `%MEM 0.4`)
- Designed to stay lean during idle + short dictation bursts.
- In day-to-day use, this stays far lighter than heavier desktop transcription apps that can reach around `300 MB+`.

## Features

- Native AppKit menu bar app (`NSStatusBar`, accessory app)
- Audio capture (`AVAudioRecorder`) to temporary `.m4a`
- Microphone input mode:
  - `Automatic (system default)`
  - `Always use this Mac's built-in microphone`
- Groq API transcription (`/openai/v1/audio/transcriptions`)
- Latency-focused flow:
  - Stop recording on Option key-down while recording
  - In-memory multipart upload prep (no extra temp upload file)
- Option key trigger mode:
  - `Any` / `Left` / `Right`
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

### Stable Code Signing (Recommended)

To keep macOS permissions (Input Monitoring / Post Events / Microphone) stable across updates, install with a stable signing identity instead of ad-hoc signing.

List available identities:

```bash
security find-identity -v -p codesigning
```

Install with an explicit identity (preferred):

```bash
GROQ_DICTATE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/install_to_applications.sh
```

Optional hint-based identity matching (for example by email):

```bash
GROQ_DICTATE_SIGN_IDENTITY_HINT="huntae324@gmail.com" ./scripts/install_to_applications.sh
```

Ad-hoc signing fallback (not recommended, may reset permissions on every update):

```bash
GROQ_DICTATE_ALLOW_ADHOC=1 ./scripts/install_to_applications.sh
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

- Prioritizes speed and simplicity over complex UI/feature bloat.
- API key is configured in `Open Settings`.
- Startup behavior is configurable in `Open Settings` via `Launch at login`.
- End-prune behavior is configurable in `Open Settings` via `Prune transcript ending phrases`.
- Microphone mode is configurable in `Open Settings` via `Microphone input`.
- Option key trigger mode is configurable in `Open Settings` via `Option key`.
- In built-in mic mode, the app temporarily sets macOS default input to the internal microphone during recording and restores the previous input when recording stops.
- If auto-paste permission is missing, transcript is still copied to clipboard.
- App is single-instance protected. Launching it again will not create another active instance.
