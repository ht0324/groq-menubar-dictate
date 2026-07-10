import unittest
from pathlib import Path

from user_profile_test_support import (
    assert_marker_pulses,
    click_press,
    click_release,
    load_user_profile,
    send_adc2,
    slot_calls,
)


USER_PATH = Path(__file__).resolve().parents[1] / "user_v12.py"


class UserV12StopOnlyTests(unittest.TestCase):
    def test_exec_loads_only_stop_marker_and_emits_factory_confirmation(self):
        _env, spl, logs = load_user()

        self.assertEqual(
            spl.load_wav_calls,
            [(3, "/fat/marker_stop.wav", "oneshot")],
        )
        self.assertEqual(spl.trigger_calls, [(-1, 0, True), (-1, 0, False)])
        self.assertEqual(slot_calls(spl, 2), [])
        self.assertEqual(slot_calls(spl, 3), [])
        self.assertTrue(any("v12 marker_stop loaded=1" in line for line in logs))

    def test_rest_squeeze_release_emits_one_stop_marker(self):
        env, spl, _logs = load_user()

        for value in (3900, 581, 3900):
            send_adc2(env, value)

        assert_marker_pulses(self, spl, [3])

    def test_initial_squeezed_reading_only_seeds_armed_state(self):
        env, spl, _logs = load_user()

        send_adc2(env, 581)
        assert_marker_pulses(self, spl, [])
        send_adc2(env, 3900)

        assert_marker_pulses(self, spl, [3])

    def test_rest_and_release_without_squeeze_emit_no_marker(self):
        env, spl, _logs = load_user()

        for value in (3900, 3500, 3900):
            send_adc2(env, value)

        assert_marker_pulses(self, spl, [])

    def test_arm_and_release_thresholds_are_strict(self):
        env, spl, _logs = load_user()

        send_adc2(env, 3900)
        send_adc2(env, 2000)
        send_adc2(env, 2801)
        assert_marker_pulses(self, spl, [])

        send_adc2(env, 1999)
        send_adc2(env, 2800)
        assert_marker_pulses(self, spl, [])

        send_adc2(env, 2801)
        assert_marker_pulses(self, spl, [3])

    def test_click_press_release_storms_emit_no_marker(self):
        env, spl, logs = load_user()

        send_adc2(env, 3900)
        for _index in range(12):
            env["user_cb"](click_press())
            env["user_cb"](click_release())

        assert_marker_pulses(self, spl, [])
        self.assertTrue(any("click press" in line for line in logs))
        self.assertTrue(any("click release" in line for line in logs))

    def test_three_squeeze_release_cycles_emit_three_stops(self):
        env, spl, _logs = load_user()

        for value in (3900, 581, 3900, 202, 3900, 379, 3900):
            send_adc2(env, value)

        assert_marker_pulses(self, spl, [3, 3, 3])


def load_user():
    return load_user_profile(USER_PATH, {"/fat/marker_stop.wav"})


if __name__ == "__main__":
    unittest.main()
