"""PP 6 placeholder critter voices -- additive formant synthesis (numpy only). Original sounds, no samples used.
Each: mono, 44.1 kHz, 16-bit PCM WAV, peak -3 dBFS, a few ms of fade at both ends."""
import numpy as np, wave, sys
SR = 44100
rng = np.random.default_rng(6)

def interp(points, n):
    """points: [(t_seconds, value)] -> per-sample array (linear)."""
    t = np.arange(n) / SR
    ts, vs = zip(*points)
    return np.interp(t, ts, vs)

def voice(dur, f0pts, formants, amp_pts, vib=(0, 0, 0), breath=0.02, bursts=()):
    n = int(dur * SR)
    t = np.arange(n) / SR
    f0 = interp(f0pts, n)
    rate, cents, onset = vib
    if cents:
        depth = np.clip((t - onset) / 0.12, 0, 1) * cents
        f0 = f0 * 2 ** (depth * np.sin(2 * np.pi * rate * t) / 1200)
    phase = 2 * np.pi * np.cumsum(f0) / SR
    F = [(interp(fp, n), interp(bp, n), interp(ap, n)) for fp, bp, ap in formants]
    out = np.zeros(n)
    kmax = int(6000 / f0.min())
    for k in range(1, kmax + 1):
        fk = k * f0
        g = sum(a / (1 + ((fk - Fc) / (B / 2)) ** 2) for Fc, B, a in F) + 0.004
        g = g * (fk < 7000)
        out += g / k * np.sin(k * phase)
    # breath: noise shaped by the first two formants (cheap: band-limited by a moving average)
    noise = rng.standard_normal(n)
    noise = np.convolve(noise, np.ones(6) / 6, mode="same")
    out = out / (np.abs(out).max() + 1e-9) + breath * noise
    for (at, length, level) in bursts:                        # consonant releases (d, b, p)
        i, m = int(at * SR), int(length * SR)
        b = rng.standard_normal(m) * np.exp(-np.linspace(0, 6, m)) * level
        out[i:i + m] += b
    out *= interp(amp_pts, n)
    fade = int(0.004 * SR)
    out[:fade] *= np.linspace(0, 1, fade); out[-fade:] *= np.linspace(1, 0, fade)
    return out / np.abs(out).max() * 10 ** (-3 / 20)

def write(name, x):
    with wave.open(name, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())
    print(name, f"{len(x)/SR:.3f}s")

def midi_hz(m): return 440 * 2 ** ((m - 69) / 12)

# 1. "doo" -- sung, a steady A3 (220 Hz) with a gentle late vibrato: the clearly pitched one.
A3 = midi_hz(57)
write("voice-doo-A3.wav", voice(0.60,
    [(0, A3 * 0.985), (0.04, A3), (0.6, A3)],
    [([(0, 400), (0.05, 320)], [(0, 90)], [(0, 1)]),
     ([(0, 1700), (0.06, 870)], [(0, 110)], [(0, 0.45)]),
     ([(0, 2600), (0.06, 2240)], [(0, 150)], [(0, 0.18)])],
    [(0, 0), (0.012, 0.9), (0.08, 1), (0.42, 0.85), (0.6, 0)],
    vib=(5.5, 14, 0.22), breath=0.015, bursts=[(0.0, 0.010, 0.25)]))

# 2. "meep" -- a small high critter, E5 after a quick scoop up; ends on a closed "p".
E5 = midi_hz(76)
write("voice-meep-E5.wav", voice(0.32,
    [(0, E5 * 2 ** (-2.5 / 12)), (0.045, E5), (0.32, E5)],
    [([(0, 300), (0.03, 280)], [(0, 80)], [(0, 1)]),
     ([(0, 2000), (0.04, 2400)], [(0, 140)], [(0, 0.8)]),
     ([(0, 3000)], [(0, 200)], [(0, 0.3)])],
    [(0, 0), (0.008, 1), (0.2, 0.9), (0.27, 0.6), (0.285, 0), (0.32, 0)],
    breath=0.01, bursts=[(0.292, 0.012, 0.12)]))

# 3. "bum" -- a low, round A2 (110 Hz) that closes into a hummed "m".
A2 = midi_hz(45)
write("voice-bum-A2.wav", voice(0.55,
    [(0, A2 * 0.97), (0.03, A2), (0.55, A2 * 0.995)],
    [([(0, 350), (0.05, 640), (0.25, 620), (0.32, 260)], [(0, 100)], [(0, 1)]),
     ([(0, 900), (0.05, 1190), (0.25, 1150), (0.32, 1000)], [(0, 120), (0.3, 300)], [(0, 0.5), (0.3, 0.08)]),
     ([(0, 2390)], [(0, 160)], [(0, 0.2), (0.3, 0.02)])],
    [(0, 0), (0.01, 1), (0.25, 0.9), (0.32, 0.55), (0.5, 0.35), (0.55, 0)],
    breath=0.008, bursts=[(0.0, 0.008, 0.3)]))

# 4. "baby?" -- speech-like: two syllables, a gliding spoken pitch (no stable note), rising at the end.
write("voice-baby.wav", voice(0.62,
    [(0, 185), (0.20, 160), (0.30, 150), (0.36, 150), (0.62, 215)],
    [([(0, 300), (0.04, 560), (0.18, 420), (0.30, 300), (0.36, 300), (0.40, 290)], [(0, 90)], [(0, 1)]),
     ([(0, 1000), (0.05, 1850), (0.2, 2150), (0.3, 1200), (0.38, 2200), (0.6, 2300)], [(0, 120)], [(0, 0.55), (0.38, 0.7)]),
     ([(0, 2600), (0.36, 3000)], [(0, 180)], [(0, 0.2)])],
    [(0, 0), (0.012, 0.95), (0.20, 0.8), (0.27, 0.15), (0.31, 0.05), (0.33, 0.9), (0.55, 0.75), (0.62, 0)],
    breath=0.03, bursts=[(0.0, 0.008, 0.25), (0.315, 0.008, 0.25)]))
