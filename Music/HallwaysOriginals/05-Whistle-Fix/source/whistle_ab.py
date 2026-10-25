import sys, os, numpy as np, soundfile as sf
from scipy.signal import resample_poly
sys.path.insert(0, "/home/claude/lab"); sys.path.insert(0, "/home/claude/lab/voice")
import mix_voice as M
from labkit import midi_for, render, SR
OUT = "/home/claude/lab/deliver/05-Whistle-Fix"; os.makedirs(OUT, exist_ok=True); M.OUT = OUT
def load(p):
    x, sr = sf.read(p); return resample_poly(x, 147, 160) if sr == 48000 else x
cut = int(12.5 * SR)
band = render(midi_for(M.band(), [(0, M.BPM)], 36), cut, sfont=M.MS)
band = band * 10 ** ((-26 - M.rms(band)) / 20)
def voice(x, lvl=-22.0, pan=0.0):
    x = x[:cut]; return M.place(x * 10 ** ((lvl - M.rms(x)) / 20), pan)
for tag, before, after, withband in [("1-soul singer with band", "raw/soul.wav", "fixed/soul.wav", True),
                                     ("2-crooner alone", "raw/crooner.wav", "fixed/crooner.wav", False),
                                     ("3-two singers (soul + harmony)", None, None, False),
                                     ("4-sinsy raw (resynthesized, no expression)", "fixed/lead-raw-world-nofix.wav", "fixed/lead-raw-world-fixed.wav", False)]:
    if before is None:
        b = voice(load("raw/soul.wav"), pan=-.15) + voice(load("raw/harmony.wav"), -24.5, .2)
        a = voice(load("fixed/soul.wav"), pan=-.15) + voice(load("fixed/harmony.wav"), -24.5, .2)
    else:
        b, a = voice(load(before)), voice(load(after))
        if withband: b, a = b + band, a + band
    M.write(f"{tag} - BEFORE", b); M.write(f"{tag} - AFTER", a)
