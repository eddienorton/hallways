"""JUANITA SINGS -- auditions (prototype 2).

Juanita's wordless melody on the house band's timeline (84 bpm, 48 bars,
A A B B A' A', the same harmony as prototype 1), and Tinky's complement (the
kalimba ostinato, double bass and a softer pad from prototype 1).

Her melody is rendered as several CANDIDATE VOICES, each clearly labelled:
  whistle-modelled   a whistle synthesised here from a physical-ish model:
                     a near-pure tone with breath noise, tongue re-articulation,
                     scoops, slides and late vibrato. SYNTHETIC.
  hum-modelled       a closed-mouth "mmm" hum synthesised here: a glottal
                     source through nasal-murmur resonances, with breaths,
                     vibrato and jitter. SYNTHETIC.
  library-whistle    the General MIDI "Whistle" sample (FluidR3). SYNTHETIC.
  library-oohs       the General MIDI "Voice Oohs" sample (FluidR3). SYNTHETIC.
None of these is a recording of a person. A real hummed or whistled take,
recorded to the guide track this script also writes, would replace them.
"""
import importlib.util
import os
import subprocess
import sys
import wave

import numpy as np
from scipy import signal

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("hb", os.path.join(HERE, "house_band.py"))
hb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hb)

SR = hb.SR
BPM = hb.BPM
BEATS = hb.BEATS
L = hb.LOOP_SAMPLES
SPB = 60 / BPM                      # seconds per beat
rng = np.random.default_rng(7)

# ------------------------------------------------------------------ the melody (written at humming pitch)
A1 = [(.5, .5, "A3"), (1, .5, "D4"), (1.5, .5, "E4"), (2, 1.5, "F4"), (3.5, .5, "E4"),
      (4, 1, "D4"), (5, .5, "C4"), (5.5, .5, "D4"), (6, 2, "A3"),
      (8.5, .5, "A3"), (9, .5, "D4"), (9.5, .5, "E4"), (10, 1.5, "F4"), (11.5, .5, "G4"),
      (12, 1, "A4"), (13, .5, "G4"), (13.5, .5, "F4"), (14, 2, "E4"),
      (16.5, .5, "D4"), (17, .5, "F4"), (17.5, .5, "G4"), (18, 1.5, "A4"), (19.5, .5, "Bb4"),
      (20, 1, "A4"), (21, .5, "G4"), (21.5, .5, "F4"), (22, 2, "D4"),
      (24.5, .5, "C4"), (25, .5, "E4"), (25.5, .5, "F4"), (26, 1.5, "A4"), (27.5, .5, "G4"),
      (28, 1, "E4"), (29, 2, "D4")]
A2 = [(.5, .5, "D4"), (1, .5, "F4"), (1.5, .5, "A4"), (2, 2, "C5"),
      (4, 1, "A4"), (5, 1, "G4"), (6, 2, "F4"),
      (8.5, .5, "F4"), (9, .5, "A4"), (9.5, .5, "Bb4"), (10, 2, "D5"),
      (12, 1, "C5"), (13, .5, "Bb4"), (13.5, .5, "A4"), (14, 2, "F4"),
      (16.5, .5, "G4"), (17, .5, "Bb4"), (17.5, .5, "C5"), (18, 2, "D5"),
      (20, 1, "C5"), (21, 1, "Bb4"), (22, 2, "A4"),
      (24, 1.5, "G4"), (25.5, .5, "F4"), (26, 2, "E4"),
      (28, 1, "E4"), (29, 1, "D4"), (30, 1.6, "E4")]
B1 = [(.5, .5, "C4"), (1, 2.5, "D4"), (3.5, .5, "F4"),
      (4, 3, "E4"),
      (8.5, .5, "C4"), (9, .5, "E4"), (9.5, .5, "G4"), (10, 2, "A4"),
      (12, 1.5, "F4"), (13.5, .5, "E4"), (14, 2, "D4"),
      (17, .5, "Bb3"), (17.5, .5, "D4"), (18, 2, "F4"),
      (20, 1, "G4"), (21, 1, "F4"), (22, 2, "D4"),
      (24.5, .5, "E4"), (25, 1, "F4"), (26, 2, "A4"),
      (28, 3, "G4")]
B2 = [(2, 2, "F4"), (4, 2, "G4"), (6, 1, "E4"),
      (9, 2, "C5"), (11, 1, "B4"), (12, 3, "A4"),
      (20.5, .5, "F4"), (21, .5, "G4"), (21.5, .5, "Bb4"), (22, 2, "D5"),
      (24, 2, "C5"), (26, 2, "A4"), (28, 1, "G4"), (29, 1, "E4"), (30, 1.6, "D4")]
A2b = A2[:-3] + [(28, 3, "D4")]                   # the last unit: settles, a breath before the loop
MELODY = []
for unit, notes in enumerate([A1, A2, B1, B2, A1, A2b]):
    for b, d, name in notes:
        MELODY.append((unit * 32 + b, d, hb.n(name)))
MELODY.sort()

# phrase starts (beats): where she can resume after being interrupted
PHRASES = []
prev_end = -10
for b, d, m in MELODY:
    if b - prev_end >= 0.45:
        PHRASES.append(b)
    prev_end = max(prev_end, b + d)


def legato_groups(notes):
    """(start s, end s, midi, legato_from_previous)"""
    out = []
    prev_end = None
    for b, d, m in notes:
        s, e = b * SPB, (b + d) * SPB
        leg = prev_end is not None and s - prev_end < 0.03
        out.append((s, e, m, leg))
        prev_end = e
    return out


def smooth(x, ms):
    n = max(1, int(SR * ms / 1000))
    k = np.hanning(2 * n + 1)
    return np.convolve(x, k / k.sum(), mode="same")


def drift(total, cents, hz):
    """slow random pitch wander, in cents"""
    n = int(total / SR * hz) + 4
    pts = rng.normal(0, cents, n)
    return np.interp(np.arange(total) / SR * hz, np.arange(n), pts)


# ------------------------------------------------------------------ voice models
def pitch_and_amp(notes, total, transpose, scoop_c, vib_c, vib_hz, legato_dip, attack_ms, release_ms):
    cents = np.full(total, np.nan)
    amp = np.zeros(total)
    vib = np.zeros(total)
    for s, e, m, leg in legato_groups(notes):
        i0, i1 = int(s * SR), min(total, int(e * SR))
        if i1 <= i0:
            continue
        c = (m + transpose) * 100.0
        seg = np.full(i1 - i0, c)
        # onset: a scoop up into the note (detached), or a quick slide (legato)
        k = min(len(seg), int(SR * (0.045 if leg else 0.06)))
        start_off = (-scoop_c if not leg else 0)
        if k > 0 and not leg:
            seg[:k] += start_off * (1 - np.linspace(0, 1, k)) ** 2
        cents[i0:i1] = seg
        # amplitude
        a = np.ones(i1 - i0)
        ka = min(len(a), int(SR * attack_ms / 1000))
        if ka > 0:
            a[:ka] = (legato_dip if leg else 0) + (1 - (legato_dip if leg else 0)) * np.sin(np.linspace(0, np.pi / 2, ka)) ** 2
        kr = min(len(a) // 2, int(SR * release_ms / 1000))
        if kr > 0:
            a[-kr:] *= np.cos(np.linspace(0, np.pi / 2, kr)) ** 1.5
        dur = e - s
        a *= np.linspace(1.0, 0.86 if dur > 0.6 else 0.95, len(a))                 # breath runs down
        if dur > 0.9:
            a *= 1 + 0.08 * np.sin(np.linspace(0, np.pi, len(a)))                   # a small swell
        amp[i0:i1] = np.maximum(amp[i0:i1], a * (0.9 + 0.1 * (m - 57) / 17))
        # vibrato: arrives late, only on held notes
        if dur > 0.45:
            t = np.arange(i1 - i0) / SR
            depth = vib_c * np.clip((t - 0.22) / 0.35, 0, 1)
            rate = vib_hz * (1 + rng.uniform(-0.06, 0.06))
            vib[i0:i1] = depth * np.sin(2 * np.pi * rate * t + rng.uniform(0, 6.28))
    # glide between legato notes: fill the pitch track and smooth it (slides between notes)
    idx = np.where(~np.isnan(cents))[0]
    cents = np.interp(np.arange(total), idx, cents[idx]) if len(idx) else np.zeros(total)
    cents = smooth(cents, 14)
    cents += vib + drift(total, 4, 3)
    return cents, amp


def whistle(notes, total):
    cents, amp = pitch_and_amp(notes, total, transpose=24, scoop_c=55, vib_c=14, vib_hz=5.6,
                               legato_dip=0.35, attack_ms=22, release_ms=45)
    f = 8.1758 * 2 ** (cents / 1200)
    ph = 2 * np.pi * np.cumsum(f) / SR
    tone = np.sin(ph) + 0.035 * np.sin(2 * ph + 0.4) + 0.008 * np.sin(3 * ph)
    # breath: noise around the whistle's pitch (a moving band), plus a little broadband air
    wn = rng.normal(0, 1, total)
    band = np.zeros(total)
    for lo, hi in [(700, 1300), (1100, 1900), (1700, 2700)]:
        sos = signal.butter(2, [lo, hi], btype="band", fs=SR, output="sos")
        b = signal.sosfilt(sos, wn)
        centre = (lo + hi) / 2
        w = np.exp(-((np.log2(np.maximum(f, 1) / centre)) ** 2) / 0.08)
        band += b * w
    air = signal.sosfilt(signal.butter(2, [2500, 9000], btype="band", fs=SR, output="sos"), wn)
    a = smooth(amp, 6)
    x = tone * a + 0.10 * band * a + 0.012 * air * np.sqrt(a)
    # onset "chiff" (lip/tongue release) on detached notes
    for s, e, m, leg in legato_groups(notes):
        if leg:
            continue
        i0 = int(s * SR)
        k = int(SR * 0.012)
        if i0 + k < total:
            x[i0:i0 + k] += 0.05 * wn[i0:i0 + k] * np.hanning(k)
    return x


def hum(notes, total):
    cents, amp = pitch_and_amp(notes, total, transpose=0, scoop_c=35, vib_c=18, vib_hz=5.1,
                               legato_dip=0.82, attack_ms=45, release_ms=70)
    f = 8.1758 * 2 ** (cents / 1200)
    f *= 1 + 0.0025 * smooth(rng.normal(0, 1, total), 2)                          # jitter
    ph = 2 * np.pi * np.cumsum(f) / SR
    src = np.zeros(total)
    for k in range(1, 22):
        ak = (1 / k ** 1.45) * (f * k < 5000)
        src += ak * np.sin(k * ph + 0.3 * k)
    # nasal murmur: a strong low resonance, an anti-resonance, weak upper resonances
    def peak(x, fc, q, gain_db):
        b, a = signal.iirpeak(fc, q, fs=SR)
        return x + (10 ** (gain_db / 20) - 1) * signal.lfilter(b, a, x)
    y = peak(src, 280, 3.0, 9)
    b, a = signal.iirnotch(950, 2.2, fs=SR)
    y = signal.lfilter(b, a, y)
    y = peak(y, 2200, 6, 2)
    y = peak(y, 2750, 7, 1)
    y = signal.sosfilt(signal.butter(2, 3200, fs=SR, output="sos"), y)
    shimmer = 1 + 0.03 * smooth(rng.normal(0, 1, total), 8)
    a = smooth(amp, 10) * shimmer
    x = y * a
    # soft nasal in-breaths before phrases
    wn = rng.normal(0, 1, total)
    breath = signal.sosfilt(signal.butter(2, [300, 2200], btype="band", fs=SR, output="sos"), wn)
    for b in PHRASES + [p + BEATS for p in PHRASES]:                              # (both passes)
        i1 = int(b * SPB * SR)
        i0 = i1 - int(SR * 0.28)
        if i0 > 0:
            x[i0:i1] += 0.012 * breath[i0:i1] * np.hanning(i1 - i0)
    return x


def room_ir(rt60=0.55, seed=3):
    r = np.random.default_rng(seed)
    n = int(SR * rt60 * 1.4)
    t = np.arange(n) / SR
    out = []
    for ch in range(2):
        tail = r.normal(0, 1, n) * np.exp(-6.91 * t / rt60)
        tail = signal.sosfilt(signal.butter(1, 4500, fs=SR, output="sos"), tail)
        ir = np.zeros(n)
        ir[0] = 1.0
        for d, g in [(0.011, .5), (0.017, .4), (0.023, .32), (0.031, .25), (0.043, .2)]:
            ir[int((d + 0.002 * ch) * SR)] += g * r.choice([-1, 1])
        pd = int(0.014 * SR)
        ir[pd:] += 0.32 * tail[:n - pd]
        out.append(ir)
    return np.stack(out, axis=1)


IR = room_ir()


def in_room(x, wet=0.28, pan=0.0):
    dry = np.stack([x * (1 - pan) ** 0.5, x * (1 + pan) ** 0.5], axis=1) / np.sqrt(2)
    w = np.stack([signal.fftconvolve(x, IR[:, c])[:len(x)] for c in range(2)], axis=1)
    return dry * (1 - wet) + w * wet * 0.6


def two_pass(fn):
    """render the melody twice end to end, keep the second pass (tails wrap round)"""
    notes = MELODY + [(b + BEATS, d, m) for b, d, m in MELODY]
    x = fn(notes, 2 * L + SR)
    return x[L:2 * L]


def write(path, x):
    pcm = np.clip(x * 32767, -32768, 32767).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def m4a(wav, out):
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-c:a", "aac", "-b:a", "256k", out], check=True)


def rms(x):
    return 20 * np.log10(np.sqrt(np.mean(x.astype(np.float64) ** 2)) + 1e-12)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "juanita-out"
    os.makedirs(out, exist_ok=True)
    voices = {}
    voices["whistle-modelled"] = in_room(two_pass(whistle), wet=0.30, pan=-0.1)
    print("whistle done")
    voices["hum-modelled"] = in_room(two_pass(hum), wet=0.26, pan=-0.1)
    print("hum done")
    # library voices (General MIDI)
    for name, prog, tr in [("library-whistle", 78, 24), ("library-oohs", 53, 0)]:
        t = hb.Track(f"Juanita -- {name}", prog, 4, vol=100, pan=58, reverb=55)
        for b, d, m in MELODY:
            t.add(b, d * 0.98, m + tr, 78)
        two = hb.render(hb.midi_for([t], repeats=2), 2 * L)
        voices[name] = two[L:]
        print(name, "done")
    # Tinky's complement: prototype 1's kalimba, double bass and a softer pad (+ a whisper of shaker)
    hb.pad.vol = 60
    hb.perc.vol = 64
    tinky = hb.render(hb.midi_for([hb.kal, hb.bass, hb.pad, hb.perc], repeats=2), 2 * L)[L:]
    np.save(os.path.join(out, "voices.npy"), np.stack([voices[k] for k in voices]))
    np.save(os.path.join(out, "tinky.npy"), tinky)
    with open(os.path.join(out, "voices.txt"), "w") as fh:
        fh.write("\n".join(voices.keys()))
    # the melody as MIDI (for a guide / re-rendering), and the phrase starts
    t = hb.Track("Juanita -- melody (hum pitch; whistle sounds two octaves up)", 73, 4)
    for b, d, m in MELODY:
        t.add(b, d, m, 80)
    hb.midi_for([t], name="Juanita -- melody").save(os.path.join(out, "juanita-melody.mid"))
    with open(os.path.join(out, "phrases.txt"), "w") as fh:
        fh.write(" ".join(f"{b:g}" for b in PHRASES))
    print("phrases", len(PHRASES))
