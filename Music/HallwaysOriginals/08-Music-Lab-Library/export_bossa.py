"""Rua das Lâmpadas (Hallways Originals, lab/genres/bossa.py + bossa_vocal.py) -> an instrument-independent
template: Jazz / "Bossa Nova". The song's own note-writing functions, run into collectors named for parts.

Form (the lab loop, 32 bars, 140 bpm): A (tune; answers an octave up) / A (tune, home ending; answers;
a harmony line under the tune) / B (the bittersweet middle; held chords) / A (tune; answers; harmony;
held chords softly) -- its last bar (A7) turns back to the top.
The guitar's bossa pattern keeps its syncopated chords; its thumb (roots on 1 and 3) is left to the bass layer."""
import sys
sys.path.insert(0, "/home/claude/band/templates")
from tplkit import Collector, part, groove, write, n
import bossa as Bo
import bossa_vocal as BV
from common import B, line, chord_at, spans, add
from labkit import chord, voicing

PROG = Bo.A + Bo.A_END + Bo.BR + Bo.A


def main():
    C = {k: Collector(k, i + 3) for i, k in enumerate(["bass", "guitar", "melody", "answers", "harmony", "pads"])}
    P = {k: Collector(k, 11 + i) for i, k in enumerate(["congas", "shaker", "claves", "bongos"])}
    # the rhythm, all 32 bars
    Bo.guitar(C["guitar"], 1, PROG)
    Bo.bass(C["bass"], 1, PROG)
    Bo.kitchen(P, 1, 8, bongos=False)
    Bo.kitchen(P, 9, 8, bongos=False, fill_last=True)
    Bo.kitchen(P, 17, 8, vel=0.85, bongos=False)
    Bo.kitchen(P, 25, 8, bongos=False)
    # the tune
    line(C["melody"], 1, Bo.TUNE_A, vel=74, bpb=4, bpm=Bo.BPM, swell=False)
    line(C["melody"], 9, Bo.TUNE_A_END, vel=78, bpb=4, bpm=Bo.BPM, swell=False)
    line(C["melody"], 17, Bo.TUNE_B, vel=72, bpb=4, bpm=Bo.BPM, swell=False)
    line(C["melody"], 25, Bo.TUNE_A, vel=78, bpb=4, bpm=Bo.BPM, swell=False)
    # answers in the tune's long notes: high in A1, the piano's in A2, both in A3
    line(C["answers"], 1, BV.FLUTE_ANS, vel=60, bpb=4, bpm=Bo.BPM, swell=False)
    line(C["answers"], 9, Bo.ANSWERS, vel=60, bpb=4, bpm=Bo.BPM, swell=False)
    line(C["answers"], 25, {k: v for k, v in BV.FLUTE_ANS.items() if k <= 4}, vel=60, bpb=4, bpm=Bo.BPM, swell=False)
    line(C["answers"], 25, {k: v for k, v in Bo.ANSWERS.items() if k > 4}, vel=60, bpb=4, bpm=Bo.BPM, swell=False)
    # the harmony singer's line (a safe chord tone under each note), now for anyone, in A2 and A3
    class H(Collector):
        pass
    h = C["harmony"]
    for bar0, mel, prog in [(9, Bo.TUNE_A_END, Bo.A_END), (25, Bo.TUNE_A, Bo.A)]:
        for bar, notes in mel.items():
            for beat, dur, name in notes:
                sym = Bo.soft(chord_at(prog, bar, beat))
                r, pcs, _, _ = chord(sym)
                safe = [pc for pc in pcs if not any((pc - q) % 12 in (1, 11) for q in pcs)] or pcs
                lead = n(name)
                hm = next(m for m in range(lead - 3, lead - 13, -1) if m % 12 in safe)
                h.add(B(bar0, bar, 4) + beat, dur * 0.95, hm, 64)
    # held chords: the B section's piano pads; softer under the last A
    for bar0, prog, vel in [(17, Bo.BR, 44), (25, Bo.A, 34)]:
        for i, b, length, sym in spans(prog):
            for m in voicing(Bo.soft(sym), 0, lo=n("A3"), hi=n("F#4") + 2):
                C["pads"].add(B(bar0, i, 4) + b + 0.5, length - 0.6, m, vel)
    # guitar: keep the chords (E3 and up); the thumb's roots belong to the bass
    chords_only = [x for x in C["guitar"].notes if x[2] >= n("E3")]
    pieces = {"congas": {60: "tap", 62: "quinto", 63: "conga", 64: "tumba"}, "shaker": {60: "shaker", 61: "shaker"}, "claves": {60: "claves"}}
    hits = [(b, pieces[k][m], v) for k, col in P.items() if k in pieces for b, d, m, v in col.notes]
    tpl = {
        "format": "hallways-composition/1", "id": "bossa-nova", "title": "Rua das Lâmpadas", "genre": "jazz",
        "style": "Bossa nova", "source": "Hallways Originals: Rua das Lâmpadas (lab/genres/bossa.py, bossa_vocal.py), converted Oct 25 2026",
        "bpm": 140, "meter": [4, 4], "key": "D", "feel": "straight eighths, bossa syncopation",
        "bars": 32, "loop": True,
        "sections": [{"name": "A", "start": 0, "bars": 8}, {"name": "A again", "start": 8, "bars": 8},
                     {"name": "B", "start": 16, "bars": 8}, {"name": "A, last time", "start": 24, "bars": 8}],
        "chords": [[[b, s] for b, s in bar] for bar in PROG],
        "parts": [
            # (the source wrote the bass an octave low, B0-D2, for the contrabass sample's keymap; here it is at
            # the pitch a bass player reads, B1-D3, like Night Porter's)
            part("bass", "Bass", "bass", [(t, d, m + 12, v) for t, d, m, v in C["bass"].notes], desc="Roots and fifths, a beat and a half each, anticipating."),
            part("guitar", "Bossa chords", "comp", chords_only, poly=4, art="held", desc="The guitar's syncopated two-bar bossa chords."),
            groove("percussion", "Percussion", hits, desc="Congas, shaker, claves (the 3-2 clave): the light Brazilian kitchen."),
            part("melody", "Melody", "melody", C["melody"].notes, art="legato", desc="Rua das Lâmpadas' tune: the rising hook, the long notes, the bittersweet B."),
            part("answers", "Answers", "answer", C["answers"].notes, desc="Little three-note replies in the tune's long notes."),
            part("harmony", "Harmony", "harmony", h.notes, art="legato", desc="A line under the tune (the old harmony singer's), in the second and last A."),
            part("pads", "Held chords", "pad", C["pads"].notes, poly=4, desc="Soft held chords in the B section and under the last A."),
        ],
        "layers": [{"part": "bass", "name": "Bass"}, {"part": "guitar", "name": "Bossa chords"}, {"part": "percussion", "name": "Percussion"},
                   {"part": "melody", "name": "Melody"}, {"part": "answers", "name": "Answers"}, {"part": "harmony", "name": "Harmony"},
                   {"part": "pads", "name": "Held chords"}],
    }
    write(tpl)


if __name__ == "__main__":
    main()
