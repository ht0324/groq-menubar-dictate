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
APP_MARKER_WINDOW_SECONDS = 1.5
APP_FINALIZE_WINDOW_SECONDS = 1.5
WAV_ANCHOR_UNCERTAINTY_SECONDS = 0.3
EXPECTED_FIRMWARE_PROFILE = "v13"
REQUIRED_PREFLIGHT_CHECKS = (
    "expected_squeeze_count",
    "serial",
    "required_settings",
    "repository",
    "installed_app",
    "cable_creation_input",
    "firmware",
    "raw_wav",
)

RAW_DUMP_PREFIX = "ting raw dump path="
APP_MONITOR_STARTED = "ting audio monitor started"
APP_MONITOR_STOPPED = "ting audio monitor stopped"
APP_ACTIVITY_STARTED = "ting activity started level_dbfs="
APP_ACTIVITY_STOPPED = "ting activity stopped level_dbfs="
APP_CAPTURE_FINALIZED = "ting capture finalized duration_s="
APP_CAPTURE_CANCELLED = "ting capture cancelled"
APP_LEVELS = "ting levels window_s="

SERIAL_LINE_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s+(.*)$")
MARKER_RE = re.compile(r"\bTING\s+(\d+)\s+marker\s+(start|stop)\b", re.IGNORECASE)
SERIAL_FATAL_RE = re.compile(r"\bSERIAL_(?:READ_ERROR|OPEN_ERROR|EOF)\b", re.IGNORECASE)
VALUE_RE = re.compile(r"\bv=([^\s]+)")
PROFILE_RE = re.compile(r"\bprofile=([^\s]+)", re.IGNORECASE)
CAUSE_RE = re.compile(r"\bcause=([^\s]+)", re.IGNORECASE)


@dataclass
class EventLine:
    timestamp: float | None
    source: str
    description: str
    verdict: str = "INFO"
    sequence: int = 0


@dataclass
class FirmwareMarker:
    timestamp: float
    kind: str
    raw_line: str
    ticks_ms: str
    profile: str | None
    event: EventLine
    matched_tone: "ToneDetection | None" = None
    matched_app_event: "AppEvent | None" = None


@dataclass
class AppEvent:
    timestamp: float | None
    kind: str
    message: str
    event: EventLine
    cause: str | None = None
    matched_fw: FirmwareMarker | None = None


@dataclass
class RawDump:
    timestamp: float | None
    source_path: str
    event: EventLine
    resolved_path: Path | None = None
    sample_count: int = 0
    sample_rate: int | None = None
    duration_seconds: float | None = None
    coverage_start: float | None = None
    coverage_end: float | None = None

    def covers(self, timestamp: float) -> bool:
        return (
            self.coverage_start is not None
            and self.coverage_end is not None
            and self.coverage_start <= timestamp <= self.coverage_end
        )

    def is_within_anchor_uncertainty(self, timestamp: float) -> bool:
        if self.coverage_start is None or self.coverage_end is None:
            return False
        return not self.covers(timestamp) and (
            self.coverage_start - WAV_ANCHOR_UNCERTAINTY_SECONDS
            <= timestamp
            <= self.coverage_end + WAV_ANCHOR_UNCERTAINTY_SECONDS
        )


@dataclass
class ToneDetection:
    timestamp: float
    kind: str
    sample_index: int
    frequency: int
    score: float
    wav_path: Path
    raw_dump: RawDump
    event: EventLine
    matched_fw: FirmwareMarker | None = None


@dataclass
class CaptureChain:
    firmware_start: FirmwareMarker
    firmware_stop: FirmwareMarker
    start_tone: ToneDetection | None = None
    app_start: AppEvent | None = None
    stop_tone: ToneDetection | None = None
    app_stop: AppEvent | None = None
    finalized: AppEvent | None = None
    failures: list[str] = field(default_factory=list)


@dataclass
class ParsedSession:
    session_dir: Path
    events: list[EventLine] = field(default_factory=list)
    firmware_starts: list[FirmwareMarker] = field(default_factory=list)
    firmware_stops: list[FirmwareMarker] = field(default_factory=list)
    raw_dumps: list[RawDump] = field(default_factory=list)
    tones: list[ToneDetection] = field(default_factory=list)
    app_starts: list[AppEvent] = field(default_factory=list)
    app_stops: list[AppEvent] = field(default_factory=list)
    app_finalized: list[AppEvent] = field(default_factory=list)
    app_cancellations: list[AppEvent] = field(default_factory=list)
    app_state_events: list[AppEvent] = field(default_factory=list)
    app_log_present: bool = False
    serial_present: bool = False
    usable_wav_count: int = 0
    missing_streams: int = 0
    expected_squeezes: int | None = None
    recorder_meta_valid: bool = False
    invalid_firmware_profiles: int = 0
    fatal_serial_errors: int = 0
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

    parse_meta(parsed)
    parse_serial(parsed)
    parse_app_log(parsed)
    detect_wav_tones(parsed)
    summary = cross_check(parsed)
    print_report(parsed, summary)
    return 0 if summary["accepted"] else 2


def parse_meta(parsed):
    meta_path = parsed.session_dir / "meta.json"
    if not meta_path.exists():
        parsed.add_event(None, "meta", "missing meta.json", "ANOMALY recorder metadata invalid")
        return
    try:
        with meta_path.open("r", encoding="utf-8") as handle:
            meta = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        parsed.add_event(
            None,
            "meta",
            "cannot read meta.json: {}".format(exc),
            "ANOMALY recorder metadata invalid",
        )
        return
    if not isinstance(meta, dict):
        parsed.add_event(
            None,
            "meta",
            "meta.json must contain a JSON object",
            "ANOMALY recorder metadata invalid",
        )
        return

    expected_squeezes = meta.get("expected_squeezes")
    if (
        isinstance(expected_squeezes, int)
        and not isinstance(expected_squeezes, bool)
        and expected_squeezes > 0
    ):
        parsed.expected_squeezes = expected_squeezes

    failures = []
    if parsed.expected_squeezes is None:
        failures.append("expected_squeezes must be a positive integer")

    preflight = meta.get("preflight")
    failed_preflight_checks = [
        check
        for check in REQUIRED_PREFLIGHT_CHECKS
        if not isinstance(preflight, dict)
        or not isinstance(preflight.get(check), dict)
        or preflight[check].get("result") != "pass"
    ]
    if failed_preflight_checks:
        failures.append(
            "preflight checks not passed: {}".format(", ".join(failed_preflight_checks))
        )

    artifact_integrity = meta.get("artifact_integrity")
    if (
        not isinstance(artifact_integrity, dict)
        or artifact_integrity.get("result") != "pass"
        or artifact_integrity.get("errors") != []
    ):
        failures.append("artifact_integrity must report pass with no errors")

    completion_reason = meta.get("completion_reason")
    if completion_reason != "user_interrupt":
        failures.append("completion_reason must be user_interrupt")

    status = meta.get("status")
    if status not in ("captured", "finished"):
        failures.append("status must be captured or finished")

    if failures:
        for failure in failures:
            parsed.add_event(
                None,
                "meta",
                failure,
                "ANOMALY recorder metadata invalid",
            )
        return

    parsed.recorder_meta_valid = True
    parsed.add_event(None, "meta", "recorder acceptance metadata valid", "OK")


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
                if SERIAL_FATAL_RE.search(line):
                    parsed.fatal_serial_errors += 1
                    parsed.add_event(
                        None,
                        "serial",
                        "fatal serial stream error: {}".format(line),
                        "ANOMALY fatal serial error",
                    )
                else:
                    parsed.add_event(
                        None,
                        "serial",
                        "unparseable serial line: {}".format(line),
                        "UNKNOWN",
                    )
                continue
            timestamp = float(match.group(1))
            payload = match.group(2).strip()
            if SERIAL_FATAL_RE.search(payload):
                parsed.fatal_serial_errors += 1
                parsed.add_event(
                    timestamp,
                    "serial",
                    "fatal serial stream error: {}".format(payload),
                    "ANOMALY fatal serial error",
                )
                continue

            marker_match = MARKER_RE.search(payload)
            if marker_match:
                ticks_ms = marker_match.group(1)
                kind = marker_match.group(2).lower()
                value_match = VALUE_RE.search(payload)
                profile_match = PROFILE_RE.search(payload)
                profile = profile_match.group(1).lower() if profile_match else None
                value_text = " v={}".format(value_match.group(1)) if value_match else ""
                profile_text = profile or "missing"
                profile_is_valid = profile == EXPECTED_FIRMWARE_PROFILE
                event = parsed.add_event(
                    timestamp,
                    "serial",
                    "firmware marker {} ticks_ms={} profile={}{}".format(
                        kind,
                        ticks_ms,
                        profile_text,
                        value_text,
                    ),
                    (
                        "PENDING"
                        if profile_is_valid
                        else "ANOMALY firmware marker profile must be {}".format(
                            EXPECTED_FIRMWARE_PROFILE
                        )
                    ),
                )
                if not profile_is_valid:
                    parsed.invalid_firmware_profiles += 1
                marker = FirmwareMarker(timestamp, kind, payload, ticks_ms, profile, event)
                if kind == "start":
                    parsed.firmware_starts.append(marker)
                else:
                    parsed.firmware_stops.append(marker)
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
            if not isinstance(record, dict):
                parsed.add_event(
                    None,
                    "app-log",
                    "ndjson record must contain a JSON object: {}".format(line),
                    "UNKNOWN",
                )
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
                cause = extract_cause(message)
                event = parsed.add_event(timestamp, "app-log", message, "PENDING")
                app_event = AppEvent(timestamp, "activity-start", message, event, cause)
                parsed.app_starts.append(app_event)
                parsed.app_state_events.append(app_event)
            elif APP_ACTIVITY_STOPPED in message:
                cause = extract_cause(message)
                event = parsed.add_event(timestamp, "app-log", message, "PENDING")
                app_event = AppEvent(timestamp, "activity-stop", message, event, cause)
                parsed.app_stops.append(app_event)
                parsed.app_state_events.append(app_event)
            elif APP_MONITOR_STARTED in message:
                event = parsed.add_event(timestamp, "app-log", message, "INFO")
                parsed.app_state_events.append(AppEvent(timestamp, "monitor-start", message, event))
            elif APP_MONITOR_STOPPED in message:
                event = parsed.add_event(timestamp, "app-log", message, "INFO")
                parsed.app_state_events.append(AppEvent(timestamp, "monitor-stop", message, event))
            elif APP_CAPTURE_CANCELLED in message:
                event = parsed.add_event(timestamp, "app-log", message, "ANOMALY capture cancelled")
                app_event = AppEvent(timestamp, "capture-cancelled", message, event)
                parsed.app_cancellations.append(app_event)
                parsed.app_state_events.append(app_event)
            elif APP_CAPTURE_FINALIZED in message:
                event = parsed.add_event(timestamp, "app-log", message, "PENDING")
                parsed.app_finalized.append(AppEvent(timestamp, "capture-finalized", message, event))
            elif APP_LEVELS in message:
                parsed.add_event(timestamp, "app-log", message, "INFO")


def extract_cause(message):
    match = CAUSE_RE.search(message)
    return match.group(1).lower() if match else None


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
        raw_dump.sample_count = len(samples)
        raw_dump.sample_rate = sample_rate
        raw_dump.duration_seconds = len(samples) / float(sample_rate)
        if raw_dump.timestamp is not None:
            raw_dump.coverage_start = raw_dump.timestamp
            raw_dump.coverage_end = raw_dump.timestamp + raw_dump.duration_seconds
            raw_dump.event.description = (
                "raw dump path={} duration_s={:.3f} coverage_end={} "
                "(sample 0 anchor +/-{:.1f}s)"
            ).format(
                raw_dump.source_path,
                raw_dump.duration_seconds,
                format_timestamp(raw_dump.coverage_end),
                WAV_ANCHOR_UNCERTAINTY_SECONDS,
            )
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
                    raw_dump,
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
    chains, unpaired_markers, inactive_stops = pair_firmware_markers(parsed)
    unknown_checks = 0
    outside_coverage_unknowns = 0
    ambiguous_coverage_unknowns = 0

    markers_by_kind = {
        "start": sorted(parsed.firmware_starts, key=lambda marker: marker.timestamp),
        "stop": sorted(parsed.firmware_stops, key=lambda marker: marker.timestamp),
    }

    for chain in chains:
        for marker in (chain.firmware_start, chain.firmware_stop):
            if marker.profile != EXPECTED_FIRMWARE_PROFILE:
                chain.failures.append(
                    "firmware {} profile={} (expected {})".format(
                        marker.kind,
                        marker.profile or "missing",
                        EXPECTED_FIRMWARE_PROFILE,
                    )
                )

        for marker, app_events in (
            (chain.firmware_start, parsed.app_starts),
            (chain.firmware_stop, parsed.app_stops),
        ):
            coverage, coverage_kind = raw_dumps_covering_marker(parsed, marker)
            if coverage is None:
                unknown_checks += 1
                chain.failures.append("{} marker audio coverage unknown".format(marker.kind))
                if coverage_kind == "ambiguous":
                    ambiguous_coverage_unknowns += 1
                elif coverage_kind == "outside":
                    outside_coverage_unknowns += 1
                continue

            tone = nearest_marker_tone(
                marker,
                markers_by_kind[marker.kind],
                parsed.tones,
                coverage,
            )
            if tone is None:
                marker.event.verdict = "BROKEN {} tone never reached audio".format(marker.kind)
                chain.failures.append("missing {} tone".format(marker.kind))
                continue

            marker.matched_tone = tone
            tone.matched_fw = marker
            tone.event.verdict = "OK matched firmware marker {}".format(marker.kind)

            app_event = nearest_marker_app_event(
                marker,
                tone,
                markers_by_kind[marker.kind],
                app_events,
            )
            if app_event is None:
                marker.event.verdict = "BROKEN app activity {} missing".format(marker.kind)
                chain.failures.append("missing app activity {}".format(marker.kind))
                continue

            marker.matched_app_event = app_event
            app_event.matched_fw = marker
            if app_event.cause != "marker":
                cause = app_event.cause or "missing"
                app_event.event.verdict = "ANOMALY activity {} cause={}".format(marker.kind, cause)
                chain.failures.append("app activity {} cause={}".format(marker.kind, cause))
            else:
                app_event.event.verdict = "OK matched marker-caused activity {}".format(marker.kind)

            if marker.kind == "start":
                chain.start_tone = tone
                chain.app_start = app_event
            else:
                chain.stop_tone = tone
                chain.app_stop = app_event

        if chain.app_start is not None and chain.app_stop is not None:
            if chain.app_start.timestamp is None or chain.app_stop.timestamp is None:
                chain.failures.append("app activity timestamp unavailable")
            elif chain.app_start.timestamp >= chain.app_stop.timestamp:
                chain.failures.append("app start/stop order invalid")
            elif capture_interrupted(parsed, chain.app_start.timestamp, chain.app_stop.timestamp):
                inactive_stops += 1
                chain.failures.append("capture inactive before stop")

        if chain.start_tone is not None and chain.stop_tone is not None:
            if chain.start_tone.timestamp is None or chain.stop_tone.timestamp is None:
                chain.failures.append("tone timestamp unavailable")
            elif chain.start_tone.timestamp >= chain.stop_tone.timestamp:
                chain.failures.append("START/STOP tone order invalid")

        if (
            chain.start_tone is not None
            and chain.app_start is not None
            and chain.stop_tone is not None
            and chain.app_stop is not None
            and chain.start_tone.timestamp is not None
            and chain.app_start.timestamp is not None
            and chain.stop_tone.timestamp is not None
            and chain.app_stop.timestamp is not None
        ):
            start_stage_end = max(
                chain.firmware_start.timestamp,
                chain.start_tone.timestamp,
                chain.app_start.timestamp,
            )
            stop_stage_start = min(
                chain.firmware_stop.timestamp,
                chain.stop_tone.timestamp,
                chain.app_stop.timestamp,
            )
            if start_stage_end >= stop_stage_start:
                chain.failures.append("START/STOP lifecycle stages crossed")

        if chain.app_stop is not None:
            next_start_timestamp = next_app_start_after(chain.app_stop, parsed.app_starts)
            finalized = nearest_finalized_after_stop(
                chain.app_stop,
                parsed.app_finalized,
                next_start_timestamp,
            )
            if finalized is None:
                if next_start_timestamp is None:
                    chain.failures.append("finalized capture missing")
                else:
                    chain.failures.append("finalized capture missing before next app START")
            else:
                finalized.matched_fw = chain.firmware_stop
                finalized.event.verdict = "OK matched finalized capture"
                chain.finalized = finalized

        if chain.failures:
            verdict = "BROKEN full chain: {}".format("; ".join(chain.failures))
            if chain.firmware_start.event.verdict == "PENDING":
                chain.firmware_start.event.verdict = verdict
            if chain.firmware_stop.event.verdict == "PENDING":
                chain.firmware_stop.event.verdict = verdict
        else:
            chain.firmware_start.event.verdict = "CLEAN full capture chain"
            chain.firmware_stop.event.verdict = "CLEAN full capture chain"

    phantom_tones = mark_unmatched_tones(parsed)
    unmatched_app_events, level_causes = mark_unmatched_app_events(parsed)
    unmatched_finalized = mark_unmatched_finalized(parsed)

    clean = sum(not chain.failures for chain in chains)
    broken_total = sum(bool(chain.failures) for chain in chains) + unpaired_markers
    count_mismatches = add_expected_count_verdict(parsed, chains)
    anomalies = count_existing_anomaly_events(parsed)
    unknown_events = sum(event.verdict.startswith("UNKNOWN") for event in parsed.events)
    expected_is_positive = parsed.expected_squeezes is not None
    accepted = (
        expected_is_positive
        and clean == parsed.expected_squeezes
        and broken_total == 0
        and count_mismatches == 0
        and phantom_tones == 0
        and unmatched_app_events == 0
        and unmatched_finalized == 0
        and inactive_stops == 0
        and parsed.fatal_serial_errors == 0
        and parsed.missing_streams == 0
        and parsed.recorder_meta_valid
        and parsed.invalid_firmware_profiles == 0
        and unknown_events == 0
        and anomalies == 0
    )
    return {
        "accepted": accepted,
        "clean": clean,
        "broken_total": broken_total,
        "phantom_tones": phantom_tones,
        "unmatched_app_events": unmatched_app_events,
        "unmatched_finalized": unmatched_finalized,
        "level_causes": level_causes,
        "outside_coverage_unknowns": outside_coverage_unknowns,
        "ambiguous_coverage_unknowns": ambiguous_coverage_unknowns,
        "inactive_stops": inactive_stops,
        "start_tones": sum(tone.kind == "start" for tone in parsed.tones),
        "stop_tones": sum(tone.kind == "stop" for tone in parsed.tones),
        "anomalies": anomalies,
        "unknown_checks": unknown_checks,
        "unknown_events": unknown_events,
        "count_mismatches": count_mismatches,
    }


def pair_firmware_markers(parsed):
    markers = sorted(
        parsed.firmware_starts + parsed.firmware_stops,
        key=lambda marker: marker.event.sequence,
    )
    chains = []
    pending_start = None
    unpaired = 0
    inactive_stops = 0
    for marker in markers:
        if marker.kind == "start":
            if pending_start is not None:
                pending_start.event.verdict = "ANOMALY unmatched firmware START"
                unpaired += 1
            pending_start = marker
            continue

        if pending_start is None:
            marker.event.verdict = "ANOMALY inactive firmware STOP without START"
            inactive_stops += 1
            unpaired += 1
            continue
        if marker.timestamp <= pending_start.timestamp:
            marker.event.verdict = "ANOMALY firmware START/STOP order invalid"
            pending_start.event.verdict = "ANOMALY firmware START/STOP order invalid"
            unpaired += 2
        else:
            chains.append(CaptureChain(pending_start, marker))
        pending_start = None

    if pending_start is not None:
        pending_start.event.verdict = "ANOMALY unmatched firmware START without STOP"
        unpaired += 1
    return chains, unpaired, inactive_stops


def raw_dumps_covering_marker(parsed, marker):
    if parsed.usable_wav_count == 0:
        marker.event.verdict = "UNKNOWN tone check unavailable"
        return None, "unavailable"

    relevant = [raw_dump for raw_dump in parsed.raw_dumps if raw_dump.covers(marker.timestamp)]
    if relevant:
        return relevant, "covered"
    if any(raw_dump.is_within_anchor_uncertainty(marker.timestamp) for raw_dump in parsed.raw_dumps):
        marker.event.verdict = "UNKNOWN ambiguous raw WAV edge coverage"
        return None, "ambiguous"
    marker.event.verdict = "UNKNOWN outside raw WAV coverage"
    return None, "outside"


def marker_neighborhood(marker, markers):
    index = next(index for index, candidate in enumerate(markers) if candidate is marker)
    lower = float("-inf")
    upper = float("inf")
    if index > 0:
        lower = (markers[index - 1].timestamp + marker.timestamp) / 2.0
    if index + 1 < len(markers):
        upper = (marker.timestamp + markers[index + 1].timestamp) / 2.0
    return lower, upper


def nearest_marker_tone(marker, same_kind_markers, tones, relevant_raw_dumps):
    lower, upper = marker_neighborhood(marker, same_kind_markers)
    candidates = [
        tone
        for tone in tones
        if tone.kind == marker.kind
        and tone.matched_fw is None
        and tone.timestamp is not None
        and lower < tone.timestamp <= upper
        and any(tone.raw_dump is raw_dump for raw_dump in relevant_raw_dumps)
        and abs(tone.timestamp - marker.timestamp) <= FW_TONE_WINDOW_SECONDS
    ]
    if not candidates:
        return None
    return min(candidates, key=lambda tone: abs(tone.timestamp - marker.timestamp))


def nearest_marker_app_event(marker, tone, same_kind_markers, app_events):
    lower, upper = marker_neighborhood(marker, same_kind_markers)
    candidates = [
        app_event
        for app_event in app_events
        if app_event.matched_fw is None
        and app_event.timestamp is not None
        and lower < app_event.timestamp <= upper
        and abs(app_event.timestamp - marker.timestamp) <= APP_MARKER_WINDOW_SECONDS
        and abs(app_event.timestamp - tone.timestamp) <= APP_MARKER_WINDOW_SECONDS
        and app_event.timestamp + WAV_ANCHOR_UNCERTAINTY_SECONDS >= tone.timestamp
    ]
    if not candidates:
        return None
    return min(candidates, key=lambda app_event: abs(app_event.timestamp - tone.timestamp))


def capture_interrupted(parsed, start_timestamp, stop_timestamp):
    return any(
        event.kind in ("capture-cancelled", "monitor-stop", "activity-stop")
        and event.timestamp is not None
        and start_timestamp < event.timestamp < stop_timestamp
        for event in parsed.app_state_events
    )


def next_app_start_after(app_stop, app_starts):
    if app_stop.timestamp is None:
        return None
    candidates = [
        event.timestamp
        for event in app_starts
        if event.timestamp is not None and event.timestamp > app_stop.timestamp
    ]
    return min(candidates) if candidates else None


def nearest_finalized_after_stop(app_stop, finalized_events, next_start_timestamp):
    if app_stop.timestamp is None:
        return None
    candidates = [
        event
        for event in finalized_events
        if event.matched_fw is None
        and event.timestamp is not None
        and 0.0 <= event.timestamp - app_stop.timestamp <= APP_FINALIZE_WINDOW_SECONDS
        and (next_start_timestamp is None or event.timestamp < next_start_timestamp)
    ]
    if not candidates:
        return None
    return min(candidates, key=lambda event: event.timestamp - app_stop.timestamp)


def mark_unmatched_tones(parsed):
    unmatched = 0
    for tone in parsed.tones:
        if tone.matched_fw is not None:
            continue
        label = "START" if tone.kind == "start" else "STOP"
        tone.event.verdict = "ANOMALY phantom/unmatched {} tone".format(label)
        unmatched += 1
    return unmatched


def mark_unmatched_app_events(parsed):
    unmatched = 0
    level_causes = 0
    for app_event in parsed.app_starts + parsed.app_stops:
        if app_event.matched_fw is not None:
            if app_event.cause != "marker":
                level_causes += 1
            continue
        cause = app_event.cause or "missing"
        app_event.event.verdict = "ANOMALY unmatched app {} cause={}".format(
            app_event.kind,
            cause,
        )
        if cause != "marker":
            level_causes += 1
        unmatched += 1
    return unmatched, level_causes


def mark_unmatched_finalized(parsed):
    unmatched = 0
    for finalized in parsed.app_finalized:
        if finalized.matched_fw is not None:
            continue
        finalized.event.verdict = "ANOMALY unmatched finalized capture"
        unmatched += 1
    return unmatched


def add_expected_count_verdict(parsed, chains):
    if parsed.expected_squeezes is None:
        parsed.add_event(
            None,
            "meta",
            "positive expected_squeezes is required for acceptance",
            "ANOMALY positive expected squeeze count required",
        )
        return 1

    expected = parsed.expected_squeezes
    observed = {
        "firmware START": len(parsed.firmware_starts),
        "firmware STOP": len(parsed.firmware_stops),
        "6 kHz START tone": sum(tone.kind == "start" for tone in parsed.tones),
        "7 kHz STOP tone": sum(tone.kind == "stop" for tone in parsed.tones),
        "app activity START": len(parsed.app_starts),
        "app activity STOP": len(parsed.app_stops),
        "finalized capture": len(parsed.app_finalized),
        "paired chain": len(chains),
    }
    mismatches = [
        "{}={}".format(label, count)
        for label, count in observed.items()
        if count != expected
    ]
    if not mismatches:
        return 0
    parsed.add_event(
        None,
        "meta",
        "expected each lifecycle count={} but {}".format(expected, ", ".join(mismatches)),
        "ANOMALY expected squeeze count mismatch",
    )
    return len(mismatches)


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
    print("acceptance: {}".format("PASS" if summary["accepted"] else "FAIL"))
    print("clean full capture chains: {}".format(summary["clean"]))
    print("broken chains: {}".format(summary["broken_total"]))
    print("phantom/unmatched tones: {}".format(summary["phantom_tones"]))
    print("unmatched app activity events: {}".format(summary["unmatched_app_events"]))
    print("unmatched finalized captures: {}".format(summary["unmatched_finalized"]))
    print("non-marker or missing app causes: {}".format(summary["level_causes"]))
    print("outside-WAV-coverage unknowns: {}".format(summary["outside_coverage_unknowns"]))
    print("ambiguous-WAV-edge unknowns: {}".format(summary["ambiguous_coverage_unknowns"]))
    print("inactive-capture stops: {}".format(summary["inactive_stops"]))
    print("6 kHz START tones: {}".format(summary["start_tones"]))
    print("7 kHz STOP tones: {}".format(summary["stop_tones"]))
    print("unknown marker checks: {}".format(summary["unknown_checks"]))
    print("unknown events: {}".format(summary["unknown_events"]))
    print("observed firmware START markers: {}".format(len(parsed.firmware_starts)))
    print("observed firmware STOP markers: {}".format(len(parsed.firmware_stops)))
    if parsed.expected_squeezes is not None:
        print("expected squeezes: {}".format(parsed.expected_squeezes))
    else:
        print("expected squeezes: missing or non-positive")
    print("count mismatches: {}".format(summary["count_mismatches"]))
    print("capture cancellations: {}".format(len(parsed.app_cancellations)))
    print("fatal serial errors: {}".format(parsed.fatal_serial_errors))
    print("missing/absent streams: {}".format(parsed.missing_streams))
    print("recorder metadata: {}".format("PASS" if parsed.recorder_meta_valid else "FAIL"))
    print("invalid firmware profiles: {}".format(parsed.invalid_firmware_profiles))
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
