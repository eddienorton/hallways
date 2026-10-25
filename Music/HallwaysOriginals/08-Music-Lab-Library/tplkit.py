"""Shared helpers for writing hallways-composition/1 templates (Oct 2026).

A template is music only: parts of notes [beat, beats, midi, velocity, articulation?] or groove hits
[beat, piece, velocity], a chord chart, sections, and the ordered layer stack. No instruments."""
import sys, json, random, os
sys.path.insert(0, "/home/claude/lab"); sys.path.insert(0, "/home/claude/lab/genres")
from labkit import n

OUTDIR = "/home/claude/band/out/templates"
# Groove pieces a template may use (lab-arranger.js maps each to the drum kit and to the congas & percussion).
PIECES = {"kick", "snare", "ghost", "hat", "openhat", "crash", "ride", "tomhi", "tomlo", "rim",
          "tumba", "conga", "quinto", "tap", "shaker", "claves", "cowbell"}


class Collector:
    """Stands in for a lab Part: the original composition code writes into it unchanged (no jitter)."""
    def __init__(self, name, seed=1):
        self.name, self.notes, self.cc = name, [], []
        self.rng = random.Random(seed)

    def add(self, beat, dur, note, vel, swing=False, jitter_ms=0, bpm=100):
        self.notes.append((round(beat, 4), round(dur, 4), n(note), max(1, min(127, int(vel)))))


def sw(b):
    """A written swung eighth: x.5 -> x.667 (the shuffle's third triplet)."""
    f = b - int(b)
    return int(b) + 2 / 3 if abs(f - 0.5) < 1e-6 else b


def part(pid, name, role, notes, poly=1, art=None, desc=""):
    ns = sorted(notes, key=lambda x: (x[0], -x[2]))
    out = []
    for b, d, m, v in ns:
        e = [round(b, 4), round(d, 4), int(m), int(v)]
        a = art(d) if callable(art) else art
        if a: e.append(a)
        out.append(e)
    ps = [e[2] for e in out]
    return {"id": pid, "name": name, "role": role, "polyphony": poly, "description": desc, "range": [min(ps), max(ps)], "notes": out}


def groove(pid, name, hits, desc=""):
    for h in hits:
        assert h[1] in PIECES, h
    return {"id": pid, "name": name, "role": "rhythm", "kind": "percussion", "description": desc,
            "hits": sorted([[round(b, 4), p, int(v)] for b, p, v in hits])}


def write(tpl):
    """Check the template, write it, print a summary (layers, first sound, notes per part)."""
    bpb = tpl["meter"][0]
    ids = {p["id"] for p in tpl["parts"]}
    for L in tpl["layers"]:
        assert L["part"] in ids, L
    assert len(tpl["chords"]) == tpl["bars"]
    total = tpl["bars"] * bpb
    for p in tpl["parts"]:
        ev = p.get("notes") or p.get("hits")
        assert ev, p["id"]
        assert all(0 <= e[0] < total for e in ev), (p["id"], [e[0] for e in ev if not 0 <= e[0] < total][:3])
    path = f"{OUTDIR}/comp-{tpl['id']}.json"
    os.makedirs(OUTDIR, exist_ok=True)
    json.dump(tpl, open(path, "w"), separators=(",", ":"))
    print(f"{tpl['title']}: {tpl['bars']} bars of {bpb}, {tpl['bpm']} bpm, {round(total * 60 / tpl['bpm'], 1)} s a loop, {os.path.getsize(path)} bytes")
    byid = {p["id"]: p for p in tpl["parts"]}
    for i, L in enumerate(tpl["layers"], 1):
        p = byid[L["part"]]
        ev = p.get("notes") or p.get("hits")
        bars = sorted({int(e[0] // bpb) for e in ev})
        print(f"  {i}. {L['name']:<14} {len(ev):4d} events, sounds in {len(bars)}/{tpl['bars']} bars, first bar {bars[0] + 1}")
