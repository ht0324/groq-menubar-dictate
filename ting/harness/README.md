# Ting Desktop Harness

This directory contains a pure-Python desktop harness for the tracked EP-2350
Ting `main_tingdisk.py` override and its deployable `user.py` profiles. The
locally extracted stock firmware remains an optional ignored reference; the
test suite does not depend on it.

## Usage

Run all harness tests from the repository root:

```sh
python3 ting/harness/run_all.py
```

The runner discovers `test_*.py`, prints the normal `unittest` output, then
prints a short PASS/FAIL summary and exits nonzero on failure.

## Mock Architecture

`tingmock.TingSim` execs the firmware source in an isolated globals dictionary
while injecting desktop modules under the bare names the firmware imports:

- `ui`: records `leds(...)`, stores the registered `callback(...)`, and exposes
  settable switch state through `sw(index)`.
- `spl`: records `trigger(...)`, `load_wav(...)`, and `rom(...)`.
- `fx`: records every called `fx.*` function as a no-op.

The simulator also supplies minimal `vfs` and `rp2` modules while callbacks are
running so the preserved USB remount path can be tested.
`TingSim.message(type, val)` builds firmware callback integers, and helpers such
as `press`, `release`, `tick`, `set_switch`, and `inject_message` drive scripted
sequences.

`test_main_tingdisk.py` verifies the tracked main override, including its boot
signature and the preserved sample/preset behavior. `test_user_v13.py` covers
the current start+stop profile, while `test_user_v12.py` protects the retained
stop-only profile.

## Marker Tools

`markers.py` generates 16-bit mono PCM marker bursts with a 5 ms raised-cosine
attack and release. It can write standalone WAV files or additively mix a marker
into an existing `array('h')` buffer with PCM clipping protection.

`goertzel.py` implements a streaming two-frequency Goertzel detector. It works
in short blocks, compares each target frequency's normalized Goertzel energy
against the total block energy, and uses debounce plus release hysteresis before
reporting start/stop detections with sample-index timestamps.

## Capture Format And Frequency Recommendation

The Ting-specific Mac capture path is `AudioActivityCaptureService`: it pins the
Cable Creation input device into an `AVAudioEngine`, converts input to 16,000 Hz
mono PCM16, and writes final clips as WAV files. `AudioRecorderService` is the
older generic recorder path; it tries 16 kHz AAC first, then 22.05 kHz and
44.1 kHz fallbacks.

The Mac-side detector profile targets the actual Ting capture format:

- start marker: 6,000 Hz
- stop marker: 7,000 Hz
- sample rate: 16,000 Hz
- burst length: 30 ms

This pair sits above dominant speech energy, has 1 kHz spacing for simple
classification, and leaves 1 kHz of margin below the 8 kHz Nyquist limit after
the Mac-side resample. The tracked device WAVs use 48 kHz containers for Ting
playback but contain the same 6/7 kHz tones. The harness also tests a separate
48 kHz lab profile at 17,800/18,800 Hz for higher-rate capture experiments.
