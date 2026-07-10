import unittest
from pathlib import Path

from tingmock import TingSim


MAIN_PATH = Path(__file__).resolve().parents[1] / "main_1_0_8_extracted.py"


class StockFirmwareBehaviorTests(unittest.TestCase):
    def test_sample_button_press_and_release_trigger_current_sample(self):
        sim = TingSim(MAIN_PATH)

        sim.inject_message(TingSim.message(1, 0))
        self.assertEqual(sim.spl.trigger_calls[-1], (-1, 0, True))

        sim.inject_message(TingSim.message(2, 0))
        self.assertEqual(sim.spl.trigger_calls[-1], (-1, 0, False))

    def test_button_one_held_with_handle_released_cycles_sample_after_ten_ticks(self):
        sim = TingSim(MAIN_PATH)
        sim.set_switch(4, 0)

        sim.inject_message(TingSim.message(1, 1))
        sim.tick(9)
        self.assertEqual(sim.get_global("sam_pos"), 0)

        sim.tick()
        self.assertEqual(sim.get_global("sam_pos"), 1)
        self.assertEqual(sim.ui.led_calls[-1], (-1, 1))

    def test_usb_remount_event_reruns_drive_scan_and_reloads_preset(self):
        sim = TingSim(MAIN_PATH)
        initial_rom_count = len(sim.spl.rom_calls)
        initial_load_preset_count = len(sim.fx.calls_for("load_preset"))

        sim.inject_message(TingSim.message(4, 1))

        self.assertGreaterEqual(len(sim.spl.rom_calls), initial_rom_count + 4)
        self.assertEqual(sim.spl.rom_calls[-4:], [0, 1, 2, 3])
        self.assertEqual(len(sim.fx.calls_for("load_preset")), initial_load_preset_count + 1)
        self.assertTrue(sim.vfs.calls)
        self.assertTrue(sim.rp2.calls)


if __name__ == "__main__":
    unittest.main()
