# ting marker firmware v12 stop-only for EP-2350 / MicroPython RP2350.
# Why: start detection moved fully to Mac app; v7-v11 failed on click starts.
# Lever geometry: ~3900 released/rest; click ~2900-3200 unreliable both
# strokes; resting fingers ~1050-1150; full squeeze bottoms ~0-950 (typ. ~581).

ARM_BELOW = 2000
RELEASE_ABOVE = 2800
ADC_CHANNEL = 2
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
_stop_ok = _load(3, 'marker_stop.wav')
_log('v12 marker_stop loaded=%d' % _stop_ok)
# Load confirmation must NOT be a marker tone.
try:
    pulse(0)
except:
    pass
# state: [armed, last_adc]; armed is None until the first adc2 reading.
_st = [None, -1]
def _mark(m):
    try:
        t = m >> 16
        v = m & 0xFFFF
        if (t & 0xF0) == 0x10 and (t & 0x0F) == ADC_CHANNEL:
            _st[1] = v
            if _st[0] is None:
                _st[0] = 1 if v < ARM_BELOW else 0
                _log('adc2 initial v=%d armed=%d' % (v, _st[0]))
                return
            if not _st[0] and v < ARM_BELOW:
                _st[0] = 1
                _log('armed v=%d' % v)
            elif _st[0] and v > RELEASE_ABOVE:
                # Disarm before the 80 ms pulse so a callback that lands
                # mid-pulse cannot fire a second stop.
                _st[0] = 0
                pulse(3)
                _log('marker stop v=%d' % v)
        elif v == 4 and t in (1, 2):
            name = 'press' if t == 1 else 'release'
            _log('click %s v_last=%d' % (name, _st[1]))
    except:
        pass
user_cb = _mark
