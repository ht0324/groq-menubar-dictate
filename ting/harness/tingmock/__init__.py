"""Desktop mocks for running ting MicroPython application code.

The Ting main script imports native MicroPython modules named ``ui``,
``spl``, and ``fx``.  ``TingSim`` injects call-recording desktop substitutes
for those bare module names while it execs the firmware source and while tests
deliver callback messages.
"""

from __future__ import annotations

import builtins
import contextlib
import os
import sys
import types


_MISSING = object()


class UIModule(types.ModuleType):
    def __init__(self) -> None:
        super().__init__("ui")
        self.led_calls = []
        self.callback_calls = []
        self.switch_reads = []
        self.switches = {}
        self.registered_callback = None

    def leds(self, fx_pos, sam_pos):
        self.led_calls.append((fx_pos, sam_pos))

    def callback(self, callback):
        self.callback_calls.append(callback)
        self.registered_callback = callback if callable(callback) else None

    def sw(self, index):
        self.switch_reads.append(index)
        return self.switches.get(index, 1)

    def set_switch(self, index, value):
        self.switches[index] = value


class SPLModule(types.ModuleType):
    def __init__(self) -> None:
        super().__init__("spl")
        self.trigger_calls = []
        self.load_wav_calls = []
        self.rom_calls = []
        self.load_wav_results = []
        self.default_load_wav_result = True

    def trigger(self, channel, sample_position, enabled):
        self.trigger_calls.append((channel, sample_position, enabled))

    def load_wav(self, position, file_obj, playmode):
        self.load_wav_calls.append((position, file_obj, playmode))
        if self.load_wav_results:
            return self.load_wav_results.pop(0)
        return self.default_load_wav_result

    def rom(self, position):
        self.rom_calls.append(position)


class FXModule(types.ModuleType):
    _KNOWN_FUNCTIONS = (
        "preset_mods_disable",
        "preset",
        "preset_param",
        "preset_handle",
        "preset_shake",
        "preset_lfo",
        "preset_trigger_row",
        "load_preset",
    )

    def __init__(self) -> None:
        super().__init__("fx")
        self.calls = []
        for name in self._KNOWN_FUNCTIONS:
            setattr(self, name, self._make_recorder(name))

    def _make_recorder(self, name):
        def recorder(*args, **kwargs):
            self.calls.append((name, args, kwargs))

        return recorder

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        recorder = self._make_recorder(name)
        setattr(self, name, recorder)
        return recorder

    def calls_for(self, name):
        return [args for call_name, args, _kwargs in self.calls if call_name == name]


class VFSModule(types.ModuleType):
    def __init__(self) -> None:
        super().__init__("vfs")
        self.calls = []
        owner = self

        class VfsFat:
            def __init__(self, block_device):
                self.block_device = block_device
                owner.calls.append(("VfsFat", (block_device,), {}))

            @staticmethod
            def mkfs(block_device):
                owner.calls.append(("VfsFat.mkfs", (block_device,), {}))

        self.VfsFat = VfsFat

    def umount(self, path):
        self.calls.append(("umount", (path,), {}))

    def mount(self, filesystem, path):
        self.calls.append(("mount", (filesystem, path), {}))


class RP2Module(types.ModuleType):
    def __init__(self) -> None:
        super().__init__("rp2")
        self.calls = []
        owner = self

        class Flash:
            def __init__(self):
                owner.calls.append(("Flash", (), {}))

        self.Flash = Flash


class TingSim:
    """Exec a Ting main-script source file under desktop mocks."""

    def __init__(self, source_path=None, source_text=None) -> None:
        if source_path is None and source_text is None:
            raise ValueError("source_path or source_text is required")

        self.source_path = os.fspath(source_path) if source_path is not None else "<ting-main>"
        if source_text is None:
            with open(self.source_path, "r", encoding="utf-8") as source_file:
                source_text = source_file.read()

        self.ui = UIModule()
        self.spl = SPLModule()
        self.fx = FXModule()
        self.vfs = VFSModule()
        self.rp2 = RP2Module()
        self.modules = {
            "ui": self.ui,
            "spl": self.spl,
            "fx": self.fx,
            "vfs": self.vfs,
            "rp2": self.rp2,
        }
        self.globals = {
            "__builtins__": builtins.__dict__,
            "__file__": self.source_path,
            "__name__": "__ting_main__",
        }

        code = compile(source_text, self.source_path, "exec")
        with self._installed_modules():
            exec(code, self.globals)

    @contextlib.contextmanager
    def _installed_modules(self):
        previous_modules = {}
        for name, module in self.modules.items():
            previous_modules[name] = sys.modules.get(name, _MISSING)
            sys.modules[name] = module

        original_chdir = os.chdir

        def guarded_chdir(path):
            if path == "/fat":
                raise OSError("desktop TingSim does not mount /fat")
            return original_chdir(path)

        os.chdir = guarded_chdir
        try:
            yield
        finally:
            os.chdir = original_chdir
            for name, previous in previous_modules.items():
                if previous is _MISSING:
                    sys.modules.pop(name, None)
                else:
                    sys.modules[name] = previous

    @staticmethod
    def message(message_type, value=0):
        return (message_type << 16) | (value & 0xFFFF)

    def set_switch(self, index, value):
        self.ui.set_switch(index, value)

    def inject_message(self, message):
        callback = self.ui.registered_callback or self.globals.get("python_callback")
        if not callable(callback):
            raise RuntimeError("firmware did not register python_callback")
        with self._installed_modules():
            return callback(message)

    def press(self, value):
        return self.inject_message(self.message(1, value))

    def release(self, value):
        return self.inject_message(self.message(2, value))

    def tick(self, count=1):
        for _ in range(count):
            self.inject_message(self.message(3, 0))

    def analog(self, channel, reading):
        return self.inject_message(self.message(0x10 | (channel & 0x0F), reading))

    def get_global(self, name):
        return self.globals[name]
