"""Render a lab-harness.js run through the band's SoundFonts and the singers' prerendered parts -- the same
sounds, levels and bar-by-bar scheduling the app uses:
  python3 render_lab.py <events.json> <scenario.json> <out.m4a> [--check]
Levels: every instrument evened out to REFERENCE (a sampler up to +12 dB; a singer never boosted), the
arranger's per-bar level on top, the limiter's +8 dB make-up."""
import sys, json, os, collections
import numpy as np
import soundfile as sf
sys.path.insert(0, "/home/claude/lab"); sys.path.insert(0, "/home/claude/band")
import studio as S
from labkit import Part, midi_for, render, SR

REFERENCE, MAKEUP = -24.0, 8.0
PAN = {"drums": 0, "percussion": 0.45, "upright_bass": 0, "electric_bass": 0, "tuba": -0.1, "piano": -0.3, "electric_piano": -0.35,
       "organ": -0.25, "nylon_guitar": 0.35, "electric_guitar": 0.4, "marimba": 0.3, "vibraphone": 0.3, "glockenspiel": 0.5, "harp": -0.45,
       "violin": -0.2, "cello": 0.25, "flute": 0.2, "clarinet": -0.15, "harmonica": 0.1, "tenor_sax": 0.15, "french_horn": -0.35,
       "trumpet": 0.2, "trombone": -0.2, "soprano": 0.05, "alto": -0.05, "tenor": 0.05, "bass_voice": -0.05}
VOICE = {"soprano": "soprano", "alto": "alto", "tenor": "tenor", "bass_voice": "bass"}
VDIR = "/home/claude/band/out/voices-np"


def main():
    ev = json.load(open(sys.argv[1])); sc = json.load(open(sys.argv[2])); out = sys.argv[3]
    inst = json.load(open("/home/claude/band/out/instruments.json"))
    vman = json.load(open(f"{VDIR}/band-voices.json")) if os.path.exists(f"{VDIR}/band-voices.json") else {"levels": {}}
    bpm = ev["meta"]["bpm"]; bpb = ev["meta"]["beatsPerBar"]; spb = 60 / bpm
    nbars = len(ev["bars"]); F = int(round(bpb * spb * SR))
    T = nbars * F + int(4 * SR)
    roster = sc["roster"]
    notes = collections.defaultdict(list); ccs = collections.defaultdict(list); sings = collections.defaultdict(list)
    levels = collections.defaultdict(dict)
    for b in ev["bars"]:
        for w, db in b["levels"].items():
            levels[w][b["bar"]] = db
        for e in b["events"]:
            t = b["bar"] * bpb + e["t"]
            if e["type"] == "note": notes[e["who"]].append((t, e["dur"], e["pitch"], e["vel"]))
            elif e["type"] == "cc": ccs[e["who"]].append((t, e["cc"], e["value"]))
            elif e["type"] == "sing": sings[e["who"]].append((b["bar"], e["part"], e["loopBar"]))
    if "--check" in sys.argv: check(notes, roster)
    mix = np.zeros((T, 2)); ir = S.room_ir(rt=1.2)
    clips = {}
    for w in sorted(set(notes) | set(sings)):
        iid = roster[w]
        if iid in VOICE:
            x = np.zeros(T)
            for bar, part, lb in sings[w]:
                key = f"{VOICE[iid]}-{part}"
                if key not in clips: clips[key] = sf.read(f"{VDIR}/{key}.wav")[0]
                c = clips[key]; seg = c[lb * F:(lb + 1) * F]
                x[bar * F:bar * F + len(seg)] += seg
            x = np.stack([x, x], 1)
            loud = vman["levels"].get(iid, -16); trim = min(0.0, REFERENCE - loud)
        else:
            p = Part(w, w, 0, 0, vol=127, pan=64, reverb=0, swing=0)
            p.notes = [(s, d, int(m), int(v)) for s, d, m, v in notes[w]]
            p.cc = ccs[w]
            x = render(midi_for([p], [(0, bpm)], nbars * bpb + 8), T, reverb=(0.1, 0.5, 0.5, 0.0), sfont=f"/home/claude/band/out/sf2/{iid}.sf2")
            trim = min(12.0, REFERENCE - inst[iid]["loudnessDb"])
        g = np.zeros(T)
        for n in range(nbars):
            db = levels[w].get(n)
            g[n * F:(n + 1) * F] = 10 ** ((trim + db + MAKEUP) / 20) if db is not None and db > -59 else 0
        g[nbars * F:] = g[nbars * F - 1]
        k = int(0.08 * SR); g = np.convolve(g, np.ones(k) / k, mode="same")
        y = S.place(x * g[:, None], PAN.get(iid, 0))
        mix += S.add_room(y, ir, 0.16)
    S.write_m4a(out, S.finish(mix, -16, fout=2.5))
    print("wrote", out, round(T / SR, 1), "s")


def check(notes, roster):
    """Half-step rubs between different musicians' notes that start within a beat of each other and overlap."""
    issues = collections.Counter()
    pitched = {w: v for w, v in notes.items() if roster[w] not in ("drums", "percussion")}
    alln = sorted((s, s + d, m, w) for w, v in pitched.items() for s, d, m, _ in v)
    for i, (s, e, m, w) in enumerate(alln):
        for s2, e2, m2, w2 in alln[i + 1:]:
            if s2 >= e: break
            if w2 != w and abs(m - m2) % 12 in (1, 11) and s2 - s < 1.0:
                issues[(w, w2)] += 1
    print("pitched notes", sum(len(v) for v in pitched.values()), " half-step rubs:", dict(issues))


if __name__ == "__main__":
    main()
