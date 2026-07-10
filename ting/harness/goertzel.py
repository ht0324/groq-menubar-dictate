"""Streaming two-tone Goertzel marker detector."""

from __future__ import annotations

import math


class Detection:
    __slots__ = ("kind", "sample_index", "frequency", "score")

    def __init__(self, kind, sample_index, frequency, score):
        self.kind = kind
        self.sample_index = sample_index
        self.frequency = frequency
        self.score = score

    def __repr__(self):
        return (
            "Detection(kind={!r}, sample_index={!r}, frequency={!r}, score={!r})"
            .format(self.kind, self.sample_index, self.frequency, self.score)
        )


class _TargetState:
    __slots__ = (
        "kind",
        "frequency",
        "coefficient",
        "active",
        "candidate_count",
        "candidate_start",
        "release_count",
        "last_detection",
    )

    def __init__(self, kind, frequency, sample_rate):
        self.kind = kind
        self.frequency = frequency
        omega = 2.0 * math.pi * frequency / sample_rate
        self.coefficient = 2.0 * math.cos(omega)
        self.active = False
        self.candidate_count = 0
        self.candidate_start = None
        self.release_count = 0
        self.last_detection = None


class GoertzelDetector:
    """Detect start/stop marker bursts from streaming mono PCM samples.

    Scores are per-target Goertzel power normalized against total block energy,
    so a full-block pure target sine scores near 1.0 regardless of amplitude.
    """

    def __init__(
        self,
        sample_rate,
        start_frequency,
        stop_frequency,
        block_size=None,
        block_duration_seconds=0.005,
        threshold=0.35,
        release_threshold=0.14,
        debounce_blocks=2,
        release_blocks=2,
        refractory_seconds=0.050,
    ):
        if sample_rate <= 0:
            raise ValueError("sample_rate must be positive")
        for frequency in (start_frequency, stop_frequency):
            if frequency <= 0 or frequency >= sample_rate / 2:
                raise ValueError("target frequencies must be between 0 and Nyquist")

        self.sample_rate = sample_rate
        self.block_size = block_size or max(16, int(round(sample_rate * block_duration_seconds)))
        self.threshold = threshold
        self.release_threshold = min(release_threshold, threshold)
        self.debounce_blocks = max(1, int(debounce_blocks))
        self.release_blocks = max(1, int(release_blocks))
        self.refractory_samples = int(round(refractory_seconds * sample_rate))
        self.targets = [
            _TargetState("start", start_frequency, sample_rate),
            _TargetState("stop", stop_frequency, sample_rate),
        ]
        self._pending = []
        self._samples_seen = 0

    def process(self, samples):
        events = []
        for sample in samples:
            self._pending.append(sample)
            self._samples_seen += 1
            if len(self._pending) == self.block_size:
                block_start = self._samples_seen - self.block_size
                events.extend(self._process_block(self._pending, block_start))
                self._pending = []
        return events

    def flush(self):
        if not self._pending:
            return []
        padded = list(self._pending)
        block_start = self._samples_seen - len(padded)
        padded.extend([0] * (self.block_size - len(padded)))
        self._pending = []
        return self._process_block(padded, block_start)

    def _process_block(self, block, block_start):
        values = [_to_unit_sample(sample) for sample in block]
        total_energy = sum(sample * sample for sample in values)
        if total_energy <= 1.0e-18:
            scores = {target.kind: 0.0 for target in self.targets}
        else:
            scores = {
                target.kind: self._normalized_goertzel_score(
                    values,
                    target.coefficient,
                    total_energy,
                )
                for target in self.targets
            }

        events = []
        for target in self.targets:
            event = self._update_target(target, scores[target.kind], block_start)
            if event is not None:
                events.append(event)
        return events

    def _normalized_goertzel_score(self, values, coefficient, total_energy):
        previous = 0.0
        previous2 = 0.0
        for sample in values:
            current = sample + coefficient * previous - previous2
            previous2 = previous
            previous = current
        power = previous2 * previous2 + previous * previous - coefficient * previous * previous2
        return max(0.0, (2.0 * power) / (len(values) * total_energy))

    def _update_target(self, target, score, block_start):
        if target.active:
            target.candidate_count = 0
            target.candidate_start = None
            if score <= self.release_threshold:
                target.release_count += 1
                if target.release_count >= self.release_blocks:
                    target.active = False
                    target.release_count = 0
            else:
                target.release_count = 0
            return None

        if score >= self.threshold:
            if target.candidate_count == 0:
                target.candidate_start = block_start
            target.candidate_count += 1
            if target.candidate_count >= self.debounce_blocks:
                sample_index = target.candidate_start
                if self._outside_refractory(target, sample_index):
                    target.active = True
                    target.release_count = 0
                    target.candidate_count = 0
                    target.candidate_start = None
                    target.last_detection = sample_index
                    return Detection(target.kind, sample_index, target.frequency, score)
            return None

        if score <= self.release_threshold:
            target.candidate_count = 0
            target.candidate_start = None
        return None

    def _outside_refractory(self, target, sample_index):
        if target.last_detection is None:
            return True
        return sample_index - target.last_detection >= self.refractory_samples


def detect_markers(samples, sample_rate, start_frequency, stop_frequency, **kwargs):
    detector = GoertzelDetector(
        sample_rate=sample_rate,
        start_frequency=start_frequency,
        stop_frequency=stop_frequency,
        **kwargs
    )
    events = detector.process(samples)
    events.extend(detector.flush())
    return events


def _to_unit_sample(sample):
    if isinstance(sample, int):
        return sample / 32_768.0
    return float(sample)
