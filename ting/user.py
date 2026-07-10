# ting marker firmware v13 lever-driven start+stop markers for EP-2350 / MicroPython RP2350.
# Why: start markers restored - lever proved reliable on hardware 2026-07-07;
# level-based start cannot work over the USB-tether noise floor.
# Lever geometry: ~3900 rest; finger-rest zone ~1050-1150 must not trigger;
# full squeeze bottoms ~0-950 (measured 0/202/227/379/581); release crossings ~2806-2831.

START_BELOW = 1000
RELEASE_ABOVE = 2800
ADC_CHANNEL = 2
IDLE = 0
DOWN = 1
try:
    pulse
except NameError:
    try:
        from time import sleep_ms as _slp
    except:
        def _slp(ms):
            pass
    def pulse(slot, ms=80):
        spl.trigger(-1, slot, True)
        _slp(ms)
        spl.trigger(-1, slot, False)
try:
    from time import ticks_ms as _now
except:
    import time
    def _now():
        return int(time.time() * 1000)
def _log(text):
    try:
        print('TING %d %s' % (_now(), text))
    except:
        pass
def _load(slot, name):
    try:
        f = open('/fat/' + name, 'rb')
        ok = spl.load_wav(slot, f, 'oneshot')
        f.close()
        return bool(ok)
    except:
        return False
_start_ok = _load(2, 'marker_start.wav')
_stop_ok = _load(3, 'marker_stop.wav')
_log('v13 markers loaded start=%d stop=%d' % (_start_ok, _stop_ok))
# Load confirmation must NOT be a marker tone.
try:
    pulse(0)
except:
    pass
# state: [lever_state, last_adc]; lever_state is None until the first adc2 reading.
_st = [None, -1]
def _mark(m):
    try:
        t = m >> 16
        v = m & 0xFFFF
        if (t & 0xF0) == 0x10 and (t & 0x0F) == ADC_CHANNEL:
            _st[1] = v
            if _st[0] is None:
                _st[0] = DOWN if v < START_BELOW else IDLE
                name = 'DOWN' if _st[0] == DOWN else 'IDLE'
                _log('adc2 initial v=%d state=%s' % (v, name))
                return
            if _st[0] == IDLE and v < START_BELOW:
                _st[0] = DOWN
                pulse(2)
                _log('marker start profile=v13 v=%d' % v)
            elif _st[0] == DOWN and v > RELEASE_ABOVE:
                # Return to IDLE before the 80 ms pulse so a callback that lands
                # mid-pulse cannot fire a second stop.
                _st[0] = IDLE
                pulse(3)
                _log('marker stop profile=v13 v=%d' % v)
        elif v == 4 and t in (1, 2):
            name = 'press' if t == 1 else 'release'
            _log('click %s v_last=%d' % (name, _st[1]))
    except:
        pass
user_cb = _mark
