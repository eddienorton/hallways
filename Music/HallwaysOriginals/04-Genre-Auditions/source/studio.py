"""Hallways Music Lab -- the studio (Oct 24, Level 3): each part rendered by the best engine we have.

Engines (Part.engine):
  ("sf", path, program)        a SoundFont via FluidSynth (MuseScore General, MIT; FluidR3, MIT)
  ("sfz", path)                a sampled instrument via sfizz (VSCO-2 CE, CC0; Salamander Grand, CC-BY 3.0)
  ("hammond", dict)            a tonewheel organ, synthesized here (drawbars, key click, percussion, Leslie, drive)
  ("perc", {note: [wav,...]})  one-shot samples (VCSL / VSCO percussion, CC0), round-robin, velocity-scaled
Mixing: per-part gain to a target level (the ensemble balance), pan, and a shared convolution room.
"""
import os, subprocess, tempfile, glob, re
import numpy as np
import soundfile as sf
from scipy.signal import fftconvolve, resample_poly
from labkit import Part, midi_for, render as fs_render, SR, n

SFIZZ = "/home/claude/src/sfizz/build/library/bin/sfizz_render"
MSG = "/usr/share/sounds/sf3/MuseScore_General_Full.sf3"
VSCO = "/home/claude/samples/VSCO-2-CE"
VCSL = "/home/claude/samples/VCSL"
SALAMANDER = "/home/claude/samples/SalamanderGrandPiano/Salamander Grand Piano V3.sfz"


def ep(name, who, engine, vol=100, pan=64, swing=0.0, channel=0, program=0):
    p = Part(name, who, program, channel, vol=vol, pan=pan, reverb=0, swing=swing)
    p.engine = engine
    return p


# ------------------------------------------------------------------ engines
def _fit(x, T):
    if x.ndim == 1:
        x = np.stack([x, x], 1)
    if len(x) >= T:
        return x[:T]
    return np.pad(x, ((0, T - len(x)), (0, 0)))


def render_sf(p, tempo, beats, T):
    _, path, prog = p.engine
    p.program = prog
    return fs_render(midi_for([p], tempo, beats), T, reverb=(0.1, 0.5, 0.5, 0.0), sfont=path)


def render_sfz(p, tempo, beats, T):
    _, path = p.engine
    with tempfile.TemporaryDirectory() as d:
        q = Part(p.name, p.who, 0, 0, vol=127, pan=64, reverb=0, swing=0)
        q.notes, q.cc, q.expr = p.notes, p.cc, p.expr
        midi_for([q], tempo, beats).save(f"{d}/p.mid")
        r = subprocess.run([SFIZZ, "--sfz", path, "--midi", f"{d}/p.mid", "--wav", f"{d}/p.wav", "-s", str(SR), "-q", "2", "-p", "128"],
                           capture_output=True, text=True)
        if not os.path.exists(f"{d}/p.wav"):
            raise RuntimeError(f"sfizz failed for {p.name}: {r.stdout[-500:]} {r.stderr[-500:]}")
        x, sr = sf.read(f"{d}/p.wav")
    if sr != SR:
        x = resample_poly(x, SR, sr, axis=0)
    return _fit(x, T)


def beats_to_sec(tempo):
    marks = sorted(tempo)
    def f(b):
        s = 0.0
        for i, (b0, bpm) in enumerate(marks):
            b1 = marks[i + 1][0] if i + 1 < len(marks) else float("inf")
            if b <= b0:
                break
            s += (min(b, b1) - b0) * 60 / bpm
        return s
    return f


_cache = {}


def load(path):
    if path not in _cache:
        x, sr = sf.read(path, always_2d=True)
        if sr != SR:
            x = resample_poly(x, SR, sr, axis=0)
        if x.shape[1] == 1:
            x = np.repeat(x, 2, 1)
        _cache[path] = x[:, :2].astype(np.float32)
    return _cache[path]


def render_perc(p, tempo, beats, T):
    """One-shots: note -> list of (wav, loudness rank); velocity picks the layer and scales; round-robin."""
    _, kit = p.engine
    out = np.zeros((T, 2), np.float32)
    sec = beats_to_sec(tempo)
    rr = {}
    for s, d, note, vel in p.notes:
        layers = kit.get(note)
        if not layers:
            continue
        # layers: list of lists (soft..loud), each a list of round-robin files
        li = min(len(layers) - 1, int(vel / 128 * len(layers)))
        files = layers[li]
        k = rr.get((note, li), 0)
        rr[(note, li)] = k + 1
        x = load(files[k % len(files)])
        g = (vel / 127) ** 1.6 * 1.6
        i = int(round(sec(s) * SR))
        if i >= T:
            continue
        m = min(len(x), T - i)
        out[i:i + m] += x[:m] * g
    return out


def render_hammond(p, tempo, beats, T):
    """A tonewheel organ: nine drawbars (16' 5 1/3' 8' 4' 2 2/3' 2' 1 3/5' 1 1/3' 1'), key click,
    single-trigger percussion (2nd or 3rd harmonic), soft overdrive, and a Leslie (rotor speed in cfg)."""
    cfg = p.engine[1]
    draw = cfg.get("drawbars", "888000000")
    ratios = [0.5, 1.5, 1, 2, 3, 4, 5, 6, 8]
    amps = [0 if c == "0" else 10 ** ((int(c) - 8) * 3 / 20) for c in draw]
    perc = cfg.get("perc", 3)              # 2, 3 or 0
    sec = beats_to_sec(tempo)
    dry = np.zeros(T, np.float64)
    held = []
    for s, d, note, vel in sorted(p.notes):
        t0, t1 = sec(s), sec(s + d)
        i0, i1 = int(t0 * SR), min(T, int(t1 * SR) + int(0.012 * SR))
        if i0 >= T:
            continue
        L = i1 - i0
        t = np.arange(L) / SR
        f = 440 * 2 ** ((note - 69) / 12)
        y = np.zeros(L)
        for r, a in zip(ratios, amps):
            if a and f * r < 9000:
                y += a * np.sin(2 * np.pi * f * r * t + np.random.rand() * 6.28)    # free-running wheels
        # percussion: only on notes that start with nothing else held (single trigger)
        held = [h for h in held if h > t0]
        if perc and not held:
            y += 0.9 * np.sin(2 * np.pi * f * perc * t) * np.exp(-t / 0.22)
        held.append(t1)
        env = np.minimum(1, t / 0.004) * np.clip((t1 - t0 + 0.012 - t) / 0.012, 0, 1)
        y *= env * (0.55 + 0.45 * vel / 127)
        k = int(0.0035 * SR)                                     # key click
        y[:k] += np.random.randn(k) * np.exp(-np.arange(k) / (0.0009 * SR)) * 0.35
        dry[i0:i1] += y
    dry = np.tanh(dry * cfg.get("drive", 0.9)) / max(1e-6, np.tanh(cfg.get("drive", 0.9)))
    # Leslie: two rotors (horn above 800 Hz, drum below), Doppler + amplitude, stereo
    from scipy.signal import butter, sosfilt
    lo = sosfilt(butter(2, 800, "low", fs=SR, output="sos"), dry)
    hi = dry - lo
    t = np.arange(T) / SR
    speed = cfg.get("leslie", 6.7)           # Hz (chorale ~0.8, tremolo ~6.7)
    out = np.zeros((T, 2))
    for sig, rate, depth_ms, am in [(hi, speed, 0.45, 0.35), (lo, speed * 0.88, 0.25, 0.18)]:
        for c, ph in [(0, 0.0), (1, np.pi / 2)]:
            mod = np.sin(2 * np.pi * rate * t + ph)
            delay = (1.2 + depth_ms * mod) / 1000 * SR
            pos = np.arange(T) - delay
            y = np.interp(pos, np.arange(T), sig, left=0, right=0)
            out[:, c] += y * (1 - am / 2 + am / 2 * mod)
    return (out * 0.25).astype(np.float32)


def render_part(p, tempo, beats, T):
    kind = p.engine[0]
    return {"sf": render_sf, "sfz": render_sfz, "perc": render_perc, "hammond": render_hammond}[kind](p, tempo, beats, T)


# ------------------------------------------------------------------ mixing
def room_ir(rt=1.6, pre=0.018, seed=7, damp=6000):
    from scipy.signal import butter, sosfilt
    rng = np.random.default_rng(seed)
    L = int(SR * rt * 1.3)
    t = np.arange(L) / SR
    ir = np.zeros((L + int(pre * SR), 2))
    for c in range(2):
        noise = rng.standard_normal(L)
        noise = sosfilt(butter(1, damp, "low", fs=SR, output="sos"), noise)
        ir[int(pre * SR):, c] = noise * np.exp(-6.9 * t / rt)
    return ir / np.sqrt((ir ** 2).sum(axis=0, keepdims=True))


def rms(x):
    return 20 * np.log10(np.sqrt(np.mean(np.asarray(x, np.float64) ** 2)) + 1e-12)


def active_rms(x, frame=4410):
    """Loudness while playing (frames above -60 dB) -- a part that rests half the time isn't 'quiet'."""
    m = np.mean(x.reshape(-1, 2) ** 2, axis=1) if x.ndim == 2 else x ** 2
    nfr = len(m) // frame
    e = m[: nfr * frame].reshape(nfr, frame).mean(1)
    on = e[e > 1e-6]
    return 10 * np.log10(on.mean() + 1e-12) if len(on) else -120.0


def place(x, pan):
    """stereo stem, pan -1..1 (equal-power balance)."""
    l, r = np.cos((pan + 1) * np.pi / 4) * np.sqrt(2), np.sin((pan + 1) * np.pi / 4) * np.sqrt(2)
    return x * np.array([l, r])[None, :]


def add_room(x, ir, wet):
    if wet <= 0:
        return x
    w = np.stack([fftconvolve(x[:, c], ir[:, c])[: len(x)] for c in range(2)], 1)
    return x + wet * w


def finish(x, target=-18.0, ceiling=-1.0, fout=0.0):
    x = x * 10 ** ((target - rms(x)) / 20)
    pk = np.abs(x).max()
    if pk > 10 ** (ceiling / 20):
        x = x * 10 ** (ceiling / 20) / pk
    x = x.copy()
    k = int(0.01 * SR); x[:k] *= np.linspace(0, 1, k)[:, None]
    if fout:
        k = int(fout * SR); x[-k:] *= np.linspace(1, 0, k)[:, None] ** 1.5
    return x


def write_m4a(path, x):
    import wave
    tmp = path + ".tmp.wav"
    with wave.open(tmp, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(np.clip(x * 32767, -32768, 32767).astype(np.int16).tobytes())
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp, "-c:a", "aac", "-b:a", "256k", path], check=True)
    os.remove(tmp)


# ------------------------------------------------------------------ kits (one-shot sample maps)
def vsco_perc(prefix):
    """VSCO percussion: Name_vN_rrM_Sum.wav -> layers by vN, round-robins within."""
    files = sorted(glob.glob(f"{VSCO}/Percussion/{prefix}_v*_Sum.wav"))
    layers = {}
    for f in files:
        m = re.search(r"_v(\d+)", f)
        layers.setdefault(int(m.group(1)) if m else 1, []).append(f)
    return [layers[k] for k in sorted(layers)]


def vcsl_dir(sub, pattern="*.wav"):
    return sorted(glob.glob(f"{VCSL}/{sub}/**/{pattern}", recursive=True))
