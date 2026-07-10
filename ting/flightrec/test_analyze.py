#!/usr/bin/env python3
"""Standalone tests for the Ting flight recorder analyzer."""

from __future__ import annotations

import contextlib
import io
import json
import math
import random
import sys
import tempfile
import unittest
from array import array
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True

FLIGHTREC_DIR = Path(__file__).resolve().parent
TING_DIR = FLIGHTREC_DIR.parent
HARNESS_DIR = TING_DIR / "harness"
for path in (str(FLIGHTREC_DIR), str(HARNESS_DIR)):
    if path not in sys.path:
        sys.path.insert(0, path)

import analyze  # noqa: E402
from markers import render_marker, write_pcm16_wav  # noqa: E402


SAMPLE_RATE = 16_000
START_FREQUENCY = 6_000
STOP_FREQUENCY = 7_000
BASE_TIME = datetime(2026, 7, 7, 21, 26, 3, 123456, tzinfo=timezone.utc).timestamp()
UNSET = object()


class AnalyzeFlightRecorderTests(unittest.TestCase):
    def test_complete_marker_chains_pass_with_serial_printing_after_tones(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, firmware_pairs=[(1.0, 2.0), (3.0, 4.2)])

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 0, output)
            self.assertIn("acceptance: PASS", output)
            self.assertIn("clean full capture chains: 2", output)
            self.assertIn("count mismatches: 0", output)
            self.assertIn("recorder metadata: PASS", output)
            self.assertIn("invalid firmware profiles: 0", output)

    def test_finished_recorder_metadata_is_valid_for_reanalysis(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir)
            update_meta(session_dir, status="finished")

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 0, output)
            self.assertIn("acceptance: PASS", output)
            self.assertIn("recorder metadata: PASS", output)

    def test_missing_firmware_profile_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, firmware_profiles=[None, None])

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("profile=missing", output)
            self.assertIn("invalid firmware profiles: 2", output)
            self.assertIn("acceptance: FAIL", output)

    def test_wrong_firmware_profile_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, firmware_profiles=["v12", "v12"])

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("profile=v12", output)
            self.assertIn("invalid firmware profiles: 2", output)
            self.assertIn("acceptance: FAIL", output)

    def test_mixed_firmware_profiles_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, firmware_profiles=["v13", "v12"])

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("firmware stop profile=v12 (expected v13)", output)
            self.assertIn("invalid firmware profiles: 1", output)
            self.assertIn("acceptance: FAIL", output)

    def test_app_marker_event_before_tone_beyond_anchor_uncertainty_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, app_starts=[(0.50, "marker")])

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("BROKEN app activity start missing", output)
            self.assertIn("acceptance: FAIL", output)

    def test_app_marker_event_within_anchor_uncertainty_can_match_tone(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, app_starts=[(0.65, "marker")])

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 0, output)
            self.assertIn("acceptance: PASS", output)

    def test_finalization_after_next_app_start_cannot_cross_capture_boundary(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(
                session_dir,
                firmware_pairs=[(1.0, 2.0), (2.05, 3.0)],
                finalized=[2.02, 2.97],
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("finalized capture missing before next app START", output)
            self.assertIn("ANOMALY unmatched finalized capture", output)
            self.assertIn("acceptance: FAIL", output)

    def test_failed_preflight_metadata_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir)
            meta = read_meta(session_dir)
            meta["preflight"]["serial"]["result"] = "fail"
            write_meta(session_dir, meta)

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("preflight checks not passed: serial", output)
            self.assertIn("recorder metadata: FAIL", output)
            self.assertIn("acceptance: FAIL", output)

    def test_failed_artifact_integrity_metadata_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir)
            update_meta(
                session_dir,
                artifact_integrity={
                    "result": "fail",
                    "errors": ["active raw WAV did not grow during the capture interval"],
                },
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("artifact_integrity must report pass with no errors", output)
            self.assertIn("recorder metadata: FAIL", output)
            self.assertIn("acceptance: FAIL", output)

    def test_termination_completion_reason_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir)
            update_meta(session_dir, completion_reason="termination_signal")

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("completion_reason must be user_interrupt", output)
            self.assertIn("recorder metadata: FAIL", output)

    def test_failed_recorder_status_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir)
            update_meta(session_dir, status="artifact_failed")

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("status must be captured or finished", output)
            self.assertIn("recorder metadata: FAIL", output)

    def test_non_object_meta_json_fails_without_crashing(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir)
            (session_dir / "meta.json").write_text("[]", encoding="utf-8")

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("meta.json must contain a JSON object", output)
            self.assertIn("recorder metadata: FAIL", output)

    def test_non_object_app_log_record_fails_without_crashing(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir)
            app_log_path = session_dir / "app-log.ndjson"
            app_log_path.write_text("42\n" + app_log_path.read_text(encoding="utf-8"), encoding="utf-8")

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("ndjson record must contain a JSON object: 42", output)
            self.assertIn("unknown events: 1", output)
            self.assertIn("acceptance: FAIL", output)

    def test_missing_expected_count_cannot_false_green_empty_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(
                session_dir,
                firmware_pairs=[],
                expected_squeezes=None,
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("ANOMALY positive expected squeeze count required", output)
            self.assertIn("expected squeezes: missing or non-positive", output)
            self.assertIn("acceptance: FAIL", output)

    def test_zero_expected_count_is_not_an_acceptance_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(
                session_dir,
                firmware_pairs=[],
                expected_squeezes=0,
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("positive expected_squeezes is required", output)

    def test_stop_only_session_is_inactive_and_cannot_false_green(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(
                session_dir,
                firmware_pairs=[],
                firmware_markers=[("stop", 2.0)],
                stop_tones=[1.92],
                app_stops=[(1.96, "marker")],
                finalized=[1.97],
                expected_squeezes=1,
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("ANOMALY inactive firmware STOP without START", output)
            self.assertIn("inactive-capture stops: 1", output)
            self.assertIn("acceptance: FAIL", output)

    def test_missing_start_tone_breaks_otherwise_complete_stop_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, start_tones=[])

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("BROKEN start tone never reached audio", output)
            self.assertIn("clean full capture chains: 0", output)

    def test_phantom_start_tone_is_anomaly(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, start_tones=[0.92, 2.55])

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("ANOMALY phantom/unmatched START tone", output)
            self.assertIn("phantom/unmatched tones: 1", output)

    def test_start_without_explicit_marker_cause_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, app_starts=[(0.96, None)])

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("ANOMALY activity start cause=missing", output)
            self.assertIn("non-marker or missing app causes: 1", output)

    def test_level_caused_stop_fails_even_when_near_stop_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, app_stops=[(1.96, "level")])

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("ANOMALY activity stop cause=level", output)
            self.assertIn("acceptance: FAIL", output)

    def test_cancelled_capture_fails_and_makes_stop_inactive(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, cancellations=[1.50])

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("ANOMALY capture cancelled", output)
            self.assertIn("capture inactive before stop", output)
            self.assertIn("capture cancellations: 1", output)

    def test_missing_finalized_capture_breaks_chain(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, finalized=[])

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("finalized capture missing", output)
            self.assertIn("count mismatches: 1", output)

    def test_fatal_serial_error_fails_an_otherwise_clean_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, serial_errors=[(2.30, "SERIAL_EOF device disappeared")])

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("ANOMALY fatal serial error", output)
            self.assertIn("fatal serial errors: 1", output)

    def test_marker_outside_raw_wav_coverage_is_unknown_and_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(
                session_dir,
                wav_start_offset=3.0,
                wav_duration_seconds=2.0,
                start_tones=[3.20],
                stop_tones=[4.00],
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("UNKNOWN outside raw WAV coverage", output)
            self.assertIn("outside-WAV-coverage unknowns: 2", output)

    def test_missing_wav_stream_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, missing_wav=True)

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("MISSING WAV", output)
            self.assertIn("missing/absent streams: 1", output)

    def test_expected_count_mismatch_reports_every_short_layer(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, expected_squeezes=2)

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("ANOMALY expected squeeze count mismatch", output)
            self.assertIn("firmware START=1", output)
            self.assertIn("finalized capture=1", output)

    def test_unmatched_app_event_fails_even_with_one_clean_chain(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(
                session_dir,
                app_starts=[(0.96, "marker"), (2.60, "level")],
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("ANOMALY unmatched app activity-start cause=level", output)
            self.assertIn("unmatched app activity events: 1", output)

    def test_crossed_start_and_stop_stages_cannot_pass_by_proximity(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(
                session_dir,
                app_starts=[(1.94, "marker")],
                app_stops=[(1.96, "marker")],
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("START/STOP lifecycle stages crossed", output)
            self.assertIn("acceptance: FAIL", output)

    def test_missing_serial_and_app_log_streams_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, missing_serial=True, missing_app_log=True)

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("missing serial.log", output)
            self.assertIn("missing app-log.ndjson", output)
            self.assertIn("missing/absent streams: 3", output)

    def test_unmatched_finalized_capture_is_anomaly(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(session_dir, finalized=[1.97, 3.00])

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("ANOMALY unmatched finalized capture", output)
            self.assertIn("unmatched finalized captures: 1", output)


def run_analyzer(session_dir):
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        status = analyze.main([str(session_dir)])
    return status, output.getvalue()


def build_session(
    session_dir,
    firmware_pairs=UNSET,
    firmware_markers=UNSET,
    firmware_profiles=UNSET,
    start_tones=UNSET,
    stop_tones=UNSET,
    app_starts=UNSET,
    app_stops=UNSET,
    finalized=UNSET,
    cancellations=UNSET,
    serial_errors=UNSET,
    expected_squeezes=UNSET,
    wav_start_offset=0.0,
    wav_duration_seconds=6.0,
    missing_wav=False,
    missing_serial=False,
    missing_app_log=False,
):
    session_dir.mkdir(parents=True, exist_ok=True)
    if firmware_pairs is UNSET:
        firmware_pairs = [(1.0, 2.0)]
    if firmware_markers is UNSET:
        firmware_markers = [
            marker
            for start, stop in firmware_pairs
            for marker in (("start", start), ("stop", stop))
        ]
    if firmware_profiles is UNSET:
        firmware_profiles = ["v13"] * len(firmware_markers)
    if len(firmware_profiles) != len(firmware_markers):
        raise ValueError("firmware_profiles must align with firmware_markers")
    if start_tones is UNSET:
        start_tones = [start - 0.08 for start, _stop in firmware_pairs]
    if stop_tones is UNSET:
        stop_tones = [stop - 0.08 for _start, stop in firmware_pairs]
    if app_starts is UNSET:
        app_starts = [(start - 0.04, "marker") for start, _stop in firmware_pairs]
    if app_stops is UNSET:
        app_stops = [(stop - 0.04, "marker") for _start, stop in firmware_pairs]
    if finalized is UNSET:
        finalized = [stop - 0.03 for _start, stop in firmware_pairs]
    if cancellations is UNSET:
        cancellations = []
    if serial_errors is UNSET:
        serial_errors = []
    if expected_squeezes is UNSET:
        expected_squeezes = len(firmware_pairs)

    wav_path = session_dir / "ting-raw-acceptance.wav"
    if not missing_wav:
        samples = speech_like_audio(SAMPLE_RATE, wav_duration_seconds, seed=707)
        for offset_seconds in start_tones:
            render_marker(
                samples,
                int(round((offset_seconds - wav_start_offset) * SAMPLE_RATE)),
                START_FREQUENCY,
                sample_rate=SAMPLE_RATE,
            )
        for offset_seconds in stop_tones:
            render_marker(
                samples,
                int(round((offset_seconds - wav_start_offset) * SAMPLE_RATE)),
                STOP_FREQUENCY,
                sample_rate=SAMPLE_RATE,
            )
        write_pcm16_wav(wav_path, samples, sample_rate=SAMPLE_RATE)

    if not missing_serial:
        serial_entries = []
        for index, ((kind, offset_seconds), profile) in enumerate(
            zip(firmware_markers, firmware_profiles),
            start=1,
        ):
            ticks_ms = 100_000 + int(round(offset_seconds * 1000))
            profile_text = " profile={}".format(profile) if profile is not None else ""
            serial_entries.append(
                (
                    offset_seconds,
                    "{:.6f} TING {} marker {}{} v={}\n".format(
                        BASE_TIME + offset_seconds,
                        ticks_ms,
                        kind,
                        profile_text,
                        900 + index,
                    ),
                )
            )
        for offset_seconds, message in serial_errors:
            serial_entries.append(
                (offset_seconds, "{:.6f} {}\n".format(BASE_TIME + offset_seconds, message))
            )
        serial_entries.sort(key=lambda entry: entry[0])
        (session_dir / "serial.log").write_text(
            "".join(line for _offset, line in serial_entries),
            encoding="utf-8",
        )

    if not missing_app_log:
        app_records = [
            log_record(BASE_TIME + wav_start_offset, "ting raw dump path={}".format(wav_path)),
            log_record(BASE_TIME + wav_start_offset + 0.01, "ting audio monitor started"),
            log_record(BASE_TIME + wav_start_offset + 0.25, "ting levels window_s=0.500 peak_dbfs=-22.0"),
        ]
        for offset_seconds, cause in app_starts:
            app_records.append(
                log_record(
                    BASE_TIME + offset_seconds,
                    activity_message("started", -29.0, cause),
                )
            )
        for offset_seconds, cause in app_stops:
            app_records.append(
                log_record(
                    BASE_TIME + offset_seconds,
                    activity_message("stopped", -54.0, cause),
                )
            )
        for offset_seconds in finalized:
            app_records.append(
                log_record(BASE_TIME + offset_seconds, "ting capture finalized duration_s=0.800")
            )
        for offset_seconds in cancellations:
            app_records.append(log_record(BASE_TIME + offset_seconds, "ting capture cancelled"))
        app_records.sort(key=lambda record: record["timestamp"])
        with (session_dir / "app-log.ndjson").open("w", encoding="utf-8") as handle:
            for record in app_records:
                handle.write(json.dumps(record, sort_keys=True))
                handle.write("\n")

    meta = {
        "session_start_epoch": BASE_TIME,
        "serial_device": "/dev/cu.usbmodemTEST",
        "completion_reason": "user_interrupt",
        "status": "captured",
        "preflight": {
            "expected_squeeze_count": {"result": "pass"},
            "serial": {"result": "pass"},
            "required_settings": {"result": "pass"},
            "repository": {"result": "pass"},
            "installed_app": {"result": "pass"},
            "cable_creation_input": {"result": "pass"},
            "firmware": {"result": "pass"},
            "raw_wav": {"result": "pass"},
        },
        "artifact_integrity": {
            "result": "pass",
            "errors": [],
        },
    }
    if expected_squeezes is not None:
        meta["expected_squeezes"] = expected_squeezes
    (session_dir / "meta.json").write_text(json.dumps(meta), encoding="utf-8")


def read_meta(session_dir):
    return json.loads((session_dir / "meta.json").read_text(encoding="utf-8"))


def write_meta(session_dir, meta):
    (session_dir / "meta.json").write_text(json.dumps(meta), encoding="utf-8")


def update_meta(session_dir, **updates):
    meta = read_meta(session_dir)
    meta.update(updates)
    write_meta(session_dir, meta)


def activity_message(action, level, cause):
    message = "ting activity {} level_dbfs={:.1f}".format(action, level)
    if cause is not None:
        message += " cause={}".format(cause)
    return message


def log_record(epoch, message):
    return {
        "timestamp": format_log_timestamp(epoch),
        "subsystem": "com.huntae.groq-menubar-dictate",
        "eventMessage": message,
    }


def format_log_timestamp(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f%z")


def speech_like_audio(sample_rate, duration_seconds, seed):
    rng = random.Random(seed)
    count = int(round(sample_rate * duration_seconds))
    samples = array("h")
    append = samples.append
    low = 0.0
    cutoff = 3_400.0
    alpha = 1.0 / (1.0 + sample_rate / (2.0 * math.pi * cutoff))
    phases = [0.0, 0.7, 1.6, 2.4]
    increments = [
        2.0 * math.pi * 135.0 / sample_rate,
        2.0 * math.pi * 710.0 / sample_rate,
        2.0 * math.pi * 1_840.0 / sample_rate,
        2.0 * math.pi * 4_700.0 / sample_rate,
    ]
    env1 = 0.0
    env2 = 1.1
    env1_step = 2.0 * math.pi * 2.6 / sample_rate
    env2_step = 2.0 * math.pi * 5.1 / sample_rate

    for _index in range(count):
        white = rng.uniform(-1.0, 1.0)
        low += alpha * (white - low)
        envelope = 0.46 + 0.24 * math.sin(env1) + 0.10 * math.sin(env2)
        tone = (
            0.035 * math.sin(phases[0])
            + 0.022 * math.sin(phases[1])
            + 0.018 * math.sin(phases[2])
            + 0.010 * math.sin(phases[3])
        )
        value = envelope * (0.115 * low + tone)
        append(clip_pcm16(value * 32_767.0))

        env1 += env1_step
        env2 += env2_step
        for phase_index, step in enumerate(increments):
            phases[phase_index] += step
            if phases[phase_index] > math.tau:
                phases[phase_index] -= math.tau

    return samples


def clip_pcm16(value):
    value = int(round(value))
    if value > 32_767:
        return 32_767
    if value < -32_768:
        return -32_768
    return value


if __name__ == "__main__":
    unittest.main()
