import math
import random
import unittest
from array import array

from goertzel import GoertzelDetector
from markers import render_marker


PROFILES = (
    {"name": "48 kHz", "sample_rate": 48_000, "start": 17_800, "stop": 18_800},
    {"name": "16 kHz", "sample_rate": 16_000, "start": 6_000, "stop": 7_000},
)


class MarkerDetectionTests(unittest.TestCase):
    def test_start_and_stop_markers_detect_within_ten_ms(self):
        for profile in PROFILES:
            with self.subTest(profile=profile["name"]):
                sample_rate = profile["sample_rate"]
                samples = speech_like_audio(sample_rate, 2.0, seed=101)
                start_offset = int(0.500 * sample_rate)
                stop_offset = int(1.350 * sample_rate)
                render_marker(samples, start_offset, profile["start"], sample_rate=sample_rate)
                render_marker(samples, stop_offset, profile["stop"], sample_rate=sample_rate)

                events = run_detector(samples, profile)
                start_events = [event for event in events if event.kind == "start"]
                stop_events = [event for event in events if event.kind == "stop"]

                self.assertTrue(start_events, events)
                self.assertTrue(stop_events, events)
                tolerance = int(0.010 * sample_rate)
                self.assertLessEqual(abs(start_events[0].sample_index - start_offset), tolerance)
                self.assertLessEqual(abs(stop_events[0].sample_index - stop_offset), tolerance)

    def test_no_false_positives_over_marker_free_speech_like_audio_and_noise(self):
        for profile in PROFILES:
            with self.subTest(profile=profile["name"], signal="speech-like"):
                samples = speech_like_audio(profile["sample_rate"], 60.0, seed=202)
                self.assertEqual(run_detector(samples, profile), [])

            with self.subTest(profile=profile["name"], signal="white-noise"):
                samples = white_noise(profile["sample_rate"], 60.0, seed=303)
                self.assertEqual(run_detector(samples, profile), [])


def run_detector(samples, profile):
    detector = GoertzelDetector(
        sample_rate=profile["sample_rate"],
        start_frequency=profile["start"],
        stop_frequency=profile["stop"],
    )
    events = []
    chunk_size = 257
    for offset in range(0, len(samples), chunk_size):
        events.extend(detector.process(samples[offset : offset + chunk_size]))
    events.extend(detector.flush())
    return events


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


def white_noise(sample_rate, duration_seconds, seed):
    rng = random.Random(seed)
    count = int(round(sample_rate * duration_seconds))
    samples = array("h")
    append = samples.append
    for _index in range(count):
        append(clip_pcm16(rng.uniform(-0.12, 0.12) * 32_767.0))
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
