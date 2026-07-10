import unittest
from pathlib import Path


USER_PATH = Path(__file__).resolve().parents[1] / "user.py"


class MockFatFile:
    def __init__(self, path, mode):
        self.path = path
        self.mode = mode
        self.closed = False

    def close(self):
        self.closed = True


class MockSpl:
    def __init__(self):
        self.load_wav_calls = []
        self.trigger_calls = []

    def load_wav(self, slot, f, mode):
        self.load_wav_calls.append((slot, f.path, mode))
        return True

    def trigger(self, ch, slot, gate):
        self.trigger_calls.append((ch, slot, gate))


class UserV13LeverStartStopTests(unittest.TestCase):
    def test_exec_load_emits_only_factory_confirmation(self):
        _env, spl, logs = load_user()

        self.assertEqual(
            spl.load_wav_calls,
            [
                (2, "/fat/marker_start.wav", "oneshot"),
                (3, "/fat/marker_stop.wav", "oneshot"),
            ],
        )
        self.assertEqual(spl.trigger_calls, [(-1, 0, True), (-1, 0, False)])
        self.assertEqual(slot_calls(spl, 2), [])
        self.assertEqual(slot_calls(spl, 3), [])
        self.assertTrue(any("v13 markers loaded start=1 stop=1" in line for line in logs))

    def test_rest_squeeze_release_emits_start_then_stop(self):
        env, spl, _logs = load_user()

        send_adc2(env, 3900)
        send_adc2(env, 581)
        send_adc2(env, 3900)

        assert_marker_pulses(self, spl, [2, 3])

    def test_finger_rest_then_release_emits_no_marker_pulses(self):
        env, spl, _logs = load_user()

        send_adc2(env, 1100)
        send_adc2(env, 3900)

        assert_marker_pulses(self, spl, [])

    def test_initial_squeezed_reading_only_seeds_down_state(self):
        env, spl, _logs = load_user()

        send_adc2(env, 581)
        assert_marker_pulses(self, spl, [])
        send_adc2(env, 3900)

        assert_marker_pulses(self, spl, [3])

    def test_three_squeeze_release_cycles_alternate_start_stop(self):
        env, spl, _logs = load_user()

        for value in (3900, 581, 3900, 202, 3900, 379, 3900):
            send_adc2(env, value)

        assert_marker_pulses(self, spl, [2, 3, 2, 3, 2, 3])

    def test_click_press_release_storms_emit_no_marker_pulses(self):
        env, spl, logs = load_user()

        send_adc2(env, 3900)
        for _index in range(12):
            env["user_cb"](click_press())
            env["user_cb"](click_release())

        assert_marker_pulses(self, spl, [])
        self.assertTrue(any("click press" in line for line in logs))
        self.assertTrue(any("click release" in line for line in logs))

    def test_start_and_release_thresholds_are_strict(self):
        env, spl, _logs = load_user()

        send_adc2(env, 3900)
        send_adc2(env, 1000)
        send_adc2(env, 3900)
        assert_marker_pulses(self, spl, [])

        send_adc2(env, 999)
        send_adc2(env, 2800)
        assert_marker_pulses(self, spl, [2])

        send_adc2(env, 2801)
        assert_marker_pulses(self, spl, [2, 3])

    def test_between_threshold_oscillation_after_start_emits_no_extra_tones(self):
        env, spl, _logs = load_user()

        send_adc2(env, 3900)
        send_adc2(env, 581)
        for value in (1200, 2700, 1300, 2600, 1500, 2700):
            send_adc2(env, value)

        assert_marker_pulses(self, spl, [2])


def load_user():
    spl = MockSpl()
    logs = []
    allowed_paths = {"/fat/marker_start.wav", "/fat/marker_stop.wav"}

    def mock_open(path, mode="r"):
        if path not in allowed_paths:
            raise OSError(path)
        return MockFatFile(path, mode)

    def mock_print(*args):
        logs.append(" ".join([str(arg) for arg in args]))

    env = {"spl": spl, "open": mock_open, "print": mock_print}
    source = USER_PATH.read_text()
    exec(compile(source, str(USER_PATH), "exec"), env)
    return env, spl, logs


def adc_message(channel, value):
    return ((0x10 | channel) << 16) | value


def send_adc2(env, value):
    env["user_cb"](adc_message(2, value))


def click_press():
    return (1 << 16) | 4


def click_release():
    return (2 << 16) | 4


def slot_calls(spl, slot):
    return [call for call in spl.trigger_calls if call[1] == slot]


def marker_calls(spl):
    return [call for call in spl.trigger_calls if call[1] in (2, 3)]


def assert_marker_pulses(testcase, spl, slots):
    expected = []
    for slot in slots:
        expected.append((-1, slot, True))
        expected.append((-1, slot, False))
    testcase.assertEqual(marker_calls(spl), expected)


if __name__ == "__main__":
    unittest.main()
