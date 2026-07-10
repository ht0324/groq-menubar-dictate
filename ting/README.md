# Ting EP-2350 integration

This directory contains the local firmware, marker assets, simulation harness,
and flight-recorder tooling used by the Ting auto-record experiment.

## Active files

- `main_tingdisk.py` is the TINGDISK `main.py` override. It loads `user.py`
  from the device volume and preserves the stock Ting behavior around it.
- `user.py` is the current v13 lever-driven profile. It emits a 6 kHz start
  marker on a full squeeze and a 7 kHz stop marker on release. The deployer
  selects this profile by default.
- `user_v12.py` is the retained stop-only profile. It emits only the release
  marker and relies on Mac-side level detection to start capture. The deployer
  exposes it as the `stop-only` profile without changing either source file.
- `marker_start.wav` and `marker_stop.wav` are deployed with every profile and
  loaded from TINGDISK by the firmware.

Historical source copies are kept in Git history instead of alongside the
active profiles.

## Validate

Run the desktop harness before deploying firmware changes:

```bash
python3 ting/harness/run_all.py
python3 ting/flightrec/test_analyze.py
```

Run the Swift detector and integration tests from the repository root:

```bash
swift test
```

## Deploy

With TINGDISK mounted, deploy the current `user.py` profile and marker assets:

```bash
./ting/deploy.sh
```

Select the retained stop-only profile explicitly:

```bash
./ting/deploy.sh --profile stop-only
```

Deploy the `main.py` override as well after changing `main_tingdisk.py`. The
options are combinable and may appear in either order:

```bash
./ting/deploy.sh --main
./ting/deploy.sh --profile stop-only --main
```

Run `./ting/deploy.sh --help` for the complete command summary. The `--main`
path requires a Ting power cycle. A profile-only deployment ejects TINGDISK to
hot-reload the selected source as the device's `user.py`. Delete `main.py` from
TINGDISK to return to the stock frozen firmware.

## Record an acceptance run

Enable the Ting audio trigger and raw dumps, restart the app, and connect the
Ting USB serial device. Then record a named session with an optional expected
squeeze count:

```bash
./ting/flightrec/record.sh v13-acceptance 30
```

The recorder stores the app build, repository state, firmware hashes, trigger
settings, serial telemetry, app logs, and captured WAV paths in the session
metadata. Generated sessions remain local under `ting/flightrec/sessions/`.

Analyze a saved session with:

```bash
python3 ting/flightrec/analyze.py ting/flightrec/sessions/<session-name>
```

The analyzer currently proves the release path: an acceptance run should have
no broken stop chains, no phantom stop tones, no unexplained level fallbacks,
and an observed firmware-stop count matching the expected squeeze count. It
reports 6 kHz start-tone counts separately; for the current profile, also
confirm that count matches the expected squeezes.
