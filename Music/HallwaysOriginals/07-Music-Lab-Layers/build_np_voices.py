"""Prerender the singers' parts of a composition template (Hallenese, Sinsy + WORLD), one loop per part:
  python3 build_np_voices.py [voice ...]

For each voice (soprano, alto, tenor, bass) and each single-line part (melody, answers, harmony, low harmony):
the part's notes exactly as the template writes them, moved by the same whole-octave shift the arranger
would give that voice (Lab.fitFor), sung on Hallenese syllables, corrected to pitch, de-whistled, given the
voice's character. Each clip is exactly one loop long (24 bars), its tail folded back onto its start, so
the app can play any bar of it on the shared clock (bar k = frames k*F ..< (k+1)*F).
Out: out/voices-np/<voice>-<part>.wav, band-voices.json {parts: {comp: {voice: {part: {shift}}}}, levels}
"""
import sys, os, json, subprocess, tempfile, random
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly
sys.path.insert(0, "/home/claude/lab/voice"); sys.path.insert(0, "/home/claude/lab")
import sing as V
import studio as S

TPL = "/home/claude/band/out/templates/comp-night-porter.json"
OUT = "/home/claude/band/out/voices-np"
GRID = 4
LEAD_IN = 2                     # bars of rest before the loop (Sinsy breathes in)
VOICES = {   # name: (formant, breath, vibrato)  -- ranges: the arranger's (lab-arranger.js VOICE_RANGE)
    "soprano": (1.04, 0.08, 24), "alto": (0.93, 0.13, 20), "tenor": (0.80, 0.20, 22), "bass": (0.71, 0.18, 16)}
VOICE_INST = {"soprano": "soprano", "alto": "alto", "tenor": "tenor", "bass": "bass_voice"}
SUNG = ["melody", "answer1", "answer2", "answer3"]
SYL_SHORT = ["ら", "み", "ど", "れ", "な", "そ", "べ", "ま", "に", "と", "の", "さ", "る", "か", "ぱ", "り", "で", "も", "ね", "よ"]
SYL_LONG = ["あ", "お", "え", "ら", "の", "ま", "そ", "や"]


def fit_shift(inst, part):
    js = (f'const L=require("/home/claude/band/lab-arranger.js"); const fs=require("fs");'
          f'L.configure({{instruments: JSON.parse(fs.readFileSync("/home/claude/band/out/instruments.json"))}});'
          f'L.load(JSON.parse(fs.readFileSync("{TPL}"))); console.log(JSON.stringify(L.fitFor("{inst}", "{part}")));')
    return json.loads(subprocess.run(["node", "-e", js], capture_output=True, text=True, check=True).stdout)["shift"]


def line(part):
    """The part's top line (chords -> top note), no overlaps, on the 1/4-beat grid."""
    ns = sorted(part["notes"], key=lambda x: (x[0], -x[2]))
    out = []
    for b, d, m, v, *a in ns:
        if out and abs(out[-1][0] - b) < 0.03:
            continue
        out.append([b, d, m])
    q = []
    for i, (b, d, m) in enumerate(out):
        s = int(round(b * GRID)); e = int(round((b + d) * GRID))
        if i + 1 < len(out):
            e = min(e, int(round(out[i + 1][0] * GRID)))
        q.append((s, max(e, s + 1), m))
    return q


def render(part, voice, shift, bpm, beats_total, seed):
    formant, breath, vib = VOICES[voice]
    rng = random.Random(seed)
    lead = LEAD_IN * 4 * GRID
    q = line(part)
    seq, t = [], 0
    for i, (s, e, m) in enumerate(q):
        s += lead; e += lead
        if s > t: seq.append((None, s - t, ""))
        long_ = (e - s) >= GRID or i + 1 == len(q) or (q[i + 1][0] - (e - lead)) >= GRID
        seq.append((m, e - s, rng.choice(SYL_LONG if long_ else SYL_SHORT))); t = e
    end = lead + beats_total * GRID
    seq.append((None, end - t + 2 * 4 * GRID, ""))      # to the loop's end, then two bars for the tail
    beats = [(m, d / GRID, k) for m, d, k in seq]
    ps = [m for m, _, _ in beats if m is not None]
    off = int(round(69 - (min(ps) + max(ps)) / 2))
    with tempfile.TemporaryDirectory() as d:
        V.musicxml([(None if m is None else m + off, b, k) for m, b, k in beats], bpm, f"{d}/v.xml", divisions=GRID)
        x, sr = V.sinsy(f"{d}/v.xml", f"{d}/v.wav")
    y = V.express(x, sr, beats, bpm, shift=shift, formant=formant, breath=breath, vib=vib, fall=True, fix_whistle=True)
    y = resample_poly(y, 147, 160)                      # 48 -> 44.1 kHz
    spb = 60 / bpm
    a = int(round(LEAD_IN * 4 * spb * 44100))
    F = int(round(beats_total * spb * 44100))
    body = y[a:a + F].copy()
    if len(body) < F: body = np.pad(body, (0, F - len(body)))
    tail = y[a + F:a + F + int(4 * spb * 44100)]
    body[:len(tail)] += tail                             # fold the tail onto the start: a seamless loop
    pre = y[max(0, a - int(0.3 * 44100)):a]             # (a consonant sung just before bar 1 belongs to the loop's end)
    body[F - len(pre):] += pre
    return body


def main():
    tpl = json.load(open(TPL))
    bpm, total = tpl["bpm"], tpl["bars"] * tpl["meter"][0]
    os.makedirs(OUT, exist_ok=True)
    for voice in (sys.argv[1:] or list(VOICES)):
        man_path = f"{OUT}/band-voices-{voice}.json"          # (one per voice: they render in parallel; merge() joins them)
        man = {"parts": {}, "levels": {}}
        mine = man["parts"].setdefault(tpl["id"], {})
        acts = []
        for pid in SUNG:
            part = next(p for p in tpl["parts"] if p["id"] == pid)
            shift = fit_shift(VOICE_INST[voice], pid)
            clip = render(part, voice, shift, bpm, total, seed=hash((voice, pid)) & 0xffff)
            clip *= 10 ** (-1 / 20) / max(1e-9, np.abs(clip).max())
            sf.write(f"{OUT}/{voice}-{pid}.wav", clip.astype(np.float32), 44100)
            mine.setdefault(voice, {})[pid] = {"shift": shift, "frames": len(clip)}
            acts.append(S.active_rms(np.stack([clip, clip], 1)))
            print(voice, pid, "shift", shift, round(len(clip) / 44100, 2), "s", flush=True)
            man["levels"][VOICE_INST[voice]] = round(float(np.median(acts)), 1)
            json.dump(man, open(man_path, "w"), indent=1)
        print(man["levels"])


def merge():
    out = {"parts": {}, "levels": {}}
    for v in VOICES:
        p = f"{OUT}/band-voices-{v}.json"
        if not os.path.exists(p): continue
        m = json.load(open(p))
        for comp, vs in m["parts"].items():
            out["parts"].setdefault(comp, {}).update(vs)
        out["levels"].update(m["levels"])
    json.dump(out, open(f"{OUT}/band-voices.json", "w"), indent=1)
    print(out["levels"])


if __name__ == "__main__":
    merge() if sys.argv[1:] == ["merge"] else main()
