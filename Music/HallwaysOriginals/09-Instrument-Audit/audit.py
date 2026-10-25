"""Audit the band's 23 SoundFonts (Oct 25 2026): python3 audit.py [instrument ...]

Per instrument:
  zones     every sample: has a tone (not silence / DC), its pitch vs its root (cents), its loop's match
  sustain   a held note (mid-range, 4 s) rendered by FluidSynth: level at 3-3.8 s vs 0.4-1.2 s (a working
            loop holds; a decaying instrument -- piano, guitar, mallets -- is expected to fall)
  release   the level 0.6 s after note-off, vs while held (should be far down)
  clicks    sample-to-sample jumps far larger than the signal's local motion
  loudness  active RMS of its audition phrase (the level the app evens instruments out from)
Renders each audition phrase to out/auditions/<instrument>.wav. FluidSynth stands in for Apple's
AVAudioUnitSampler: same SoundFont, a different player -- what the phone does still has to be heard."""
import sys, json, os, struct
import numpy as np
import soundfile as sf
sys.path.insert(0, "/home/claude/lab"); sys.path.insert(0, "/home/claude/band")
import studio as S
from labkit import Part, midi_for, render, SR
from bake import pitch_error, SPECS

OUT = "/home/claude/band/out"
SUSTAINS = {k for k, v in SPECS.items() if v[5]}


def zones(path):
    d = open(path, "rb").read()
    i = d.find(b"smpl"); n = struct.unpack("<I", d[i + 4:i + 8])[0]
    x = np.frombuffer(d[i + 8:i + 8 + n], dtype="<i2").astype(float) / 32768
    j = d.find(b"shdr"); m = struct.unpack("<I", d[j + 4:j + 8])[0]
    out = []
    for k in range(m // 46 - 1):
        r = d[j + 8 + 46 * k:j + 8 + 46 * (k + 1)]
        start, end, ls, le, sr = struct.unpack("<5I", r[20:40])
        out.append((r[40], x[start:end], ls - start, le - start))
    return out


def play(iid, notes, bpm, seconds):
    p = Part(iid, iid, 0, 0, vol=127, pan=64, reverb=0, swing=0)
    p.notes = [(t, d, int(m), int(v)) for t, d, m, v in notes]
    T = int(seconds * SR)
    x = render(midi_for([p], [(0, bpm)], int(seconds * bpm / 60) + 2), T, reverb=(0.1, 0.5, 0.5, 0.0), sfont=f"{OUT}/sf2/{iid}.sf2")
    return x.mean(1) if x.ndim == 2 else x


def rms(x):
    return 20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-9)


def clicks(x):
    """Jumps between neighbouring samples > 8x the 99th percentile of jumps (and audible: > 0.05)."""
    d = np.abs(np.diff(x))
    thr = max(0.05, 8 * np.percentile(d, 99))
    return int(np.sum(d > thr))


def audit(iid, aud):
    path = f"{OUT}/sf2/{iid}.sf2"
    zs = zones(path)
    empty, errs, loops = 0, [], []
    for root, s, ls, le in zs:
        ac = s - np.convolve(s, np.ones(441) / 441, mode="same")
        if np.abs(ac).max() < 1e-3:
            empty += 1; continue
        if iid not in ("drums", "percussion"):
            e = pitch_error(s, root)
            if e is not None: errs.append((int(root), int(round(e))))
    res = {"zones": len(zs), "emptyZones": empty, "pitchOff": [r for r, e in errs if abs(e) > 35]}
    if iid not in ("drums", "percussion"):
        meta = json.load(open(f"{OUT}/instruments.json"))[iid]
        mid = (meta["low"] + meta["high"]) // 2
        x = play(iid, [(0, 4 * 1.0, mid, 96)], 60, 6)                 # 4 s held at 60 bpm
        early, late = rms(x[int(.4 * SR):int(1.2 * SR)]), rms(x[int(3 * SR):int(3.8 * SR)])
        tail = rms(x[int(4.6 * SR):int(5.0 * SR)])
        ring = rms(x[int(2.4 * SR):int(2.8 * SR)])                    # (a struck / plucked note: still ringing at 2.4 s?)
        res.update(heldNote=int(mid), sustainDb=round(float(late - early), 1), ringAt2_4sDb=round(float(ring - early), 1), releaseDb=round(float(tail - late), 1), clicksHeld=clicks(x))
    y = play(iid, aud["notes"], aud["bpm"], aud["seconds"])
    os.makedirs(f"{OUT}/auditions", exist_ok=True)
    sf.write(f"{OUT}/auditions/{iid}.wav", (y / max(1e-9, np.abs(y).max()) * 0.8).astype(np.float32), SR)
    res["loudnessDb"] = round(float(S.active_rms(np.stack([y, y], 1))), 1)
    res["clicksPhrase"] = clicks(y)
    return res


if __name__ == "__main__":
    aud = json.load(open(f"{OUT}/band-auditions.json"))
    ids = sys.argv[1:] or list(aud)
    report = {}
    for iid in ids:
        r = audit(iid, aud[iid])
        report[iid] = r
        print(iid, json.dumps(r), flush=True)
    path = f"{OUT}/audit.json"
    old = json.load(open(path)) if os.path.exists(path) else {}
    old.update(report)
    json.dump(old, open(path, "w"), indent=1)
