"""Marker tone generation and PCM16 mixing helpers."""

from __future__ import annotations

import io
import math
import wave
from array import array


DEFAULT_SAMPLE_RATE = 16_000
DEFAULT_START_FREQUENCY = 6_000
DEFAULT_STOP_FREQUENCY = 7_000
DEFAULT_DURATION_SECONDS = 0.030
DEFAULT_RAMP_SECONDS = 0.005
DEFAULT_AMPLITUDE = 0.45

PCM16_MIN = -32_768
PCM16_MAX = 32_767


def _clip_pcm16(value):
    value = int(round(value))
    if value > PCM16_MAX:
        return PCM16_MAX
    if value < PCM16_MIN:
        return PCM16_MIN
    return value


def marker_samples(
    frequency,
    sample_rate=DEFAULT_SAMPLE_RATE,
    duration_seconds=DEFAULT_DURATION_SECONDS,
    amplitude=DEFAULT_AMPLITUDE,
    ramp_seconds=DEFAULT_RAMP_SECONDS,
):
    """Return an array('h') containing one raised-cosine-windowed marker."""

    if sample_rate <= 0:
        raise ValueError("sample_rate must be positive")
    if frequency <= 0 or frequency >= sample_rate / 2:
        raise ValueError("frequency must be between 0 and Nyquist")
    if duration_seconds <= 0:
        raise ValueError("duration_seconds must be positive")
    if amplitude < 0:
        raise ValueError("amplitude must be non-negative")

    frame_count = max(1, int(round(sample_rate * duration_seconds)))
    ramp_count = max(0, min(frame_count // 2, int(round(sample_rate * ramp_seconds))))
    out = array("h")
    out_extend = out.append
    angular_step = 2.0 * math.pi * frequency / sample_rate
    peak = min(float(amplitude), 1.0) * PCM16_MAX

    for index in range(frame_count):
        envelope = 1.0
        if ramp_count > 1 and index < ramp_count:
            envelope = 0.5 - 0.5 * math.cos(math.pi * index / (ramp_count - 1))
        if ramp_count > 1 and index >= frame_count - ramp_count:
            tail_index = frame_count - 1 - index
            envelope = min(
                envelope,
                0.5 - 0.5 * math.cos(math.pi * tail_index / (ramp_count - 1)),
            )
        out_extend(_clip_pcm16(math.sin(angular_step * index) * peak * envelope))

    return out


def render_marker(
    sample_buffer,
    offset,
    frequency,
    sample_rate=DEFAULT_SAMPLE_RATE,
    duration_seconds=DEFAULT_DURATION_SECONDS,
    amplitude=DEFAULT_AMPLITUDE,
    ramp_seconds=DEFAULT_RAMP_SECONDS,
):
    """Additively mix a marker into an existing PCM16 sample buffer in place."""

    marker = marker_samples(
        frequency=frequency,
        sample_rate=sample_rate,
        duration_seconds=duration_seconds,
        amplitude=amplitude,
        ramp_seconds=ramp_seconds,
    )
    start = int(offset)
    marker_start = 0
    if start < 0:
        marker_start = -start
        start = 0

    for marker_index in range(marker_start, len(marker)):
        sample_index = start + marker_index - marker_start
        if sample_index >= len(sample_buffer):
            break
        sample_buffer[sample_index] = _clip_pcm16(
            int(sample_buffer[sample_index]) + int(marker[marker_index])
        )
    return sample_buffer


def pcm16_bytes(samples):
    data = array("h", samples)
    if data.itemsize != 2:
        raise RuntimeError("array('h') is not 16-bit on this Python build")
    if not _is_little_endian():
        data.byteswap()
    return data.tobytes()


def write_pcm16_wav(path, samples, sample_rate=DEFAULT_SAMPLE_RATE):
    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(pcm16_bytes(samples))


def marker_wav_bytes(
    frequency,
    sample_rate=DEFAULT_SAMPLE_RATE,
    duration_seconds=DEFAULT_DURATION_SECONDS,
    amplitude=DEFAULT_AMPLITUDE,
    ramp_seconds=DEFAULT_RAMP_SECONDS,
):
    samples = marker_samples(
        frequency=frequency,
        sample_rate=sample_rate,
        duration_seconds=duration_seconds,
        amplitude=amplitude,
        ramp_seconds=ramp_seconds,
    )
    output = io.BytesIO()
    with wave.open(output, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(pcm16_bytes(samples))
    return output.getvalue()


def write_marker_wav(
    path,
    frequency,
    sample_rate=DEFAULT_SAMPLE_RATE,
    duration_seconds=DEFAULT_DURATION_SECONDS,
    amplitude=DEFAULT_AMPLITUDE,
    ramp_seconds=DEFAULT_RAMP_SECONDS,
):
    samples = marker_samples(
        frequency=frequency,
        sample_rate=sample_rate,
        duration_seconds=duration_seconds,
        amplitude=amplitude,
        ramp_seconds=ramp_seconds,
    )
    write_pcm16_wav(path, samples, sample_rate=sample_rate)


def _is_little_endian():
    probe = array("h", [1])
    return probe.tobytes()[0] == 1
