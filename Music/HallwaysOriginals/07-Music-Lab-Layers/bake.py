"""Bake the Hallways band's instruments into one small SoundFont each (python3 bake.py [only-id ...]).

Every pitched instrument: notes rendered from its best available source at roots every few semitones,
mono, trimmed; sustaining instruments get a crossfaded loop so a held note lasts as long as the music asks.
Percussion: one sample per key. Output: out/sf2/<id>.sf2 + out/instruments.json (ranges, loudness, credits).
"""
import sys, os, json, glob
import numpy as np
import soundfile as sf
sys.path.insert(0, "/home/claude/lab"); sys.path.insert(0, "/home/claude/band")
import studio as S
from labkit import SR
from sf2write import write_sf2

FR3 = "/usr/share/sounds/sf2/FluidR3_GM.sf2"
V = S.VSCO
OUT = "/home/claude/band/out"
os.makedirs(f"{OUT}/sf2", exist_ok=True)

CREDIT = {"vsco": "VSCO-2 Community Edition (CC0)", "fr3": "FluidR3 GM SoundFont, Frank Wen (MIT)",
          "salamander": "Salamander Grand Piano V3, Alexander Holm (CC BY 3.0)", "vcsl": "Versilian Community Sample Library (CC0)",
          "hallways": "synthesized for Hallways (tonewheel organ model)"}

# id: (display instrument, source kind, engine, roots, length s, loop?, attack, release, velocities)
def rng(a, b, step):
    return list(range(a, b + 1, step))

SPECS = {
    "upright_bass": ("Upright bass", "vsco", ("sfz", f"{V}/ContrabassPizz.sfz"), rng(28, 55, 3), 2.2, False, .002, .25, [90]),
    "electric_bass": ("Electric bass", "fr3", ("sf", FR3, 33), rng(28, 58, 3), 2.4, False, .002, .12, [95]),
    "tuba": ("Tuba", "vsco", ("sfz", f"{V}/TubaSus.sfz"), rng(29, 59, 3), 3.0, True, .03, .25, [90]),
    "piano": ("Piano", "salamander", ("sfz", S.SALAMANDER), rng(24, 96, 4), 3.0, False, .002, .35, [55, 100]),
    "electric_piano": ("Electric piano", "fr3", ("sf", FR3, 4), rng(36, 88, 4), 2.6, False, .002, .3, [90]),
    "organ": ("Organ", "hallways", ("hammond", {"drawbars": "888600000", "perc": 0, "leslie": 0.8, "drive": 1.1}), rng(36, 84, 3), 3.75, True, .006, .06, [100]),
    "nylon_guitar": ("Nylon guitar", "fr3", ("sf", FR3, 24), rng(40, 80, 4), 2.6, False, .002, .25, [95]),
    "electric_guitar": ("Electric guitar", "fr3", ("sf", FR3, 27), rng(40, 84, 4), 2.6, False, .002, .2, [95]),
    "marimba": ("Marimba", "vsco", ("sfz", f"{V}/Marimba.sfz"), rng(45, 96, 4), 1.6, False, .002, .3, [95]),
    "vibraphone": ("Vibraphone", "fr3", ("sf", FR3, 11), rng(53, 89, 4), 3.0, False, .002, .6, [95]),
    "glockenspiel": ("Glockenspiel", "vsco", ("sfz", f"{V}/Glockenspiel.sfz"), rng(79, 108, 4), 2.0, False, .002, .6, [95]),
    "harp": ("Harp", "vsco", ("sfz", f"{V}/Harp.sfz"), rng(36, 96, 4), 2.6, False, .002, .8, [90]),
    "violin": ("Violin", "vsco", ("sfz", f"{V}/SViolinVib.sfz"), rng(55, 96, 3), 3.0, True, .05, .35, [85]),
    "cello": ("Cello", "vsco", ("sfz", f"{V}/CelloEnsSusVib.sfz"), rng(36, 72, 3), 3.0, True, .06, .4, [85]),
    "flute": ("Flute", "vsco", ("sfz", f"{V}/FluteSusVib.sfz"), rng(60, 96, 3), 3.0, True, .04, .25, [85]),
    "clarinet": ("Clarinet", "vsco", ("sfz", f"{V}/ClarinetSus.sfz"), rng(50, 91, 3), 3.0, True, .03, .2, [85]),
    "french_horn": ("French horn", "vsco", ("sfz", f"{V}/FHornSus.sfz"), rng(41, 77, 3), 3.0, True, .05, .3, [85]),
    "trumpet": ("Trumpet", "vsco", ("sfz", f"{V}/TrumpetSus.sfz"), rng(55, 84, 3), 3.0, True, .02, .2, [90]),
    "trombone": ("Trombone", "vsco", ("sfz", f"{V}/TromboneSus.sfz"), rng(40, 72, 3), 3.0, True, .03, .25, [90]),
    "tenor_sax": ("Tenor sax", "fr3", ("sf", FR3, 66), rng(44, 80, 3), 3.0, True, .02, .15, [95]),
    "harmonica": ("Harmonica", "fr3", ("sf", FR3, 22), rng(60, 93, 3), 3.0, True, .02, .12, [95]),
}
# percussion: key -> (wav glob(s) or fluid drum note, seconds)
DRUM_KEYS = {35: 1.2, 36: 1.2, 37: .6, 38: 1.0, 40: 1.0, 41: 1.4, 42: .5, 44: .5, 45: 1.4, 46: 1.6, 47: 1.4, 48: 1.4,
             49: 3.0, 50: 1.4, 51: 2.5, 53: 2.5, 39: .8, 54: .8, 56: .8, 59: 2.5}


def mono(x):
    return x.mean(1) if x.ndim == 2 else x


def render_note(engine, root, vel, length):
    p = S.ep("bake", "bake", engine, channel=0)
    p.add(0, length + 0.5, root, vel, swing=False, jitter_ms=0, bpm=60)          # held through the whole sample
    x = S.render_part(p, [(0, 60)], length + 2, int((length + 0.6) * SR))
    return mono(x)[: int(length * SR)]


def trim_start(x, thresh=0.003):
    i = np.argmax(np.abs(x) > thresh * np.abs(x).max())
    return x[max(0, i - 32):]


def make_loop(x, root, xfade=0.06):
    """A crossfaded loop in the held part: ~0.7 s ending 0.15 s before the end, start chosen where the
    waveform best matches the end (searched over two periods), then the end crossfaded into it."""
    n = len(x)
    e = n - int(0.15 * SR)
    period = SR / (440 * 2 ** ((root - 69) / 12))
    L0 = int(0.7 * SR)
    W = int(0.008 * SR)
    best, bs = -1e9, e - L0
    for s in range(e - L0 - int(2 * period), e - L0 + int(2 * period)):
        c = np.dot(x[s - W:s], x[e - W:e]) / (np.linalg.norm(x[s - W:s]) * np.linalg.norm(x[e - W:e]) + 1e-12)
        if c > best:
            best, bs = c, s
    X = int(xfade * SR)
    y = x.copy()
    w = np.linspace(0, 1, X)
    y[e - X:e] = x[e - X:e] * (1 - w) + x[bs - X:bs] * w
    return y[: e + int(0.05 * SR)], (bs, e), best


def bake(iid):
    name, kind, engine, roots, length, loop, attack, release, vels = SPECS[iid]
    zones, raw = [], []
    for vi, vel in enumerate(vels):
        for k, root in enumerate(roots):
            x = trim_start(render_note(engine, root, vel, length))
            lp, q = None, None
            if loop:
                x, lp, q = make_loop(x, root)
            else:
                f = int(0.25 * SR); x = x.copy(); x[-f:] *= np.linspace(1, 0, f) ** 2
            lo = 0 if k == 0 else (roots[k - 1] + root) // 2 + 1
            hi = 127 if k == len(roots) - 1 else (root + roots[k + 1]) // 2
            vlo = 0 if vi == 0 else (vels[vi - 1] + vel) // 2 + 1
            vhi = 127 if vi == len(vels) - 1 else (vel + vels[vi + 1]) // 2
            raw.append(x)
            zones.append(dict(root=root, lo=lo, hi=hi, vlo=vlo, vhi=vhi, loop=lp, attack=attack, release=release, q=q))
    # Oct 24: single-layer instruments -- each sample to its own peak (a quiet recording no longer drags the
    # whole instrument down); layered ones (the piano) keep their layers' relative levels.
    peak = max(np.abs(r).max() for r in raw)
    for z, r in zip(zones, raw):
        g = 10 ** (-1 / 20) / (np.abs(r).max() if len(vels) == 1 else peak)
        z["sample"] = np.clip(r * g * 32767, -32768, 32767).astype(np.int16)
    write_sf2(f"{OUT}/sf2/{iid}.sf2", name, zones)
    loops = [round(float(z["q"]), 3) for z in zones if z.get("q") is not None]
    return dict(id=iid, instrument=name, source=CREDIT[kind], low=roots[0] - 2, high=roots[-1] + 2, kind="pitched",
                samples=len(zones), loopMatchMin=min(loops) if loops else None, bytes=os.path.getsize(f"{OUT}/sf2/{iid}.sf2"))


def bake_drums():
    zones = []
    for key, secs in sorted(DRUM_KEYS.items()):
        x = trim_start(render_note(("sf", FR3, 32), key, 100, secs) if False else None) if False else None
        p = S.ep("drum", "drum", ("sf", FR3, 32), channel=9)
        p.add(0, 0.2, key, 105, swing=False, jitter_ms=0, bpm=60)
        x = mono(S.render_part(p, [(0, 60)], secs + 1, int((secs + 0.3) * SR)))[: int(secs * SR)]
        x = trim_start(x)
        f = int(0.1 * SR); x = x.copy(); x[-f:] *= np.linspace(1, 0, f)
        zones.append(dict(root=key, lo=key, hi=key, sample_f=x, attack=.001, release=min(1.0, secs)))
    for z in zones:                                   # each drum to its own peak (velocity does the rest)
        x = z.pop("sample_f")
        z["sample"] = np.clip(x * 10 ** (-1 / 20) / np.abs(x).max() * 32767, -32768, 32767).astype(np.int16)
    write_sf2(f"{OUT}/sf2/drums.sf2", "Drums", zones)
    return dict(id="drums", instrument="Drums", source=CREDIT["fr3"] + " (Jazz kit)", kind="drums", samples=len(zones),
                bytes=os.path.getsize(f"{OUT}/sf2/drums.sf2"))


def bake_percussion():
    VC = S.VCSL
    pick = {60: S.vsco_perc("Conga-Tap1")[0][:1], 62: S.vsco_perc("Quinto-HitN")[-1][:1], 63: S.vsco_perc("Conga-HitN")[-1][:1],
            64: S.vsco_perc("Tumba-HitN")[-1][:1],
            70: S.vcsl_dir("Idiophones/Struck Idiophones/Shaker, Small", "*Double_Down_rr1*.wav")[:1],
            71: S.vcsl_dir("Idiophones/Struck Idiophones/Shaker, Small", "*Double_Up_rr1*.wav")[:1],
            75: S.vsco_perc("Claves1_Hit")[-1][:1], 56: S.vsco_perc("Cowbell1_Hit")[1][:1],
            66: S.vsco_perc("Guiro-Hit")[0][:1]}
    zones = []
    for key, files in sorted(pick.items()):
        x = mono(S.load(files[0]))
        x = trim_start(x)[: int(1.2 * SR)].copy()
        f = int(0.05 * SR); x[-f:] *= np.linspace(1, 0, f)
        zones.append(dict(root=key, lo=key, hi=key, sample_f=x, attack=.001, release=.3, src=os.path.basename(files[0])))
    for z in zones:                                   # each drum to its own peak (velocity does the rest)
        x = z.pop("sample_f")
        z["sample"] = np.clip(x * 10 ** (-1 / 20) / np.abs(x).max() * 32767, -32768, 32767).astype(np.int16)
    write_sf2(f"{OUT}/sf2/percussion.sf2", "Hand percussion", zones)
    return dict(id="percussion", instrument="Congas & hand percussion", source=CREDIT["vsco"] + "; " + CREDIT["vcsl"],
                kind="percussion", samples=len(zones), bytes=os.path.getsize(f"{OUT}/sf2/percussion.sf2"),
                keys={"tap": 60, "quinto": 62, "conga": 63, "tumba": 64, "shakerDown": 70, "shakerUp": 71, "claves": 75, "cowbell": 56, "guiro": 66})


if __name__ == "__main__":
    only = sys.argv[1:]
    meta_path = f"{OUT}/instruments.json"
    meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
    for iid in (only or list(SPECS) + ["drums", "percussion"]):
        m = bake_drums() if iid == "drums" else bake_percussion() if iid == "percussion" else bake(iid)
        meta[iid] = m
        print(json.dumps(m), flush=True)
        json.dump(meta, open(meta_path, "w"), indent=1)
