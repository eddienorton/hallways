"""RUA DAS LÂMPADAS -- the full piece (Oct 25 2026). Bossa nova, D (ending in E), 140 bpm, 4/4. ~2 min 20 s, 82 bars.

Grown from the Hallways Original (lab/genres/bossa.py, bossa_vocal.py): its tune, answers, harmony line, guitar
pattern, bass and percussion, now inside a performance where the musicians take turns.

  Intro        4   the guitar's pattern alone, then bass and percussion
  Head        32   A (tune) / A (tune, answers, harmony) / B (the bittersweet middle, held chords) / A
  Solos       16   the ANSWERS layer improvises over an A; then the HARMONY layer over the next
  B, trading   8   softer: the melody and the answers trade one-bar phrases
  Bass break   4   the bass walks a melodic line; guitar and percussion thin out
  Return       4   the melody climbs back in -- and the last chord turns to B7: a lift into E
  Last A       8   the tune a whole step higher (E), with everyone
  Tag          5   the hook's last phrase twice, slowing into the long note
  Ending       1   one soft chord

Layers (unchanged): Bass, Bossa chords, Percussion, Melody, Answers, Harmony, Held chords.
"""
import sys
sys.path.insert(0, "/home/claude/band/templates")
from tplkit import Piece, Collector, write, n
import bossa as Bo
import bossa_vocal as BV
from common import B, chord_at, spans
from labkit import chord, voicing

NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "G#", "A", "Bb", "B"]


def xpose(sym, t):
    if not t: return sym
    root = sym[:2] if len(sym) > 1 and sym[1] in "#b" else sym[:1]
    pc = (NAMES.index(root) if root in NAMES else {"Db": 1, "D#": 3, "Gb": 6, "Ab": 8, "A#": 10}[root]) + t
    return NAMES[pc % 12] + sym[len(root):]


def prog_syms(prog, t=0):
    return [[[b, xpose(s, t)] for b, s in bar] for bar in prog]


RETURN = Bo.A[4:7] + [[(0, "B7sus4"), (2, "B7b9")]]           # the last A's second half, its last chord the pivot to E
P = Piece(4)
intro = P.section("Intro", 4, prog_syms(Bo.INTRO))
a1 = P.section("A", 8, prog_syms(Bo.A))
a2 = P.section("A again", 8, prog_syms(Bo.A_END))
b1 = P.section("B", 8, prog_syms(Bo.BR))
a3 = P.section("A, home", 8, prog_syms(Bo.A))
s1 = P.section("Solo (Answers)", 8, prog_syms(Bo.A))
s2 = P.section("Solo (Harmony)", 8, prog_syms(Bo.A_END))
b2 = P.section("B, trading", 8, prog_syms(Bo.BR))
bb = P.section("Bass break", 4, prog_syms(Bo.A[:4]))
ret = P.section("Return", 4, prog_syms(RETURN))
a4 = P.section("Last A, in E", 8, prog_syms(Bo.A_END, 2))
tag = P.section("Tag", 5, prog_syms(Bo.TAG, 2))
end = P.section("Ending", 1, ["Emaj9"])
PIECES = {"congas": {60: "tap", 62: "quinto", 63: "conga", 64: "tumba"}, "shaker": {60: "shaker", 61: "shaker"}, "claves": {60: "claves"}}


def take(pid, notes, t=0, keep=lambda x: True):
    P.notes.setdefault(pid, []).extend((b, d, m + t, v) for b, d, m, v in notes if keep((b, d, m, v)))


def col(seed=3):
    return Collector("x", seed)


def rhythm(bar, prog, t=0, gvel=62, bvel=82, kvel=1.0, bongos=False, fill=False, guitar_keep=lambda x: True, kitchen=None):
    g = col(); Bo.guitar(g, bar + 1, prog, t=t, vel=gvel)
    take("guitar", [x for x in g.notes if x[2] >= n("E3") + t], keep=guitar_keep)
    b = col(4); Bo.bass(b, bar + 1, prog, t=t, vel=bvel)
    take("bass", b.notes, 12)                               # (at reading pitch, B1-D3: the source wrote it an octave low)
    K = {k: col(11 + i) for i, k in enumerate(["congas", "shaker", "claves", "bongos"])}
    Bo.kitchen(K, bar + 1, len(prog), vel=kvel, bongos=bongos, fill_last=fill, **(kitchen or {}))
    for k, c in K.items():
        if k in PIECES:
            for bt, d, m, v in c.notes:
                P.hits.setdefault("percussion", []).append((bt, PIECES[k][m], v))


def tune(pid, bar, mel, vel, t=0, legato=.95):
    c = col(); BV.line(c, bar + 1, mel, vel=vel, bpb=4, bpm=Bo.BPM, swell=False, legato=legato)
    take(pid, c.notes, t)


def harmony(bar, mel, prog, t=0, vel=64):
    for bi, notes in mel.items():
        for beat, dur, name in notes:
            sym = Bo.soft(chord_at(prog, bi, beat))
            r, pcs, _, _ = chord(sym)
            safe = [pc for pc in pcs if not any((pc - q) % 12 in (1, 11) for q in pcs)] or pcs
            lead = n(name)
            hm = next(m for m in range(lead - 3, lead - 13, -1) if m % 12 in safe)
            P.put("harmony", bar + bi - 1, [(beat, dur * .95, hm + t, vel)])


def pads(bar, prog, vel, t=0):
    for i, b, length, sym in spans(prog):
        P.put("pads", bar + i - 1, [(b + .5, length - .6, [m + t for m in voicing(Bo.soft(sym), 0, lo=n("A3"), hi=n("F#4") + 2)], vel)])


# ---------------------------------------------------------------- intro and head (the original song's form)
g = col(); Bo.guitar(g, intro + 1, Bo.INTRO, vel=60); take("guitar", [x for x in g.notes if x[2] >= n("E3")])
b = col(4); Bo.bass(b, intro + 3, Bo.INTRO[2:]); take("bass", b.notes, 12)
K = {k: col(11 + i) for i, k in enumerate(["congas", "shaker", "claves", "bongos"])}
Bo.kitchen(K, intro + 3, 2, vel=.8, bongos=False, fill_last=True)
for k, c in K.items():
    if k in PIECES:
        for bt, d, m, v in c.notes: P.hits.setdefault("percussion", []).append((bt, PIECES[k][m], v))
rhythm(a1, Bo.A)
tune("melody", a1, Bo.TUNE_A, 74)
tune("answers", a1, BV.FLUTE_ANS, 60)
rhythm(a2, Bo.A_END, fill=True)
tune("melody", a2, Bo.TUNE_A_END, 78)
tune("answers", a2, Bo.ANSWERS, 60)
harmony(a2, Bo.TUNE_A_END, Bo.A_END)
rhythm(b1, Bo.BR, gvel=56, kvel=.85)
tune("melody", b1, Bo.TUNE_B, 72)
pads(b1, Bo.BR, 44)
rhythm(a3, Bo.A)
tune("melody", a3, Bo.TUNE_A, 78)
tune("answers", a3, {k: v for k, v in BV.FLUTE_ANS.items() if k <= 4}, 60)
tune("answers", a3, {k: v for k, v in Bo.ANSWERS.items() if k > 4}, 60)
harmony(a3, Bo.TUNE_A, Bo.A)
pads(a3, Bo.A, 34)

# ---------------------------------------------------------------- solos: Answers, then Harmony
rhythm(s1, Bo.A, gvel=58, bongos=True)
P.line("answers", s1, {
    0: [(0, .5, "F#5"), (.5, .5, "A5"), (1, .5, "C#6"), (1.5, 1, "A5"), (2.5, .5, "F#5"), (3, 1, "E5")],
    1: [(0, .5, "D5"), (.5, .5, "F#5"), (1, 1.5, "B5"), (2.5, .5, "A5"), (3, .5, "F#5")],
    2: [(0, 1, "G5"), (1, .5, "F#5"), (1.5, .5, "E5"), (2, .5, "D5"), (2.5, 1.5, "B4")],
    3: [(.5, .5, "C#5"), (1, .5, "E5"), (1.5, .5, "F#5"), (2, 2, "G5")],
    4: [(0, .5, "A5"), (.5, .5, "G#5"), (1, 1, "F#5"), (2, .5, "E5"), (2.5, .5, "C#5"), (3, 1, "A4")],
    5: [(0, .5, "D#5"), (.5, .5, "F#5"), (1, .5, "A5"), (1.5, .5, "C6"), (2, 2, "B5")],
    6: [(0, .5, "G5"), (.5, .5, "F#5"), (1, .5, "E5"), (1.5, .5, "B4"), (2, 1.5, "D5")],
    7: [(0, 1.5, "E5"), (2, .5, "G5"), (2.5, .5, "E5"), (3, 1, "C#5")]}, vel=80, legato=.95)
pads(s1, Bo.A, 30)
rhythm(s2, Bo.A_END, gvel=58, bongos=True, fill=True)
P.line("harmony", s2, {
    0: [(0, 1.5, "A4"), (1.5, .5, "B4"), (2, 1, "C#5"), (3, .5, "E5"), (3.5, .5, "F#5")],
    1: [(0, 2, "D5"), (2, .5, "C#5"), (2.5, .5, "B4"), (3, 1, "A4")],
    2: [(0, .5, "B4"), (.5, .5, "D5"), (1, .5, "F#5"), (1.5, 1.5, "E5"), (3, 1, "D5")],
    3: [(0, 1, "C#5"), (1, .5, "B4"), (1.5, .5, "A4"), (2, 2, "G4")],
    4: [(.5, .5, "A4"), (1, .5, "C#5"), (1.5, .5, "E5"), (2, 1.5, "A5"), (3.5, .5, "G#5")],
    5: [(0, 1, "F#5"), (1, .5, "D#5"), (1.5, .5, "C5"), (2, 2, "A4")],
    6: [(0, .5, "G4"), (.5, .5, "B4"), (1, 1, "D5"), (2, .5, "C#5"), (2.5, .5, "E5"), (3, 1, "G5")],
    7: [(0, 3, "F#5")]}, vel=78, legato=.95)
P.line("answers", s2, {1: [(2.5, .5, "F#5"), (3, .5, "A5"), (3.5, .5, "B5")], 5: [(2.5, .5, "D#5"), (3, .5, "F#5"), (3.5, .5, "A5")]}, vel=58)   # little nods to the soloist

# ---------------------------------------------------------------- B, trading (softer)
rhythm(b2, Bo.BR, gvel=50, bvel=74, kvel=.7)
P.line("melody", b2, {
    0: [(0, 1.5, "B4"), (1.5, .5, "D5"), (2, 2, "F#5")],
    2: [(0, 1.5, "A4"), (1.5, .5, "C#5"), (2, 2, "E5")],
    4: [(0, 1.5, "G4"), (1.5, .5, "B4"), (2, 2, "F#5")],
    6: [(0, 1, "A5"), (1, .5, "G#5"), (1.5, .5, "F#5"), (2, 1, "D#5"), (3, 1, "F#5")]}, vel=66)
P.line("answers", b2, {
    1: [(0, .5, "G5"), (.5, .5, "Bb5"), (1, 1, "D6"), (2, 1.5, "E5")],
    3: [(0, .5, "D#5"), (.5, .5, "F#5"), (1, 1, "A5"), (2, 1.5, "C5")],
    5: [(0, .5, "F#5"), (.5, .5, "E5"), (1, 1, "C#5"), (2, 1.5, "A4")],
    7: [(0, .5, "G5"), (.5, .5, "E5"), (1, 1, "B4"), (2, 1, "C#5"), (3, 1, "E5")]}, vel=64)
pads(b2, Bo.BR, 40)

# ---------------------------------------------------------------- bass break; the return
P.line("bass", bb, {
    0: [(0, 1, "D2"), (1, 1, "F#2"), (2, 1, "A2"), (3, 1, "C#3")],
    1: [(0, 1, "D3"), (1, .5, "C#3"), (1.5, .5, "B2"), (2, 1, "A2"), (3, 1, "F#2")],
    2: [(0, 1, "E2"), (1, 1, "G2"), (2, 1, "B2"), (3, .5, "D3"), (3.5, .5, "B2")],
    3: [(0, 1, "A2"), (1, 1, "G2"), (2, 1, "E2"), (3, 1, "C#2")]}, vel=90, legato=.9)
g = col(); Bo.guitar(g, bb + 1, Bo.A[:4], vel=48)
take("guitar", [x for x in g.notes if x[2] >= n("E3") and abs((x[0] % 4)) < .1])   # (only the downbeat chords)
for i in range(4):
    for k in range(8):
        P.hit("percussion", bb + i, k * .5, "shaker", 46 if k % 2 else 34)
rhythm(ret, RETURN, fill=True)
tune("melody", ret, {k - 4: v for k, v in Bo.TUNE_A.items() if 5 <= k <= 7}, 80)
P.put("melody", ret + 3, [(0, 1, "A5", 82), (1, .5, "F#5", 78), (1.5, .5, "E5", 76), (2, 2, "F#5", 84)])
P.put("pads", ret + 3, [(0, 3.6, ["E4", "F#4", "A4", "B3"], 44)])

# ---------------------------------------------------------------- last A, in E; tag; ending
rhythm(a4, Bo.A_END, t=2, gvel=66, bongos=True)
tune("melody", a4, Bo.TUNE_A_END, 84, t=2)
tune("answers", a4, Bo.ANSWERS, 64, t=2)
harmony(a4, Bo.TUNE_A_END, Bo.A_END, t=2, vel=68)
pads(a4, Bo.A_END, 38, t=2)
rhythm(tag, Bo.TAG[:4], t=2, gvel=56, kvel=.75)
tune("melody", tag, Bo.TAG_TUNE, 72, t=2)
tune("answers", tag, {2: [(2.5, .5, "F#4"), (3, .5, "A4"), (3.5, .5, "B4")], 4: [(2.5, .5, "A4"), (3, .5, "C#5"), (3.5, .5, "E5")]}, 56, t=2)
P.put("pads", tag + 4, [(0, 3.8, ["E4", "G#4", "B4", "D#5"], 40)])
P.put("guitar", tag + 4, [(k * .06, 3.8, m, 58) for k, m in enumerate(["G#3", "B3", "D#4", "F#4"])])
P.put("bass", tag + 4, [(0, 3, "E2", 80)])
P.hit("percussion", tag + 4, 0, "tumba", 50)
# the last chord, soft
P.put("guitar", end, [(.5 + k * .08, 3.2, m, 56) for k, m in enumerate(["E3", "B3", "D#4", "F#4", "G#4"])])
P.put("pads", end, [(.5, 3.2, ["E4", "G#4", "B4", "D#5"], 40)])
P.put("bass", end, [(.5, 3, "E2", 78)])
P.put("melody", end, [(.5, 3, "B5", 66)])
P.hit("percussion", end, .5, "tumba", 52); P.hit("percussion", end, 1.25, "claves", 40)

tpl = P.template(
    {"id": "bossa-nova", "title": "Rua das Lâmpadas", "genre": "jazz", "style": "Bossa nova",
     "source": "Hallways Originals: Rua das Lâmpadas (lab/genres/bossa.py, bossa_vocal.py), developed into a full piece Oct 25 2026",
     "bpm": 140, "key": "D (ending in E)", "feel": "straight eighths, bossa syncopation"},
    [("bass", "Bass", "bass", 1, None, "Roots and fifths, anticipating; a melodic walk in the bass break."),
     ("guitar", "Bossa chords", "comp", 4, "held", "The guitar's syncopated two-bar bossa chords."),
     ("percussion", "Percussion", "rhythm", 1, None, "Congas, shaker, claves; bongos under the solos; the shaker alone in the bass break."),
     ("melody", "Melody", "melody", 1, "legato", "The tune; one-bar calls in the trading B; the lift into E; the tag."),
     ("answers", "Answers", "answer", 1, None, "Little replies in the tune's long notes -- and a solo over an A."),
     ("harmony", "Harmony", "harmony", 1, "legato", "A line under the tune -- and a solo of its own."),
     ("pads", "Held chords", "pad", 4, None, "Soft held chords under the B sections, the solos and the ending.")],
    [("bass", "Bass"), ("guitar", "Bossa chords"), ("percussion", "Percussion"), ("melody", "Melody"),
     ("answers", "Answers"), ("harmony", "Harmony"), ("pads", "Held chords")])
write(tpl)
