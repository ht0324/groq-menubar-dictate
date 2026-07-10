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


class AnalyzeFlightRecorderTests(unittest.TestCase):
    def test_clean_session_reports_one_chain_per_squeeze_and_exits_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(
                session_dir,
                tone_offsets=[0.90, 2.10],
                firmware_offsets=[0.90, 2.10],
                app_stop_offsets=[1.05, 2.25],
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 0, output)
            self.assertIn("clean stop chains: 2", output)
            self.assertIn("broken chains: 0", output)
            self.assertIn("anomalies: 0", output)

    def test_firmware_stop_with_missing_tone_breaks_at_tone_layer(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(
                session_dir,
                tone_offsets=[],
                firmware_offsets=[1.00],
                app_stop_offsets=[],
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("BROKEN fw-only: tone never reached audio", output)
            self.assertIn("fw-only breaks (tone never reached audio): 1", output)

    def test_tone_without_firmware_line_is_phantom(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(
                session_dir,
                tone_offsets=[1.00],
                firmware_offsets=[],
                app_stop_offsets=[1.18],
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("ANOMALY phantom tone: no firmware marker stop", output)
            self.assertIn("phantom tones: 1", output)

    def test_missing_wav_marks_tone_checks_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(
                session_dir,
                tone_offsets=[1.00],
                firmware_offsets=[1.00],
                app_stop_offsets=[1.18],
                missing_wav=True,
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("MISSING WAV", output)
            self.assertIn("UNKNOWN tone check unavailable", output)
            self.assertIn("unknown stop checks: 1", output)

    def test_start_tone_is_info_not_anomaly(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(
                session_dir,
                tone_offsets=[],
                firmware_offsets=[],
                app_stop_offsets=[],
                start_tone_offsets=[0.90],
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 0, output)
            self.assertIn("6 kHz START tone detected", output)
            self.assertIn("6 kHz START tones: 1", output)
            self.assertNotIn("ANOMALY unexpected START tone", output)
            self.assertIn("anomalies: 0", output)

    def test_latest_session_pattern_separates_unknown_and_inactive_stops(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            precoverage_stops = [0.20 * index for index in range(1, 11)]
            build_session(
                session_dir,
                tone_offsets=[5.80, 7.00],
                firmware_offsets=precoverage_stops + [5.80, 7.00],
                app_stop_offsets=[7.15],
                activity_start_offsets=[6.60],
                wav_start_offset=5.00,
                expected_squeezes=12,
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("clean stop chains: 1", output)
            self.assertIn("broken chains: 0", output)
            self.assertIn("outside-WAV-coverage unknowns: 10", output)
            self.assertIn("inactive-capture stops: 1", output)
            self.assertIn("unknown stop checks: 10", output)
            self.assertIn("observed firmware stop outcomes: 12", output)
            self.assertIn("expected squeezes: 12", output)
            self.assertIn("observed minus expected: +0", output)
            self.assertNotIn("Mac detector missed app stop", output)

    def test_cancel_and_monitor_stop_restore_known_inactive_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(
                session_dir,
                tone_offsets=[1.00, 2.00],
                firmware_offsets=[1.00, 2.00],
                app_stop_offsets=[],
                activity_start_offsets=[0.30, 1.30],
                capture_cancel_offsets=[0.70],
                monitor_stop_offsets=[1.70],
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 0, output)
            self.assertIn("ting capture cancelled", output)
            self.assertIn("ting audio monitor stopped", output)
            self.assertIn("inactive-capture stops: 2", output)
            self.assertIn("broken chains: 0", output)

    def test_tone_matching_does_not_cross_unrelated_wav_coverage(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_adjacent_wav_session(session_dir)

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("BROKEN fw-only: tone never reached audio", output)
            self.assertIn("fw-only breaks (tone never reached audio): 1", output)
            self.assertIn("clean stop chains: 0", output)

    def test_stops_in_wav_anchor_uncertainty_are_ambiguous(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(
                session_dir,
                tone_offsets=[],
                firmware_offsets=[0.80, 2.20],
                app_stop_offsets=[],
                wav_start_offset=1.00,
                wav_duration_seconds=1.00,
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertEqual(output.count("UNKNOWN ambiguous raw WAV edge coverage"), 2, output)
            self.assertIn("ambiguous-WAV-edge unknowns: 2", output)
            self.assertIn("outside-WAV-coverage unknowns: 0", output)
            self.assertIn("broken chains: 0", output)

    def test_expected_squeeze_mismatch_is_anomaly(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_dir = Path(tmp)
            build_session(
                session_dir,
                tone_offsets=[1.00],
                firmware_offsets=[1.00],
                app_stop_offsets=[1.15],
                expected_squeezes=2,
            )

            status, output = run_analyzer(session_dir)

            self.assertEqual(status, 2, output)
            self.assertIn("observed firmware stop outcomes: 1", output)
            self.assertIn("expected squeezes: 2", output)
            self.assertIn("observed minus expected: -1", output)
            self.assertIn("ANOMALY expected squeeze count mismatch", output)
            self.assertIn("anomalies: 1", output)


def run_analyzer(session_dir):
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        status = analyze.main([str(session_dir)])
    return status, output.getvalue()


def build_session(
    session_dir,
    tone_offsets,
    firmware_offsets,
    app_stop_offsets,
    missing_wav=False,
    start_tone_offsets=None,
    activity_start_offsets=None,
    capture_cancel_offsets=None,
    monitor_stop_offsets=None,
    wav_start_offset=0.0,
    wav_duration_seconds=3.2,
    expected_squeezes=None,
):
    session_dir.mkdir(parents=True, exist_ok=True)
    start_tone_offsets = start_tone_offsets or []
    capture_cancel_offsets = capture_cancel_offsets or []
    monitor_stop_offsets = monitor_stop_offsets or []
    wav_path = session_dir / "ting-raw-20260707-212603.wav"
    if not missing_wav:
        samples = speech_like_audio(SAMPLE_RATE, wav_duration_seconds, seed=707)
        for offset_seconds in start_tone_offsets:
            render_marker(
                samples,
                int(round((offset_seconds - wav_start_offset) * SAMPLE_RATE)),
                START_FREQUENCY,
                sample_rate=SAMPLE_RATE,
            )
        for offset_seconds in tone_offsets:
            render_marker(
                samples,
                int(round((offset_seconds - wav_start_offset) * SAMPLE_RATE)),
                STOP_FREQUENCY,
                sample_rate=SAMPLE_RATE,
            )
        write_pcm16_wav(wav_path, samples, sample_rate=SAMPLE_RATE)

    serial_lines = []
    for index, offset_seconds in enumerate(firmware_offsets, start=1):
        ticks_ms = 100_000 + int(round(offset_seconds * 1000))
        serial_lines.append(
            "{:.6f} TING {} marker stop v={}\n".format(
                BASE_TIME + offset_seconds,
                ticks_ms,
                3400 + index,
            )
        )
    (session_dir / "serial.log").write_text("".join(serial_lines), encoding="utf-8")

    app_records = [
        log_record(BASE_TIME + wav_start_offset, "ting audio monitor started"),
        log_record(BASE_TIME + wav_start_offset, "ting raw dump path={}".format(wav_path)),
        log_record(BASE_TIME + 0.25, "ting levels window_s=0.500 peak_dbfs=-22.0"),
    ]
    if activity_start_offsets is None:
        activity_start_offsets = [
            max(0.05, offset_seconds - 0.35)
            for offset_seconds in firmware_offsets or ([0.70] if app_stop_offsets else [])
        ]
    for offset_seconds in activity_start_offsets:
        app_records.append(log_record(BASE_TIME + offset_seconds, "ting activity started level_dbfs=-29.0"))
    for offset_seconds in app_stop_offsets:
        app_records.append(log_record(BASE_TIME + offset_seconds, "ting activity stopped level_dbfs=-54.0"))
        app_records.append(log_record(BASE_TIME + offset_seconds + 0.05, "ting capture finalized duration_s=0.800"))
    for offset_seconds in capture_cancel_offsets:
        app_records.append(log_record(BASE_TIME + offset_seconds, "ting capture cancelled"))
    for offset_seconds in monitor_stop_offsets:
        app_records.append(log_record(BASE_TIME + offset_seconds, "ting audio monitor stopped"))
    app_records.sort(key=lambda record: record["timestamp"])
    with (session_dir / "app-log.ndjson").open("w", encoding="utf-8") as handle:
        for record in app_records:
            handle.write(json.dumps(record, sort_keys=True))
            handle.write("\n")

    meta = {
        "session_start_epoch": BASE_TIME,
        "serial_device": "/dev/cu.usbmodemTEST",
    }
    if expected_squeezes is not None:
        meta["expected_squeezes"] = expected_squeezes
    (session_dir / "meta.json").write_text(json.dumps(meta), encoding="utf-8")


def build_adjacent_wav_session(session_dir):
    session_dir.mkdir(parents=True, exist_ok=True)
    first_wav = session_dir / "ting-raw-first.wav"
    second_wav = session_dir / "ting-raw-second.wav"

    first_samples = speech_like_audio(SAMPLE_RATE, 1.0, seed=101)
    render_marker(
        first_samples,
        int(round(0.75 * SAMPLE_RATE)),
        STOP_FREQUENCY,
        sample_rate=SAMPLE_RATE,
    )
    write_pcm16_wav(first_wav, first_samples, sample_rate=SAMPLE_RATE)
    write_pcm16_wav(
        second_wav,
        speech_like_audio(SAMPLE_RATE, 2.0, seed=202),
        sample_rate=SAMPLE_RATE,
    )

    (session_dir / "serial.log").write_text(
        "{:.6f} TING 101200 marker stop v=3401\n".format(BASE_TIME + 1.20),
        encoding="utf-8",
    )
    app_records = [
        log_record(BASE_TIME, "ting raw dump path={}".format(first_wav)),
        log_record(BASE_TIME + 0.01, "ting audio monitor started"),
        log_record(BASE_TIME + 1.10, "ting raw dump path={}".format(second_wav)),
        log_record(BASE_TIME + 1.15, "ting activity started level_dbfs=-29.0"),
        log_record(BASE_TIME + 1.35, "ting activity stopped level_dbfs=-54.0"),
    ]
    with (session_dir / "app-log.ndjson").open("w", encoding="utf-8") as handle:
        for record in app_records:
            handle.write(json.dumps(record, sort_keys=True))
            handle.write("\n")
    (session_dir / "meta.json").write_text(
        json.dumps({"session_start_epoch": BASE_TIME}),
        encoding="utf-8",
    )


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
