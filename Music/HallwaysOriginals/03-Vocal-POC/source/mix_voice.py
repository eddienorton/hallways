"""Vocal proof of concept: the sung parts over a small soul-ballad band, and the listening files."""
import os, sys, subprocess, wave
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly, fftconvolve

sys.path.insert(0, "/home/claude/lab"); sys.path.insert(0, "/home/claude/lab/voice")
from labkit import Part, n, voicing, midi_for, render, SR
import sing as S

MS = "/usr/share/sounds/sf3/MuseScore_General_Full.sf3"
OUT = "/home/claude/lab/deliver/03-Vocal-POC"
os.makedirs(OUT, exist_ok=True)
BPM = S.BPM
CH = [("F",), ("Dm7",), ("Bbmaj7",), ("Am7",), ("F",), ("Gm7",), ("C7",), ("F",)]
LEAD_IN = 0                                  # the vocal score starts on bar 1 with a beat's rest


def band():
    ep = Part("electric piano", "ep", 4, 0, vol=92, pan=54, reverb=40, swing=0)
    bs = Part("bass", "bass", 33, 1, vol=104, pan=64, reverb=15, swing=0)
    dr = Part("brushes", "drums", 40, 9, vol=84, pan=64, reverb=30, swing=0)
    for i, (sym,) in enumerate(CH):
        b0 = i * 4
        v = voicing(sym if sym != "F" else "Fmaj7", 0, lo=n("E3"), hi=n("A4"))
        for beat, dur, vel in [(0, 1.4, 56), (1.5, 0.45, 44), (2, 1.9, 50)]:
            for k, m in enumerate(v):
                ep.add(b0 + beat + k * 0.012, dur, m, vel, swing=False, bpm=BPM)
        root = n({"F": "F2", "Dm7": "D2", "Bbmaj7": "Bb1", "Am7": "A1", "Gm7": "G1", "C7": "C2"}[sym])
        for beat, m, dur in [(0, root, 1.4), (1.5, root + 7, 0.45), (2, root + 12 if root < n("D2") else root, 1.5), (3.5, root + 7, 0.45)]:
            bs.add(b0 + beat, dur, m, 78, swing=False, bpm=BPM)
        for beat in range(4):
            dr.add(b0 + beat, 0.9, 42 if beat % 2 == 0 else 38, 34 if beat % 2 == 0 else 46, swing=False, bpm=BPM)  # brush hat / swish snare
            dr.add(b0 + beat + 0.5, 0.4, 42, 26, swing=False, bpm=BPM)
        dr.add(b0, 0.5, 36, 40, swing=False, bpm=BPM)
    end = 32
    for m in [n("F2"), n("A3"), n("C4"), n("E4"), n("G4")]:
        ep.add(end, 3.5, m, 52, swing=False, bpm=BPM)
    bs.add(end, 3.5, n("F1"), 70, swing=False, bpm=BPM)
    return [ep, bs, dr]


def reverb_ir(sr, rt=1.5, pre=0.02, seed=3):
    rng = np.random.default_rng(seed)
    L = int(sr * rt * 1.2)
    t = np.arange(L) / sr
    env = np.exp(-6.9 * t / rt)
    ir = np.zeros((L + int(pre * sr), 2))
    for c in range(2):
        ir[int(pre * sr):, c] = rng.standard_normal(L) * env
    ir /= np.sqrt((ir ** 2).sum(axis=0, keepdims=True))
    return ir


IR = reverb_ir(SR)


def place(mono, pan=0.0, wet=0.22):
    """mono voice -> stereo, panned (-1..1), with a little room."""
    l, r = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
    dry = np.stack([mono * l, mono * r], 1)
    w = np.stack([fftconvolve(mono, IR[:, c])[: len(mono)] for c in range(2)], 1)
    return dry + wet * w


def rms(x):
    return 20 * np.log10(np.sqrt(np.mean(x.astype(np.float64) ** 2)) + 1e-12)


def write(name, x, target=-19.0):
    x = x * 10 ** ((target - rms(x)) / 20)
    pk = np.abs(x).max()
    if pk > 10 ** (-1 / 20):
        x = x * 10 ** (-1 / 20) / pk
    x = x.copy(); f = int(0.02 * SR); x[:f] *= np.linspace(0, 1, f)[:, None]
    tmp = "/tmp/_v.wav"
    with wave.open(tmp, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(np.clip(x * 32767, -32768, 32767).astype(np.int16).tobytes())
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp, "-c:a", "aac", "-b:a", "256k", f"{OUT}/{name}.m4a"], check=True)
    print(name, f"{len(x) / SR:.1f}s")


if __name__ == "__main__":
    def load(f):
        x, sr = sf.read(f"/home/claude/lab/voice/raw/{f}.wav")
        return resample_poly(x, 147, 160) if sr == 48000 else x       # 48 kHz -> 44.1 kHz
    V = {f: load(f) for f in ["lead", "soul", "crooner", "harmony", "harmony-low"]}
    T = len(V["soul"])
    parts = band()
    B = render(midi_for(parts, [(0, BPM)], 36), T, sfont=MS)
    Bg = 10 ** ((-26 - rms(B)) / 20)                          # the band under the voice
    B = B * Bg
    def v(name, lvl=-22.0, pan=0.0):
        x = V[name] * 10 ** ((lvl - rms(V[name][V[name] != 0] if np.any(V[name]) else V[name])) / 20)
        return place(x, pan)
    write("00-sinsy-raw (no processing, for comparison)", place(V["lead"] * 10 ** ((-22 - rms(V["lead"])) / 20)))
    write("01-soul singer alone", v("soul"))
    write("02-crooner alone", v("crooner"))
    write("03-harmony singer alone", v("harmony"))
    write("04-two singers - soul + harmony", v("soul", pan=-0.15) + v("harmony", -24.5, 0.2))
    write("05-two singers - crooner + low harmony", v("crooner", pan=-0.15) + v("harmony-low", -24.5, 0.2))
    write("06-band alone", B)
    write("07-soul singer with band", v("soul") + B)
    write("08-crooner with band", v("crooner") + B)
    write("09-full - soul + harmony + band", v("soul", pan=-0.1) + v("harmony", -24.5, 0.2) + B)
    write("10-full - crooner + low harmony + band", v("crooner", pan=-0.1) + v("harmony-low", -24.5, 0.2) + B)
    midi_for(parts, [(0, BPM)], 36, name="Lunamore -- band").save(f"{OUT}/band.mid")
