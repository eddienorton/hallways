"""Black Box synth -- Python reference for BlackBoxMusic.swift (numpy)."""
import numpy as np
from compose import tick_time

SR = 44100


def mtof(m):
    return 440.0 * 2 ** ((m - 69) / 12.0)


def gate(t, dur, rel):
    g = np.ones_like(t)
    after = t > dur
    g[after] = np.clip(1 - (t[after] - dur) / rel, 0, 1)
    return g


def attack(t, a):
    return np.clip(t / a, 0, 1)


def phase_of(freq_inst):
    return 2 * np.pi * np.cumsum(freq_inst) / SR


class Noise:
    def __init__(self, seed):
        self.r = np.random.default_rng(seed)

    def white(self, n):
        return self.r.uniform(-1, 1, n)


def voice(inst, midi, dur, vel, noise):
    f = mtof(midi)
    if inst == 'square':
        rel = 0.07
        n = int((dur + rel) * SR)
        t = np.arange(n) / SR
        vib = 1 + 0.0045 * np.sin(2 * np.pi * 5.5 * t) * np.clip((t - 0.12) / 0.2, 0, 1)
        ph = phase_of(f * vib)
        y = np.zeros(n)
        for h in (1, 3, 5, 7, 9):
            if h * f > 14000:
                break
            y += np.sin(h * ph) / h * np.exp(-(h - 1) / 4.0)
        env = attack(t, 0.006) * (0.55 + 0.45 * np.exp(-t / 0.12)) * gate(t, dur, rel)
        return y * env * 0.75 * vel
    if inst == 'whistle':
        rel = 0.09
        n = int((dur + rel) * SR)
        t = np.arange(n) / SR
        vib = 1 + 0.006 * np.sin(2 * np.pi * 5.2 * t) * np.clip((t - 0.15) / 0.25, 0, 1)
        ph = phase_of(f * vib)
        y = np.sin(ph) + 0.12 * np.sin(2 * ph) + 0.03 * np.sin(3 * ph)
        br = noise.white(n)
        # one-pole lowpass on the breath
        a = 0.25
        out = np.empty(n)
        acc = 0.0
        for i in range(n):
            acc += a * (br[i] - acc)
            out[i] = acc
        y += out * 0.12 * np.exp(-t / 0.08)
        env = attack(t, 0.03) * (0.85 + 0.15 * np.exp(-t / 0.1)) * gate(t, dur, rel)
        return y * env * 0.8 * vel
    if inst == 'marimba':
        rel = 0.05
        length = min(dur + 0.6, 1.4)
        n = int(length * SR)
        t = np.arange(n) / SR
        ph = 2 * np.pi * f * t
        tau = min(0.6, max(0.18, 0.5 * (440.0 / f) ** 0.4))
        y = np.sin(ph) + 0.22 * np.sin(3.93 * ph) * np.exp(-t / 0.04) + 0.06 * np.sin(9.2 * ph) * np.exp(-t / 0.012)
        env = attack(t, 0.002) * np.exp(-t / tau)
        return y * env * 0.95 * vel
    if inst == 'bell':
        rel = 0.25
        n = int((min(dur, 1.2) + 0.9) * SR)
        t = np.arange(n) / SR
        ph = 2 * np.pi * f * t
        y = np.sin(ph + 1.4 * np.exp(-t / 0.05) * np.sin(4 * ph)) + 0.12 * np.sin(2 * ph) * np.exp(-t / 0.3)
        env = attack(t, 0.002) * np.exp(-t / 0.75) * gate(t, min(dur, 1.2) + 0.6, rel)
        return y * env * 0.8 * vel
    if inst == 'vibes':
        rel = 0.25
        n = int((dur + rel + 0.3) * SR)
        t = np.arange(n) / SR
        ph = 2 * np.pi * f * t
        y = (np.sin(ph) + 0.15 * np.sin(4 * ph) * np.exp(-t / 0.3) + 0.05 * np.sin(10 * ph) * np.exp(-t / 0.02))
        trem = 1 + 0.28 * np.sin(2 * np.pi * 5.2 * t)
        env = attack(t, 0.002) * np.exp(-t / 1.3) * gate(t, dur + 0.3, rel)
        return y * trem * env * 0.8 * vel
    if inst == 'epiano':
        rel = 0.12
        n = int((dur + rel) * SR)
        t = np.arange(n) / SR
        ph = 2 * np.pi * f * t
        index = 1.3 * np.exp(-t / 0.25) + 0.25
        y = np.sin(ph + index * np.sin(ph)) + 0.08 * np.sin(14 * ph) * np.exp(-t / 0.015)
        tau = 1.6 * (261.6 / f) ** 0.4
        env = attack(t, 0.003) * np.exp(-t / tau) * gate(t, dur, rel)
        return y * env * 0.5 * vel
    if inst == 'pluck':
        rel = 0.06
        n = int((dur + rel) * SR)
        t = np.arange(n) / SR
        ph = 2 * np.pi * f * t
        y = np.sin(ph) + 0.7 * np.sin(2 * ph) * np.exp(-t / 0.3) + 0.35 * np.sin(3 * ph) * np.exp(-t / 0.15)
        env = attack(t, 0.004) * np.exp(-t / 0.6) * gate(t, dur, rel)
        return y * env * 0.9 * vel
    if inst == 'upright':
        rel = 0.05
        n = int((dur + rel) * SR)
        t = np.arange(n) / SR
        glide = 1 + 0.012 * np.exp(-t / 0.04)
        ph = phase_of(f * glide)
        y = np.sin(ph) + 0.55 * np.sin(2 * ph) + 0.25 * np.sin(3 * ph) * np.exp(-t / 0.12)
        env = attack(t, 0.006) * np.exp(-t / 0.5) * gate(t, dur, rel)
        return y * env * 0.95 * vel
    raise ValueError(inst)


def drum(kind, vel, noise):
    if kind == 'kick':
        n = int(0.35 * SR)
        t = np.arange(n) / SR
        ph = phase_of(58 + 90 * np.exp(-t / 0.025))
        return (np.sin(ph) * np.exp(-t / 0.14) + 0.25 * np.sin(2 * np.pi * 1800 * t) * np.exp(-t / 0.004)) * attack(t, 0.002) * vel
    if kind == 'snare':
        n = int(0.3 * SR)
        t = np.arange(n) / SR
        w = noise.white(n)
        y = bandpass(w, 1500, 0.9)
        return (y * 0.9 * np.exp(-t / 0.08) + 0.4 * np.sin(2 * np.pi * 190 * t) * np.exp(-t / 0.05)) * vel
    if kind == 'hat':
        n = int(0.08 * SR)
        t = np.arange(n) / SR
        w = noise.white(n)
        y = np.empty(n)
        prev = 0.0
        for i in range(n):
            y[i] = w[i] - prev
            prev = w[i]
        return y * 0.5 * np.exp(-t / 0.02) * vel
    if kind == 'brush':
        n = int(0.3 * SR)
        t = np.arange(n) / SR
        w = noise.white(n)
        y = np.empty(n)
        acc = 0.0
        for i in range(n):
            acc += 0.3 * (w[i] - acc)
            y[i] = acc
        return y * attack(t, 0.012) * np.exp(-t / 0.09) * 1.4 * vel
    if kind == 'click':
        n = int(0.1 * SR)
        t = np.arange(n) / SR
        return (np.sin(2 * np.pi * 1250 * t) * np.exp(-t / 0.018) + 0.4 * np.sin(2 * np.pi * 2900 * t) * np.exp(-t / 0.008)) * vel
    if kind == 'rim':
        n = int(0.08 * SR)
        t = np.arange(n) / SR
        return (np.sin(2 * np.pi * 1650 * t) * np.exp(-t / 0.012) + 0.3 * noise.white(n) * np.exp(-t / 0.004)) * vel
    raise ValueError(kind)


def bandpass(x, f0, q):
    w0 = 2 * np.pi * f0 / SR
    alpha = np.sin(w0) / (2 * q)
    b0, b1, b2 = alpha, 0.0, -alpha
    a0, a1, a2 = 1 + alpha, -2 * np.cos(w0), 1 - alpha
    b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i in range(len(x)):
        v = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, x[i], y1, v
        y[i] = v
    return y


LEVEL = {'lead': 0.30, 'keys': 0.11, 'bass': 0.28,
         'kick': 0.22, 'snare': 0.10, 'hat': 0.05, 'brush': 0.08, 'click': 0.20, 'rim': 0.10}


def reverb(x, wet=0.16):
    combs = [1116, 1188, 1277, 1356]
    out = np.zeros_like(x)
    for d in combs:
        buf = np.zeros(d)
        idx = 0
        filt = 0.0
        y = np.zeros_like(x)
        for i in range(len(x)):
            o = buf[idx]
            filt = o * 0.75 + filt * 0.25
            buf[idx] = x[i] + filt * 0.78
            idx = (idx + 1) % d
            y[i] = o
        out += y
    for d in (556, 441):
        buf = np.zeros(d)
        idx = 0
        y = np.zeros_like(out)
        for i in range(len(out)):
            b = buf[idx]
            v = -out[i] + b
            buf[idx] = out[i] + b * 0.5
            idx = (idx + 1) % d
            y[i] = v
        out = y
    return x + out * wet * 0.25


def render(p, with_reverb=True):
    total = tick_time(p, 9 * p.ticks_per_bar) + 3.0
    buf = np.zeros(int(total * SR))
    noise = Noise(p.seed)
    spb = 60.0 / p.bpm
    for nt in p.notes:
        start = tick_time(p, nt.tick)
        if nt.kind == 'drum':
            y = drum(nt.inst, nt.vel, noise) * LEVEL[nt.inst]
        else:
            dur = tick_time(p, nt.tick + nt.dur) - start
            if nt.kind == 'bass':
                dur *= 0.9
            elif nt.kind == 'keys':
                dur *= 0.85
            y = voice(nt.inst, nt.midi, dur, nt.vel, noise) * LEVEL[nt.kind]
        k = min(len(y), int(0.008 * SR))
        y[-k:] *= np.linspace(1, 0, k)
        i = int(start * SR)
        buf[i:i + len(y)] += y[:len(buf) - i]
    # Phones can't play the deep sub-bass: a gentle 80 Hz high-pass keeps
    # the loudness for what they can play.
    rc = 1 / (2 * np.pi * 80.0)
    a = rc / (rc + 1.0 / SR)
    hp = np.empty_like(buf)
    prev_x = prev_y = 0.0
    for i in range(len(buf)):
        prev_y = a * (prev_y + buf[i] - prev_x)
        prev_x = buf[i]
        hp[i] = prev_y
    buf = hp
    if with_reverb:
        buf = reverb(buf)
    peak = np.max(np.abs(buf)) + 1e-9
    buf = buf * (0.9 / peak)
    buf = np.tanh(buf * 1.1) / np.tanh(1.1)
    return buf.astype(np.float32)


def write_wav(path, x):
    import wave
    pcm = (np.clip(x, -1, 1) * 32000).astype('<i2')
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
