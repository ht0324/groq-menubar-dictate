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

The mic dongle and Ting USB connection only need to be present for a physical
run. Before recording:

- install and launch the clean repository commit under `/Applications`;
- connect the `Cable Creation` input and the Ting USB serial device so
  `TINGDISK` is mounted;
- deploy the current v13 profile and marker assets; and
- enable the Ting audio trigger, raw dumps, and performance diagnostics.

Start with a three-squeeze smoke run. The positive expected count is required:

```bash
./ting/flightrec/record.sh v13-smoke 3
```

The recorder verifies the serial port is not already owned, the installed app
matches the clean repository commit, the connected audio input is present, and
the mounted firmware and marker assets match the tracked v13 files. It then
restarts the already-enabled app to create a session-owned raw WAV and proves
that the stream is growing before it prints `recording`. It never changes app
preferences or deploys firmware.

Keep every squeeze active for at least 0.5 seconds. After the expected final
capture finishes, press Control-C. The recorder closes and copies the bounded
WAV, restores the running app, and invokes the analyzer automatically. If more
than one `/dev/cu.usbmodem*` device is attached, select the Ting explicitly:

```bash
./ting/flightrec/record.sh --serial /dev/cu.usbmodemXXXX v13-smoke 3
```

Only after the smoke run passes should you record the full acceptance session:

```bash
./ting/flightrec/record.sh v13-acceptance 30
```

Each session stores app/repository/firmware provenance, configured trigger
settings, preflight results, serial telemetry, app logs, raw-WAV coverage, and
copied artifacts under `ting/flightrec/sessions/`.

Analyze a saved session with:

```bash
python3 ting/flightrec/analyze.py ting/flightrec/sessions/<session-name>
```

Acceptance requires exactly one complete marker-driven lifecycle per expected
squeeze:

```text
firmware START -> 6 kHz tone -> app START cause=marker
               -> firmware STOP -> 7 kHz tone -> app STOP cause=marker
               -> finalized capture
```

The run fails on count mismatches, missing or wrong firmware profiles, level
fallbacks, inactive stops, cancellations, phantom or unmatched events, unknown
WAV coverage, serial errors, failed recorder integrity, or missing streams.
