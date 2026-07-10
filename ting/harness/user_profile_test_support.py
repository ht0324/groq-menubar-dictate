"""Shared desktop helpers for exercising Ting ``user.py`` profiles."""


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

    def load_wav(self, slot, file_obj, mode):
        self.load_wav_calls.append((slot, file_obj.path, mode))
        return True

    def trigger(self, channel, slot, gate):
        self.trigger_calls.append((channel, slot, gate))


def load_user_profile(source_path, marker_paths):
    """Exec one user profile with deterministic ``spl`` and ``/fat`` mocks."""

    spl = MockSpl()
    logs = []
    allowed_paths = set(marker_paths)

    def mock_open(path, mode="r"):
        if path not in allowed_paths:
            raise OSError(path)
        return MockFatFile(path, mode)

    def mock_print(*args):
        logs.append(" ".join(str(arg) for arg in args))

    env = {"spl": spl, "open": mock_open, "print": mock_print}
    source = source_path.read_text(encoding="utf-8")
    exec(compile(source, str(source_path), "exec"), env)
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
