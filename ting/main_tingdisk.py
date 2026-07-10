# Tracked TINGDISK main.py override; remove the device's main.py to revert.
import os
import json
import ui
import spl
import fx

sam_pos = 0
fx_pos = -1
sam_primed = 0
fx_primed = 0
ui.leds(fx_pos,sam_pos)
ui.callback(0)

def examine_drive(mount):
    if mount == True:
        import vfs,rp2
        bdev = rp2.Flash()
        vfs.umount("/fat")
        try:
            vfs.mount(vfs.VfsFat(bdev), "/fat")
        except:
            vfs.VfsFat.mkfs(bdev)
            vfs.mount(vfs.VfsFat(bdev), "/fat")
        del vfs, bdev

    json_loaded = False
    try:
        os.chdir('/fat')
        try:
            f = open('config.json','r')
            d = json.load(f)
            f.close()
            json_loaded = True
        except:
            try:
                f = open('1.wav','rb')
                spl.load_wav(0,f,0)
                f.close()
            except:
                spl.rom(0)
            try:
                f = open('2.wav','rb')
                spl.load_wav(1,f,0)
                f.close()
            except:
                spl.rom(1)
            try:
                f = open('3.wav','rb')
                spl.load_wav(2,f,0)
                f.close()
            except:
                spl.rom(2)
            try:
                f = open('4.wav','rb')
                spl.load_wav(3,f,0)
                f.close()
            except:
                spl.rom(3)
    except:
        spl.rom(0)
        spl.rom(1)
        spl.rom(2)
        spl.rom(3)

    if json_loaded == True:
        spl.rom(0)
        spl.rom(1)
        spl.rom(2)
        spl.rom(3)
        for i in range(4):
            try:
                pos = d.get('samples')[i].get('pos')
                if (pos >= 4) or (pos < 0):
                    pos = i
            except:
                pos = i

            try:
                g=open(d.get('samples')[i].get('file'),'rb')

                try:
                    pm = d.get('samples')[i].get('playmode')
                except:
                    pm = 'oneshot'
                if pm is None:
                    pm = 'oneshot'
                if not spl.load_wav(pos,g,pm):
                    spl.rom(pos)
                g.close()
            except:
                pass

        try:
            n = len(d.get('presets'))
        except:
            n = 0

        for i in range(n):
            try:
                pos = d.get('presets')[i].get('pos')
                if (pos >= 4) or (pos < 0):
                    pos = i
            except:
                pos = i

            fx.preset_mods_disable(pos)

            for j in range (16):
                try:
                    l = d.get('presets')[i].get('list')[j]
                except:
                    fx.preset(pos,j,'END')
                    break
                try:
                    effect = l.get('effect')
                except:
                    fx.preset(pos,j,'END')
                    break

                fx.preset(pos,j,effect)
                for key, value in l.items():
                    if key != 'effect':
                        fx.preset_param(pos,j,key,float(value))

            if d.get('presets')[i].get('handle'):
                try:
                    value = d.get('presets')[i].get('handle').get('row')
                    fx.preset_handle(pos,'row',value)
                    l = d.get('presets')[i].get('handle')
                    for key, value in l.items():
                        fx.preset_handle(pos,key,value)
                except:
                    fx.preset_handle(pos,'row',-1)

            if d.get('presets')[i].get('shake'):
                try:
                    value = d.get('presets')[i].get('shake').get('row')
                    fx.preset_shake(pos,'row',value)
                    l = d.get('presets')[i].get('shake')
                    for key, value in l.items():
                        fx.preset_shake(pos,key,value)
                except:
                    fx.preset_shake(pos,'row',-1)

            if d.get('presets')[i].get('lfo'):
                try:
                    value = d.get('presets')[i].get('lfo').get('row')
                    fx.preset_lfo(pos,'row',value)
                    l = d.get('presets')[i].get('lfo')
                    for key, value in l.items():
                        fx.preset_lfo(pos,key,value)
                except:
                    fx.preset_lfo(pos,'row',-1)

            try:
                fx.preset_trigger_row(pos,d.get('presets')[i].get('trigger').get('row'))
            except:
                pass

examine_drive(False)

fx.load_preset(fx_pos)

user_cb = None
try:
    from time import sleep_ms as _slp
except:
    def _slp(ms): pass
def pulse(slot, ms=80):
    spl.trigger(-1,slot,True)
    _slp(ms)
    spl.trigger(-1,slot,False)
def load_user():
    try:
        f = open('/fat/user.py')
        s = f.read()
        f.close()
    except:
        return
    try:
        exec(s, globals())
    except:
        pulse(3)
pulse(1)  # boot signature: TINGDISK main.py is executing
load_user()

def python_callback(message):
    global sam_pos
    global fx_pos
    global sam_primed
    global fx_primed
    if user_cb:
        try:
            user_cb(message)
        except:
            pass
    mess_type = message >> 16
    mess_val = message & 0xFFFF

    if mess_type == 1:

        if mess_val == 0:
            spl.trigger(-1,sam_pos,True)

        if mess_val == 1:
            if ui.sw(4) == 0:
                sam_primed = 10

        if mess_val == 2:
            if ui.sw(4) == 0:
                fx_primed = 10

    if mess_type == 2:

        if mess_val == 0:
            spl.trigger(-1,sam_pos,False)

        if mess_val == 1:
            sam_primed = 0

        if mess_val == 2:
            fx_primed = 0

    if mess_type == 3:
        if fx_primed > 0:
            fx_primed = fx_primed - 1
            if fx_primed == 0:
                fx_pos = fx_pos + 1
                if(fx_pos >= 4):
                    fx_pos = -1
                fx.load_preset(fx_pos)
                ui.leds(fx_pos,sam_pos)

        if sam_primed > 0:
            sam_primed = sam_primed - 1
            if sam_primed == 0:
                sam_pos = sam_pos + 1
                if sam_pos >= 4:
                    sam_pos = 0
                ui.leds(fx_pos,sam_pos)

    if mess_type == 4:
            if mess_val == 1:
                # print("ejected")
                examine_drive(mount = True)
                fx.load_preset(fx_pos)
                load_user()

    if mess_type & 0xF0 == 0x10:
        adc = mess_type & 0x0F
        # print(f"adc {adc} {mess_val}")


ui.callback(python_callback)
