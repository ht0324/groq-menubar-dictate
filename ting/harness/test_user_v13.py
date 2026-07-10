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


USER_PATH = Path(__file__).resolve().parents[1] / "user.py"


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
    return load_user_profile(
        USER_PATH,
        {"/fat/marker_start.wav", "/fat/marker_stop.wav"},
    )


if __name__ == "__main__":
    unittest.main()
