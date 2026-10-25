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


# ---------------------------------------------------------------------------------------------------------
# Oct 25: whole pieces (not loops). A Piece collects every part's notes by absolute bar, the chord chart and
# the sections, then writes a template with "loop": false and an ending.

def nn(x):
    return x if isinstance(x, int) else n(x)


class Piece:
    def __init__(self, bpb):
        self.bpb = bpb
        self.notes = {}        # part id -> [(beat, dur, midi, vel, art?)]
        self.hits = {}         # groove id -> [(beat, piece, vel)]
        self.chords = []       # per bar: [[beat, sym]]
        self.sections = []

    def section(self, name, bars, chords):
        """A section: its name, length, and chord per bar (a symbol, or [[beat, sym], ...])."""
        start = len(self.chords)
        assert len(chords) == bars, (name, len(chords), bars)
        for c in chords:
            self.chords.append([[0, c]] if isinstance(c, str) else [list(x) for x in c])
        self.sections.append({"name": name, "start": start, "bars": bars})
        return start

    def chord(self, bar, beat=0):
        sym = self.chords[bar][0][1]
        for b, s in self.chords[bar]:
            if b <= beat + 1e-6: sym = s
        return sym

    def put(self, pid, bar, notes, vel=None, art=None, legato=1.0, shift=0):
        """notes: [(beat, beats, pitch(es), vel?)] in bar `bar` (beats may run past the bar)."""
        out = self.notes.setdefault(pid, [])
        for x in notes:
            beat, dur, p = x[0], x[1], x[2]
            v = x[3] if len(x) > 3 else (vel or 80)
            for q in (p if isinstance(p, (list, tuple)) else [p]):
                if q is None: continue
                e = (bar * self.bpb + beat, dur * legato, nn(q) + shift, v)
                out.append(e + ((art,) if art else ()))

    def line(self, pid, bar, bars_notes, **kw):
        """bars_notes: {bar offset (0-based): [(beat, beats, pitch, vel?)]}"""
        for k, notes in bars_notes.items():
            self.put(pid, bar + k, notes, **kw)

    def hit(self, gid, bar, beat, piece, vel):
        self.hits.setdefault(gid, []).append((bar * self.bpb + beat, piece, vel))

    @property
    def bars(self):
        return len(self.chords)

    def template(self, meta, parts, layers):
        """parts: [(id, name, role, poly, art, desc)] -- pitched ids from self.notes, grooves from self.hits."""
        out = []
        for pid, name, role, poly, art, desc in parts:
            if pid in self.hits:
                out.append(groove(pid, name, self.hits[pid], desc=desc))
            else:
                ns = [(b, d, m, v) for b, d, m, v, *_ in self.notes[pid]]
                arts = {(round(b, 4), m): a[0] for b, d, m, v, *a in self.notes[pid] if a}
                p = part(pid, name, role, ns, poly=poly, art=art, desc=desc)
                for e in p["notes"]:
                    a = arts.get((e[0], e[2]))
                    if a:
                        if len(e) > 4: e[4] = a
                        else: e.append(a)
                out.append(p)
        tpl = dict(meta)
        tpl.update({"format": "hallways-composition/1", "meter": [self.bpb, 4], "bars": self.bars, "loop": False,
                    "sections": self.sections, "chords": self.chords, "parts": out,
                    "layers": [{"part": a, "name": b} for a, b in layers]})
        return tpl
