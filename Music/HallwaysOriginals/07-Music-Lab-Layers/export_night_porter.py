"""Convert "Night Porter" (lab/genres/soul.py, Hallways Originals #3) into an instrument-independent
composition template: hallways-composition/1 JSON.

The composition's own note-writing functions are run unchanged, but into collectors named for the
MUSICAL PART each one writes (melody, answers, bass, chords...), not for the instrument it was first
recorded on. No timing jitter (the performer adds its own); velocities as composed.

  python3 export_night_porter.py  ->  out/templates/comp-night-porter.json
"""
import sys, json, random, os
sys.path.insert(0, "/home/claude/lab"); sys.path.insert(0, "/home/claude/lab/genres")
from labkit import n
import soul as S

OUT = "/home/claude/band/out/templates/comp-night-porter.json"
KIT = {36: "kick", 38: "snare", 42: "hat", 46: "openhat", 49: "crash", 50: "tomhi", 45: "tomlo"}


class Collector:
    def __init__(self, name, seed):
        self.name, self.notes, self.cc = name, [], []
        self.rng = random.Random(seed)

    def add(self, beat, dur, note, vel, swing=False, jitter_ms=0, bpm=100):
        self.notes.append((round(beat, 4), round(dur, 4), n(note), max(1, min(127, int(vel)))))


def collect():
    C = {k: Collector(k, i + 7) for i, k in enumerate(
        ["melody", "answer1", "answer2", "answer3", "bass", "comp", "organ", "drums"])}
    horns = {"trumpet": C["answer1"], "sax": C["answer2"], "trombone": C["answer3"]}
    bar = 1
    # chorus 1: the head (melody + three-part horn answers), chops, the boogaloo bass, the groove
    S.line(C["melody"], bar, S.HEAD, vel=96, bpb=4, bpm=S.BPM, swell=False, legato=.9)
    S.horn_hits(horns, bar, S.BLUES, S.ANSWERS)
    S.chops(C["comp"], bar, S.BLUES)
    S.bass(C["bass"], bar, S.BLUES)
    S.drums(C["drums"], bar, 12, fills=(12,), crash=(1,))
    bar += 12
    # chorus 2: the solos become one continuous lead line (guitar's 4 bars, organ's 4, the horn shout's top);
    # chords: the organ's comping under the first solo, the chops after; the shout's harmony = the answers
    S.line(C["melody"], bar, S.GUITAR_SOLO, vel=88, bpb=4, bpm=S.BPM, swell=False, legato=.9)
    S.line(C["melody"], bar, S.ORGAN_SOLO, vel=98, bpb=4, bpm=S.BPM, swell=False, legato=.9)
    # the shout (soul.horn_line), its two harmony notes kept in close position under the line
    for b_, notes in S.SHOUT.items():
        sym = S.BLUES[b_ - 1]
        for beat, dur, name in notes:
            top = n(name)
            h1, h2 = S.harm_below(top, sym, 0, count=2)
            t = S.B(bar, b_, 4) + beat
            C["melody"].add(t, dur * .92, top, 90)
            C["answer1"].add(t, dur * .92, h1, 84)
            C["answer2"].add(t, dur * .92, h2, 86)
    S.organ_comp(C["comp"], bar, S.BLUES, skip=range(5, 13))
    S.chops(C["comp"], bar, S.BLUES, skip=(1, 2, 3, 4))
    S.bass(C["bass"], bar, S.BLUES)
    S.drums(C["drums"], bar, 12, fills=(4, 8, 12), crash=(1, 5, 9))
    # the organ's held chords, all 24 bars (a sustained accompaniment part, from organ_comp's voicings)
    S.organ_comp(C["organ"], 1, S.BLUES + S.BLUES, vel=58)
    return C


def art(part, d):
    if part == "drums":
        return None
    if part == "comp":
        return "staccato" if d < 0.3 else "held"
    if part.startswith("answer"):
        return "accent" if d < 0.5 else "held"
    if part == "melody":
        return "legato"
    return None


def main():
    C = collect()
    parts = []
    meta = {
        "melody": ("Melody", "melody", 1, 1, "The tune (head), then the solo chorus as one lead line."),
        "bass": ("Bass line", "bass", 2, 1, "The boogaloo riff, G G Bb C C# D F."),
        "comp": ("Chords", "comp", 3, 3, "Short offbeat chord chops; held chords under the first solo."),
        "answer1": ("Answers", "answer", 4, 1, "The horn answers' top voice; the shout's harmony."),
        "organ": ("Held chords", "pad", 5, 3, "Two held chords a bar, all the way through."),
        "answer2": ("Harmony", "harmony", 6, 1, "The answers' middle voice; the shout's low harmony."),
        "answer3": ("Low harmony", "harmony", 7, 1, "The answers' lowest voice."),
    }
    for pid, (name, role, prio, poly, desc) in meta.items():
        ns = sorted(C[pid].notes)
        notes = []
        for b, d, m, v in ns:
            e = [b, d, m, v]
            a = art(pid, d)
            if a: e.append(a)
            notes.append(e)
        ps = [x[2] for x in notes]
        parts.append({"id": pid, "name": name, "role": role, "priority": prio, "polyphony": poly, "description": desc,
                      "range": [min(ps), max(ps)], "notes": notes})
    hits = sorted((round(b, 4), KIT[m], v) for b, d, m, v in C["drums"].notes)
    parts.append({"id": "drums", "name": "Groove", "role": "rhythm", "priority": 0, "kind": "percussion",
                  "description": "Kick on 1, the a of 1, the and of 3; backbeat; eighth hats; ghost notes; fills every 4 bars in the solos.",
                  "hits": [[b, k if not (k == "snare" and v < 50) else "ghost", v] for b, k, v in hits]})
    tpl = {
        "format": "hallways-composition/1",
        "id": "night-porter", "title": "Night Porter", "genre": "blues",
        "style": "Soul-jazz blues (boogaloo)", "source": "Hallways Originals #3 (lab/genres/soul.py), converted Oct 24 2026",
        "bpm": 100, "meter": [4, 4], "key": "G", "feel": "straight sixteenths",
        "bars": 24, "loop": True,
        "sections": [{"name": "Head", "start": 0, "bars": 12}, {"name": "Solos", "start": 12, "bars": 12}],
        "chords": [[[0, c]] for c in S.BLUES + S.BLUES],
        "parts": parts,
        # the layer stack: the order musicians are given parts as the player switches them on (foundation
        # to foreground). It says nothing about WHEN a layer plays -- that is each part's own notes.
        "layers": [{"part": "bass", "name": "Bass line"}, {"part": "drums", "name": "Groove"}, {"part": "comp", "name": "Chords"},
                   {"part": "organ", "name": "Held chords"}, {"part": "melody", "name": "Melody"}, {"part": "answer1", "name": "Answers"},
                   {"part": "answer2", "name": "Harmony"}, {"part": "answer3", "name": "Low harmony"}],
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(tpl, open(OUT, "w"), separators=(",", ":"))
    for p in parts:
        print(p["id"], len(p.get("notes", p.get("hits", []))), p.get("range"))
    print("wrote", OUT, os.path.getsize(OUT), "bytes")


if __name__ == "__main__":
    main()
