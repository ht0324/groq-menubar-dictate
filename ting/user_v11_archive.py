# ting marker firmware v11 — direction-aware click starts, depth-confirmed stops.
#
# Lever geometry (measured 2026-07-04/05): ~3900 released, click DETENT at
# ~2900-3200 (shallow — fires on BOTH strokes), resting fingers ~1050-1150,
# full squeeze bottoms ~0-950 (typ. ~581).
#
# v10 post-mortem: treating any click as a start meant (a) the release
# upstroke re-click started a phantom right as the handle sprang back, and
# (b) a downstroke click-start at ~3000 was killed 82 ms later by the next
# >2800 reading. v9's re-arm rule also suppressed ~40% of real squeezes
# (every suppressed reading was ~581 = a genuine squeeze; bounces and
# finger-rests never go below ~1050), so re-arm is gone entirely.
#
# Start: click PRESS while the lever moves DOWN (or still reads near rest —
#        a snap squeeze outruns the adc stream), or lever < 600.
# Stop:  lever > 2800, only after the squeeze was confirmed by a < 2000
#        reading (so a shallow click-start cannot stop instantly).

SQUEEZE_BELOW = 600
RELEASE_ABOVE = 2800
CONFIRM_BELOW = 2000
FROM_REST_ABOVE = 3400
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

_start_ok = _load(2, 'marker_start.wav')
_stop_ok = _load(3, 'marker_stop.wav')
_log('v11 markers loaded start=%d stop=%d' % (_start_ok, _stop_ok))

# Load confirmation must NOT be a marker tone (the app would hear a start
# marker and begin a phantom capture on every deploy) — use factory sample 0.
pulse(0)

# state: [squeezed, stop_confirmed, last_adc, prev_adc]; squeezed is None
# until the first adc2 reading so a (re)load never emits a marker by itself.
_st = [None, 0, -1, -1]

def _start(v, why):
    _st[0] = 1
    _st[1] = 1 if 0 <= v < CONFIRM_BELOW else 0
    pulse(2)
    _log('marker start %s v=%d' % (why, v))

def _mark(m):
    t = m >> 16
    v = m & 0xFFFF
    if t & 0xF0 == 0x10:
        if (t & 0x0F) != ADC_CHANNEL:
            return
        _st[3] = _st[2]
        _st[2] = v
        if _st[0] is None:
            _st[0] = 1 if v < SQUEEZE_BELOW else 0
            _st[1] = 1 if v < CONFIRM_BELOW else 0
            _log('adc2 initial v=%d squeezed=%d' % (v, _st[0]))
            return
        if _st[0] == 0:
            if v < SQUEEZE_BELOW:
                _start(v, 'lever')
        else:
            if not _st[1] and v < CONFIRM_BELOW:
                _st[1] = 1
            elif _st[1] and v > RELEASE_ABOVE:
                _st[0] = 0
                _st[1] = 0
                pulse(3)
                _log('marker stop v=%d' % v)
    elif v == 4 and t in (1, 2):
        if t == 1 and _st[0] != 1:
            last, prev = _st[2], _st[3]
            moving_down = prev >= 0 and last >= 0 and last < prev
            from_rest = last < 0 or last > FROM_REST_ABOVE
            if moving_down or from_rest:
                _start(last if last >= 0 else 0, 'click')
            else:
                # Upstroke re-click at the shallow detent during release.
                _log('click ignored (upstroke) last=%d prev=%d' % (last, prev))
        elif t == 1:
            _log('click press (already recording)')
        else:
            _log('click release (telemetry only)')

user_cb = _mark
