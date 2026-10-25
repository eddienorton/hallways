"""MINUET AND TRIO -- the full piece (Oct 25 2026). Classical, G major (trio in C), 3/4, 120 bpm.
~2 min 24 s, 96 bars. The Stage A minuet is its first part; the rest is new.

  Minuet      32   A / A (the high ending) / B (questions and echoes) / A (sixths in the countermelody)
  Trio        32   C major, gentler. The COUNTERMELODY layer takes the tune; the melody layer floats a high
                   descant above it; the pah-pah chords become rippling broken chords; the bass holds. In the
                   minor D phrase the melody takes over, the countermelody slides down under it.
  Link         2   back toward G
  Minuet      24   da capo: A dressed up (runs and turns), B, A with sixths
  Coda         6   a cadence, a last arpeggio from the sparkles, a final chord

Layers (unchanged): Bass, Pah-pah chords, Melody, Countermelody, Sparkles.
"""
import sys
sys.path.insert(0, "/home/claude/band/templates")
from tplkit import Piece, write, n
import compose_minuet as M
from labkit import chord

P = Piece(3)
TRIO_C = ["C", "G7", "C", "F", "C", "G", "D7", "G"]
TRIO_C2 = ["C", "G7", "C", "F", "Am", "D7", "G7", "C"]
TRIO_D = ["Am", "E7", "Am", "E7", "F", "C", "D7", "G7"]
CODA = ["G", "C", "G", "D7", "G", "G"]
m_a1 = P.section("Minuet A", 8, M.A_CH)
m_a2 = P.section("Minuet A again", 8, M.A_CH)
m_b = P.section("Minuet B", 8, M.B_CH)
m_a3 = P.section("Minuet A, last", 8, M.A_CH)
t_c = P.section("Trio C", 8, TRIO_C)
t_c2 = P.section("Trio C again", 8, TRIO_C2)
t_d = P.section("Trio D (minor)", 8, TRIO_D)
t_c3 = P.section("Trio C, last", 8, TRIO_C2)
link = P.section("Link", 2, ["Am", "D7"])
d_a = P.section("Minuet A, dressed up", 8, M.A_CH)
d_b = P.section("Minuet B", 8, M.B_CH)
d_a2 = P.section("Minuet A, last", 8, M.A_CH)
coda = P.section("Coda", 6, CODA)

A_VAR = {1: [(0, .5, "B4"), (.5, .5, "C5"), (1, .5, "D5"), (1.5, .5, "E5"), (2, 1, "G5")],
         2: [(0, .25, "G5"), (.25, .25, "F#5"), (.5, .5, "E5"), (1, 2, "D5")],
         3: [(0, 1, "E5"), (1, .5, "G5"), (1.5, .5, "F#5"), (2, 1, "E5")],
         4: [(0, 1, "D5"), (1, 1, "C5"), (2, 1, "B4")],
         5: [(0, .5, "C5"), (.5, .5, "B4"), (1, 1, "A4"), (2, .5, "C5"), (2.5, .5, "E5")],
         6: [(0, .5, "D5"), (.5, .5, "E5"), (1, .5, "F#5"), (1.5, .5, "G5"), (2, 1, "A5")],
         7: [(0, 1.5, "B4"), (1.5, .25, "C5"), (1.75, .25, "B4"), (2, 1, "A4")],
         8: [(0, 2, "G4")]}


def root_of(sym, lo="G2", hi="D3"):
    r, pcs, bs, _ = chord(sym)
    p = n(lo) + ((bs - n(lo)) % 12)
    return p if p <= n(hi) else p - 12


def minuet_bar(bar, sym, k, tune, counter_mode, spark=None):
    """One bar of the minuet's texture (k: 1-8 in its phrase)."""
    root = root_of(sym)
    P.put("bass", bar, [(0, 1.6, root, 82)])
    if k == 7: P.put("bass", bar, [(1, .9, root + 2, 70), (2, .9, root + 4, 72)])
    elif k not in (4, 8): P.put("bass", bar, [(2, .9, root + 7 if root + 7 <= n("D3") + 2 else root - 5, 70)])
    if k != 8:
        tones = sorted({n("G3") + ((pc - n("G3")) % 12) for pc in M.pcs_of(sym)})[:3]
        P.put("pahpah", bar, [(1, .45, tones, 56), (2, .45, tones, 50)])
    for beat, d, name in tune.get(k, []):
        if name is None: continue
        P.put("melody", bar, [(beat, d * .95, name, 80 + (6 if beat == 0 else 0))])
        if counter_mode == "sixths":
            c = M.below(n(name), sym, n("D4"), n("D5"))
            if c: P.put("counter", bar, [(beat, d * .95, c, 64)])
    if counter_mode == "echo":
        P.put("counter", bar, [(b, d * .95, nm, 66) for b, d, nm in M.B_ECHO.get(k, [])])
    if spark:
        P.put("sparkles", bar, [(b, d * .9, nm, 60) for b, d, nm in spark])


def minuet(bar0, chords, tune, counter_mode, sparks):
    for k in range(1, 9):
        minuet_bar(bar0 + k - 1, chords[k - 1], k, tune, counter_mode, sparks.get(k))


SP = M.SPARK
# ---------------------------------------------------------------- MINUET
minuet(m_a1, M.A_CH, M.A1, None, {4: SP[(1, 4)], 8: SP[(1, 8)]})
minuet(m_a2, M.A_CH, M.A2, None, {4: SP[(2, 4)], 8: SP[(2, 8)]})
minuet(m_b, M.B_CH, M.B, "echo", {2: SP[(3, 2)], 6: SP[(3, 6)], 8: SP[(3, 8)]})
minuet(m_a3, M.A_CH, M.A2, "sixths", {4: SP[(4, 4)], 8: SP[(4, 8)]})

# ---------------------------------------------------------------- TRIO
TRIO_TUNE_C = {1: [(0, 2, "E4"), (2, 1, "G4")], 2: [(0, 1, "F4"), (1, 1, "D4"), (2, 1, "G4")],
               3: [(0, 1, "E4"), (1, 1, "C5"), (2, 1, "B4")], 4: [(0, 2, "A4"), (2, 1, "C5")],
               5: [(0, 1, "G4"), (1, .5, "E4"), (1.5, .5, "F4"), (2, 1, "G4")], 6: [(0, 1, "D5"), (1, 1, "B4"), (2, 1, "G4")],
               7: [(0, 1, "A4"), (1, 1, "F#4"), (2, 1, "C5")], 8: [(0, 3, "B4")]}
TRIO_TUNE_C2 = {1: [(0, 2, "E4"), (2, 1, "G4")], 2: [(0, 1, "F4"), (1, 1, "D4"), (2, 1, "B4")],
                3: [(0, 1, "C5"), (1, 1, "E5"), (2, 1, "C5")], 4: [(0, 2, "A4"), (2, 1, "F4")],
                5: [(0, 1, "E4"), (1, 1, "A4"), (2, 1, "C5")], 6: [(0, 1, "D5"), (1, 1, "C5"), (2, 1, "A4")],
                7: [(0, 1, "G4"), (1, 1, "B4"), (2, 1, "D5")], 8: [(0, 3, "C5")]}
DESCANT_C = ["G5", "G5", "G5", "A5", "G5", "G5", "F#5", "G5"]
DESCANT_C2 = ["G5", "F5", "E5", "F5", "E5", "F#5", "F5", "E5"]
TRIO_D_MEL = {1: [(0, 1, "C5"), (1, 1, "E5"), (2, 1, "A5")], 2: [(0, 2, "G#5"), (2, 1, "E5")],
              3: [(0, 1, "A5"), (1, .5, "G#5"), (1.5, .5, "A5"), (2, 1, "E5")], 4: [(0, 3, "D5")],
              5: [(0, 1, "C5"), (1, 1, "F5"), (2, 1, "A5")], 6: [(0, 2, "G5"), (2, 1, "E5")],
              7: [(0, 1, "F#5"), (1, 1, "D5"), (2, 1, "A4")], 8: [(0, 1, "B4"), (1, 1, "D5"), (2, 1, "F5")]}
TRIO_D_COUNTER = ["A4", "B4", "C5", "B4", "A4", "G4", "F#4", "F4"]
TRIO_SPARK = {4: [(2, .33, "C6"), (2.33, .33, "E6"), (2.67, .33, "G6")], 8: [(2, .5, "B5"), (2.5, .5, "D6")]}


def broken(bar, sym, vel=48):
    """Rippling broken chord, six eighths: root, fifth, third, fifth, third, fifth (C3-C4 region)."""
    r, pcs, bs, _ = chord(sym)
    base = n("C3") + ((bs - n("C3")) % 12)
    third = base + ((pcs[1] - pcs[0]) % 12)
    fifth = base + ((pcs[2] - pcs[0]) % 12)
    seq = [base, fifth, third + 12 if third < fifth else third, fifth, third + 12 if third < fifth else third, fifth]
    P.put("pahpah", bar, [(k * .5, .45, m, vel + (6 if k == 0 else 0)) for k, m in enumerate(seq)])


def trio(bar0, chords, tune, descant, spark=True, last=False):
    for k in range(1, 9):
        bar, sym = bar0 + k - 1, chords[k - 1]
        P.put("bass", bar, [(0, 2.8, root_of(sym, "C2", "G2") + 12, 70)])
        broken(bar, sym)
        P.put("counter", bar, [(b, d * .97, nm, 76) for b, d, nm in tune.get(k, [])])
        P.put("melody", bar, [(0, 2.9, descant[k - 1], 56)])
        if spark and k in TRIO_SPARK:
            P.put("sparkles", bar, [(b, d * .9, nm, 56) for b, d, nm in TRIO_SPARK[k]])


trio(t_c, TRIO_C, TRIO_TUNE_C, DESCANT_C)
trio(t_c2, TRIO_C2, TRIO_TUNE_C2, DESCANT_C2)
for k in range(1, 9):                                     # the minor phrase: the melody takes over
    bar, sym = t_d + k - 1, TRIO_D[k - 1]
    P.put("bass", bar, [(0, 2.8, root_of(sym, "C2", "G2") + 12, 74)])
    broken(bar, sym, vel=52)
    P.put("melody", bar, [(b, d * .95, nm, 82) for b, d, nm in TRIO_D_MEL[k]])
    P.put("counter", bar, [(0, 2.9, TRIO_D_COUNTER[k - 1], 64)])
    if k in (4, 8):
        P.put("sparkles", bar, [(2, .33, "E6", 54), (2.33, .33, "D6", 54), (2.67, .33, "B5", 54)])
trio(t_c3, TRIO_C2, TRIO_TUNE_C2, DESCANT_C2)
# the link back: the bass climbs, the sparkles point the way
P.put("bass", link, [(0, .9, "A2", 74), (1, .9, "B2", 72), (2, .9, "C3", 74)])
P.put("bass", link + 1, [(0, 1.6, "D3", 80), (2, .9, "D2", 76)])
P.put("pahpah", link, [(1, .45, ["A3", "C4", "E4"], 50), (2, .45, ["A3", "C4", "E4"], 48)])
P.put("pahpah", link + 1, [(1, .45, ["F#3", "A3", "C4"], 54), (2, .45, ["F#3", "A3", "C4"], 54)])
P.put("melody", link + 1, [(1, .5, "C5", 76), (1.5, .5, "B4", 74), (2, 1, "A4", 78)])
P.put("sparkles", link + 1, [(0, .33, "D6", 58), (.33, .33, "C6", 58), (.67, .33, "A5", 58)])

# ---------------------------------------------------------------- MINUET DA CAPO
minuet(d_a, M.A_CH, A_VAR, None, {4: SP[(1, 4)], 8: SP[(1, 8)]})
minuet(d_b, M.B_CH, M.B, "echo", {2: SP[(3, 2)], 6: SP[(3, 6)], 8: SP[(3, 8)]})
minuet(d_a2, M.A_CH, M.A2, "sixths", {4: SP[(4, 4)]})

# ---------------------------------------------------------------- CODA
CODA_MEL = {1: [(0, 1, "D5"), (1, 1, "G5"), (2, 1, "B5")], 2: [(0, 1, "A5"), (1, 1, "G5"), (2, 1, "E5")],
            3: [(0, 2, "D5"), (2, 1, "B4")], 4: [(0, 1, "C5"), (1, 1, "A4"), (2, 1, "F#4")], 5: [(0, 3, "G4")]}
for k in range(1, 7):
    bar, sym = coda + k - 1, CODA[k - 1]
    root = root_of(sym)
    tones = sorted({n("G3") + ((pc - n("G3")) % 12) for pc in M.pcs_of(sym)})[:3]
    if k <= 4:
        P.put("bass", bar, [(0, 1.6, root, 80), (2, .9, root + 7 if root + 7 <= n("D3") + 2 else root - 5, 70)])
        P.put("pahpah", bar, [(1, .45, tones, 54), (2, .45, tones, 50)])
    for b, d, nm in CODA_MEL.get(k, []):
        P.put("melody", bar, [(b, d * .95, nm, 82)])
        c = M.below(n(nm), sym, n("D4"), n("D5"))
        if c: P.put("counter", bar, [(b, d * .95, c, 64)])
P.put("bass", coda + 4, [(0, 2.8, "G2", 80)])
P.put("pahpah", coda + 4, [(0, 2.8, ["G3", "B3", "D4"], 52)])
P.put("sparkles", coda + 3, [(0, .25, "D6", 60), (.25, .25, "C6", 60), (.5, .25, "D6", 60), (.75, .25, "C6", 60), (1, 1, "B5", 62)])
P.put("sparkles", coda + 4, [(1, .33, "G5", 58), (1.33, .33, "B5", 60), (1.67, .33, "D6", 62), (2, 1, "G6", 64)])
for pid, ps, v in [("bass", ["G2"], 86), ("pahpah", ["G3", "B3", "D4"], 66), ("melody", ["G5"], 86), ("counter", ["B4"], 70), ("sparkles", ["G6"], 66)]:
    P.put(pid, coda + 5, [(0, 2.4, ps, v)])

tpl = P.template(
    {"id": "minuet", "title": "Minuet and Trio", "genre": "classical", "style": "Minuet and trio (a courtly dance)",
     "source": "New for the Music Lab (Claudette), Oct 25 2026; developed into a minuet and trio the same day",
     "bpm": 120, "key": "G (trio in C)", "feel": "straight; three to a bar, light"},
    [("bass", "Bass", "bass", 1, None, "The downbeat and the fifth; long notes in the trio; a climb in the link."),
     ("pahpah", "Pah-pah chords", "comp", 3, "staccato", "Two light chords on beats 2 and 3 -- rippling broken chords in the trio."),
     ("melody", "Melody", "melody", 1, "legato", "The minuet's tune (plain, then dressed up); a high descant in the trio; the trio's minor phrase."),
     ("counter", "Countermelody", "harmony", 1, "legato", "Echoes and sixths in the minuet -- the trio's tune."),
     ("sparkles", "Sparkles", "answer", 1, None, "Little high arpeggios at the cadences; a trill and the last high G.")],
    [("bass", "Bass"), ("pahpah", "Pah-pah chords"), ("melody", "Melody"), ("counter", "Countermelody"), ("sparkles", "Sparkles")])
write(tpl)
