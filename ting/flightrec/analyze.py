#!/usr/bin/env python3
"""Analyze Ting push-to-talk flight recorder sessions."""

from __future__ import annotations

import json
import re
import sys
import wave
from array import array
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path


HARNESS_DIR = Path(__file__).resolve().parents[1] / "harness"
if str(HARNESS_DIR) not in sys.path:
    sys.path.insert(0, str(HARNESS_DIR))

from goertzel import GoertzelDetector  # noqa: E402


SAMPLE_RATE = 16_000
START_FREQUENCY = 6_000
STOP_FREQUENCY = 7_000
DETECTOR_CHUNK_SIZE = 257
FW_TONE_WINDOW_SECONDS = 0.75
APP_STOP_AFTER_FW_SECONDS = 1.5
WAV_ANCHOR_UNCERTAINTY_SECONDS = 0.3

RAW_DUMP_PREFIX = "ting raw dump path="
APP_MONITOR_STARTED = "ting audio monitor started"
APP_ACTIVITY_STARTED = "ting activity started level_dbfs="
APP_ACTIVITY_STOPPED = "ting activity stopped level_dbfs="
APP_CAPTURE_FINALIZED = "ting capture finalized duration_s="
APP_LEVELS = "ting levels window_s="

SERIAL_LINE_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s+(.*)$")
MARKER_STOP_RE = re.compile(r"\bTING\s+(\d+)\s+marker\s+stop\b")
VALUE_RE = re.compile(r"\bv=([^\s]+)")


@dataclass
class EventLine:
    timestamp: float | None
    source: str
    description: str
    verdict: str = "INFO"
    sequence: int = 0


@dataclass
class FirmwareStop:
    timestamp: float
    raw_line: str
    ticks_ms: str
    event: EventLine
    matched_tone: "ToneDetection | None" = None
    matched_app_stop: "AppEvent | None" = None


@dataclass
class AppEvent:
    timestamp: float | None
    kind: str
    message: str
    event: EventLine
    matched_fw: FirmwareStop | None = None


@dataclass
class RawDump:
    timestamp: float | None
    source_path: str
    event: EventLine
    resolved_path: Path | None = None


@dataclass
class ToneDetection:
    timestamp: float
    kind: str
    sample_index: int
    frequency: int
    score: float
    wav_path: Path
    event: EventLine
    matched_fw: FirmwareStop | None = None


@dataclass
class ParsedSession:
    session_dir: Path
    events: list[EventLine] = field(default_factory=list)
    firmware_stops: list[FirmwareStop] = field(default_factory=list)
    raw_dumps: list[RawDump] = field(default_factory=list)
    tones: list[ToneDetection] = field(default_factory=list)
    app_starts: list[AppEvent] = field(default_factory=list)
    app_stops: list[AppEvent] = field(default_factory=list)
    app_log_present: bool = False
    serial_present: bool = False
    usable_wav_count: int = 0
    missing_streams: int = 0
    sequence: int = 0

    def add_event(self, timestamp, source, description, verdict="INFO"):
        self.sequence += 1
        event = EventLine(timestamp, source, description, verdict, self.sequence)
        self.events.append(event)
        return event


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) != 1:
        print("usage: python3 ting/flightrec/analyze.py <session-dir>")
        return 2

    session_dir = Path(argv[0]).expanduser().resolve()
    parsed = ParsedSession(session_dir=session_dir)
    if not session_dir.exists() or not session_dir.is_dir():
        print("session directory not found: {}".format(session_dir))
        return 2

    parse_serial(parsed)
    parse_app_log(parsed)
    detect_wav_tones(parsed)
    summary = cross_check(parsed)
    print_report(parsed, summary)
    if (
        summary["broken_total"] == 0
        and summary["anomalies"] == 0
        and summary["unknown_checks"] == 0
        and parsed.missing_streams == 0
    ):
        return 0
    return 2


def parse_serial(parsed):
    serial_path = parsed.session_dir / "serial.log"
    if not serial_path.exists():
        parsed.missing_streams += 1
        parsed.add_event(None, "serial", "missing serial.log", "UNKNOWN")
        return

    parsed.serial_present = True
    with serial_path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if not line:
                continue
            match = SERIAL_LINE_RE.match(line)
            if not match:
                parsed.add_event(None, "serial", "unparseable serial line: {}".format(line), "UNKNOWN")
                continue
            timestamp = float(match.group(1))
            payload = match.group(2).strip()
            stop_match = MARKER_STOP_RE.search(payload)
            if stop_match:
                ticks_ms = stop_match.group(1)
                value_match = VALUE_RE.search(payload)
                value_text = " v={}".format(value_match.group(1)) if value_match else ""
                event = parsed.add_event(
                    timestamp,
                    "serial",
                    "firmware marker stop ticks_ms={}{}".format(ticks_ms, value_text),
                    "PENDING",
                )
                parsed.firmware_stops.append(FirmwareStop(timestamp, payload, ticks_ms, event))
            else:
                parsed.add_event(timestamp, "serial", "raw telemetry: {}".format(payload), "INFO")


def parse_app_log(parsed):
    app_log_path = parsed.session_dir / "app-log.ndjson"
    if not app_log_path.exists():
        parsed.missing_streams += 1
        parsed.add_event(None, "app-log", "missing app-log.ndjson", "UNKNOWN")
        return

    parsed.app_log_present = True
    with app_log_path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                parsed.add_event(None, "app-log", "unparseable ndjson line: {}".format(line), "UNKNOWN")
                continue

            timestamp = parse_log_timestamp(record.get("timestamp") or record.get("date"))
            message = str(
                record.get("eventMessage")
                or record.get("message")
                or record.get("composedMessage")
                or ""
            )
            if not message:
                continue

            if RAW_DUMP_PREFIX in message:
                source_path = extract_raw_dump_path(message)
                event = parsed.add_event(
                    timestamp,
                    "app-log",
                    "raw dump path={} (sample 0 anchor +/-{:.1f}s)".format(
                        source_path,
                        WAV_ANCHOR_UNCERTAINTY_SECONDS,
                    ),
                    "INFO",
                )
                parsed.raw_dumps.append(RawDump(timestamp, source_path, event))
            elif APP_ACTIVITY_STARTED in message:
                event = parsed.add_event(timestamp, "app-log", message, "INFO level-triggered start")
                parsed.app_starts.append(AppEvent(timestamp, "start", message, event))
            elif APP_ACTIVITY_STOPPED in message:
                event = parsed.add_event(timestamp, "app-log", message, "PENDING")
                parsed.app_stops.append(AppEvent(timestamp, "stop", message, event))
            elif APP_MONITOR_STARTED in message or APP_CAPTURE_FINALIZED in message or APP_LEVELS in message:
                parsed.add_event(timestamp, "app-log", message, "INFO")


def extract_raw_dump_path(message):
    suffix = message.split(RAW_DUMP_PREFIX, 1)[1].strip()
    if not suffix:
        return ""
    if suffix[0] in ("'", '"'):
        quote = suffix[0]
        end = suffix.find(quote, 1)
        if end > 1:
            return suffix[1:end]
    return suffix.split()[0]


def parse_log_timestamp(value):
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    text = trim_fraction_to_microseconds(text)
    for fmt in ("%Y-%m-%d %H:%M:%S.%f%z", "%Y-%m-%d %H:%M:%S%z"):
        try:
            return datetime.strptime(text, fmt).timestamp()
        except ValueError:
            pass
    if text.endswith("Z"):
        try:
            return datetime.fromisoformat(text[:-1] + "+00:00").timestamp()
        except ValueError:
            pass
    try:
        return datetime.fromisoformat(text).timestamp()
    except ValueError:
        return None


def trim_fraction_to_microseconds(text):
    match = re.match(r"^(.*\.\d{6})\d+([+-]\d{2}:?\d{2})$", text)
    if match:
        return match.group(1) + match.group(2)
    return text


def detect_wav_tones(parsed):
    if not parsed.raw_dumps:
        parsed.missing_streams += 1
        parsed.add_event(None, "audio", "no ting raw dump path entries found in app log", "UNKNOWN")
        return

    for raw_dump in parsed.raw_dumps:
        wav_path = resolve_raw_dump_path(parsed.session_dir, raw_dump.source_path)
        if wav_path is None:
            raw_dump.event.verdict = "MISSING WAV"
            parsed.add_event(
                raw_dump.timestamp,
                "audio",
                "raw dump WAV missing: {}".format(raw_dump.source_path),
                "UNKNOWN",
            )
            continue
        raw_dump.resolved_path = wav_path

        try:
            samples, sample_rate = read_pcm16_wav(wav_path)
        except (OSError, wave.Error, ValueError) as exc:
            raw_dump.event.verdict = "UNREADABLE WAV"
            parsed.add_event(
                raw_dump.timestamp,
                "audio",
                "cannot read raw dump WAV {}: {}".format(wav_path, exc),
                "ANOMALY",
            )
            continue

        parsed.usable_wav_count += 1
        if sample_rate != SAMPLE_RATE:
            parsed.add_event(
                raw_dump.timestamp,
                "audio",
                "unexpected WAV sample rate {} for {}".format(sample_rate, wav_path.name),
                "ANOMALY",
            )

        detector = GoertzelDetector(
            sample_rate=sample_rate,
            start_frequency=START_FREQUENCY,
            stop_frequency=STOP_FREQUENCY,
        )
        detections = []
        for offset in range(0, len(samples), DETECTOR_CHUNK_SIZE):
            detections.extend(detector.process(samples[offset : offset + DETECTOR_CHUNK_SIZE]))
        detections.extend(detector.flush())

        for detection in detections:
            timestamp = None
            if raw_dump.timestamp is not None:
                timestamp = raw_dump.timestamp + detection.sample_index / float(sample_rate)
            frequency_label = "6 kHz START" if detection.kind == "start" else "7 kHz stop"
            verdict = "INFO" if detection.kind == "start" else "PENDING"
            event = parsed.add_event(
                timestamp,
                "audio",
                "{} tone detected in {} sample_index={} score={:.3f}".format(
                    frequency_label,
                    wav_path.name,
                    detection.sample_index,
                    detection.score,
                ),
                verdict,
            )
            parsed.tones.append(
                ToneDetection(
                    timestamp,
                    detection.kind,
                    detection.sample_index,
                    int(detection.frequency),
                    detection.score,
                    wav_path,
                    event,
                )
            )

    if parsed.usable_wav_count == 0:
        parsed.missing_streams += 1


def resolve_raw_dump_path(session_dir, source_path):
    if not source_path:
        return None
    source = Path(source_path).expanduser()
    candidates = []
    if source.name:
        candidates.append(session_dir / source.name)
    candidates.append(source)
    for candidate in candidates:
        if candidate.exists() and candidate.is_file():
            return candidate
    return None


def read_pcm16_wav(path):
    with wave.open(str(path), "rb") as wav_file:
        channels = wav_file.getnchannels()
        sample_width = wav_file.getsampwidth()
        sample_rate = wav_file.getframerate()
        frame_count = wav_file.getnframes()
        frames = wav_file.readframes(frame_count)

    if not frames:
        # A dump copied while the app still has it open has zero in the WAV
        # header size fields; fall back to everything after the 44-byte header.
        with open(path, "rb") as raw_file:
            data = raw_file.read()[44:]
        frames = data[: len(data) - (len(data) % (channels * sample_width))]

    if channels != 1:
        raise ValueError("expected mono WAV, got {} channels".format(channels))
    if sample_width != 2:
        raise ValueError("expected PCM16 WAV, got sample width {}".format(sample_width))

    samples = array("h")
    samples.frombytes(frames)
    if sys.byteorder != "little":
        samples.byteswap()
    return samples, sample_rate


def cross_check(parsed):
    stop_tones = [tone for tone in parsed.tones if tone.kind == "stop" and tone.timestamp is not None]
    start_tones = [tone for tone in parsed.tones if tone.kind == "start"]
    clean = 0
    broken_tone = 0
    broken_app = 0
    unknown_checks = 0
    phantom_tones = 0
    level_fallback_stops = 0

    for fw_stop in parsed.firmware_stops:
        if parsed.usable_wav_count == 0:
            fw_stop.event.verdict = "UNKNOWN tone check unavailable"
            unknown_checks += 1
            continue

        tone = nearest_stop_tone(fw_stop, stop_tones)
        if tone is None:
            fw_stop.event.verdict = "BROKEN fw-only: tone never reached audio"
            broken_tone += 1
            continue

        fw_stop.matched_tone = tone
        tone.matched_fw = fw_stop
        tone.event.verdict = "OK matched firmware marker stop"

        if not parsed.app_log_present:
            fw_stop.event.verdict = "UNKNOWN app log unavailable"
            unknown_checks += 1
            continue

        app_stop = nearest_app_stop_after_fw(fw_stop, parsed.app_stops)
        if app_stop is None:
            fw_stop.event.verdict = "BROKEN fw+tone: Mac detector missed app stop"
            tone.event.verdict = "OK matched firmware marker stop; app stop missing"
            broken_app += 1
            continue

        fw_stop.matched_app_stop = app_stop
        app_stop.matched_fw = fw_stop
        fw_stop.event.verdict = "CLEAN fw+tone+app"
        tone.event.verdict = "OK matched clean stop chain"
        app_stop.event.verdict = "OK matched clean stop chain"
        clean += 1

    for tone in stop_tones:
        if tone.matched_fw is not None:
            continue
        if not any(abs(tone.timestamp - fw.timestamp) <= FW_TONE_WINDOW_SECONDS for fw in parsed.firmware_stops):
            tone.event.verdict = "ANOMALY phantom tone: no firmware marker stop"
            phantom_tones += 1
        else:
            tone.event.verdict = "INFO extra stop tone near firmware marker"

    for app_stop in parsed.app_stops:
        if app_stop.matched_fw is not None:
            continue
        if app_stop.timestamp is None:
            app_stop.event.verdict = "UNKNOWN app stop timestamp unavailable"
            unknown_checks += 1
            continue
        near_fw = any(0.0 <= app_stop.timestamp - fw.timestamp <= APP_STOP_AFTER_FW_SECONDS for fw in parsed.firmware_stops)
        near_tone = any(
            abs(app_stop.timestamp - tone.timestamp) <= FW_TONE_WINDOW_SECONDS
            or 0.0 <= app_stop.timestamp - tone.timestamp <= APP_STOP_AFTER_FW_SECONDS
            for tone in stop_tones
        )
        if not near_fw and not near_tone:
            app_stop.event.verdict = "LEVEL-FALLBACK expected"
            level_fallback_stops += 1
        elif near_tone and not near_fw:
            app_stop.event.verdict = "INFO stop near phantom tone"
        else:
            app_stop.event.verdict = "INFO unmatched app stop near firmware/tone"

    start_tones_seen = len(start_tones)
    anomalies = count_existing_anomaly_events(parsed)
    broken_total = broken_tone + broken_app
    return {
        "clean": clean,
        "broken_total": broken_total,
        "broken_tone": broken_tone,
        "broken_app": broken_app,
        "phantom_tones": phantom_tones,
        "level_fallback_stops": level_fallback_stops,
        "start_tones": start_tones_seen,
        "anomalies": anomalies,
        "unknown_checks": unknown_checks,
    }


def nearest_stop_tone(fw_stop, stop_tones):
    candidates = [
        tone
        for tone in stop_tones
        if tone.matched_fw is None and abs(tone.timestamp - fw_stop.timestamp) <= FW_TONE_WINDOW_SECONDS
    ]
    if not candidates:
        return None
    return min(candidates, key=lambda tone: abs(tone.timestamp - fw_stop.timestamp))


def nearest_app_stop_after_fw(fw_stop, app_stops):
    candidates = [
        app_stop
        for app_stop in app_stops
        if app_stop.matched_fw is None
        and app_stop.timestamp is not None
        and 0.0 <= app_stop.timestamp - fw_stop.timestamp <= APP_STOP_AFTER_FW_SECONDS
    ]
    if not candidates:
        return None
    return min(candidates, key=lambda app_stop: app_stop.timestamp - fw_stop.timestamp)


def count_existing_anomaly_events(parsed):
    count = 0
    for event in parsed.events:
        if event.verdict.startswith("ANOMALY"):
            count += 1
    return count


def print_report(parsed, summary):
    print("Chronological event table")
    for event in sorted(parsed.events, key=event_sort_key):
        print(
            "{} | {} | {} | {}".format(
                format_timestamp(event.timestamp),
                event.source,
                event.description,
                event.verdict,
            )
        )

    print("")
    print("Summary")
    print("clean stop chains: {}".format(summary["clean"]))
    print("broken chains: {}".format(summary["broken_total"]))
    print("fw-only breaks (tone never reached audio): {}".format(summary["broken_tone"]))
    print("fw+tone breaks (Mac detector missed it): {}".format(summary["broken_app"]))
    print("phantom tones: {}".format(summary["phantom_tones"]))
    print("level-fallback stops: {}".format(summary["level_fallback_stops"]))
    print("6 kHz START tones: {}".format(summary["start_tones"]))
    print("unknown stop checks: {}".format(summary["unknown_checks"]))
    print("missing/absent streams: {}".format(parsed.missing_streams))
    print("anomalies: {}".format(summary["anomalies"]))


def event_sort_key(event):
    timestamp = float("inf") if event.timestamp is None else event.timestamp
    return (timestamp, event.sequence)


def format_timestamp(timestamp):
    if timestamp is None:
        return "unknown-time"
    return datetime.fromtimestamp(timestamp, timezone.utc).astimezone().isoformat(timespec="milliseconds")


if __name__ == "__main__":
    raise SystemExit(main())
