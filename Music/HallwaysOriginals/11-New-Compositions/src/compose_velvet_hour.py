"""THE VELVET HOUR -- a new Hallways composition (Claudette, Oct 25 2026). Bossa nova, F major, 128 bpm, 4/4.
~2 min 49 s, 90 bars. Warm, sophisticated, unhurried: long-breathed phrases that rise to a held note and sigh
back; the bittersweet minor-iv (B-flat minor 6) in the first part; a bridge that wanders to E-flat and A-flat
before finding its way home.

  Intro          4   guitar and shaker, the bass coming in; the strings' first chord
  A             16   the tune
  B             16   the bridge: higher, warmer; the strings come in under it
  A'            16   the tune, the COUNTERMELODY answering its long notes from below
  Solo           8   the MELODY improvises over the first half of A, lightly
  Interlude      8   the COUNTERMELODY's moment: a low, singing solo over Dm7-G7 / Gm7-C7; the others hush
  A''           16   the tune once more, with everyone -- strings, countermelody, percussion a little fuller
  Coda           6   a cadence that slips to D-flat and G-flat before landing, softly, on F

Layers: Bass, Bossa guitar, Percussion, Melody, Countermelody, Strings.
"""
import sys
sys.path.insert(0, "/home/claude/band/templates")
from tplkit import Piece, write, n
import music as M

A = ["Fmaj7", "Fmaj7", "Gm7", "C9", "Am7", "D7b9", "Gm7", "C7sus4", "Fmaj7", "F7", "Bbmaj7", "Bbm6", "Am7", "Abdim7", "Gm7", "C7"]
A_END = A[:15] + ["Fmaj7"]
BR = ["Dm7", "Dm7", "Bbmaj7", "Bbmaj7", "Gm7", "C7", "Fmaj7", "Fmaj7", "Ebmaj7", "Ebmaj7", "Abmaj7", "Abmaj7", "Gm7", "C7", "Fmaj7",
      [[0, "Gm7"], [2, "C7"]]]
INTER = ["Dm7", "G9", "Dm7", "G9", "Gm7", "C9", "Gm7", [[0, "Gm7"], [2, "C7"]]]
CODA = [[[0, "Gm7"], [2, "C7"]], "Fmaj7", "Dbmaj7", "Gbmaj7", "Fmaj7", "Fmaj7"]

P = Piece(4)
intro = P.section("Intro", 4, ["Fmaj7", "Fmaj7", "Gm7", "C9"])
a1 = P.section("A", 16, A)
b1 = P.section("B (bridge)", 16, BR)
a2 = P.section("A'", 16, A_END)
so = P.section("Solo (Melody)", 8, A[:8])
it = P.section("Interlude (Countermelody)", 8, INTER)
a3 = P.section("A'', everyone", 16, A_END)
co = P.section("Coda", 6, CODA)

TUNE_A = {0: [(.5, .5, "C5"), (1, .5, "E5"), (1.5, 2.5, "A5")], 1: [(0, 1, "G5"), (1, 1, "E5"), (2, 2, "C5")],
          2: [(.5, .5, "D5"), (1, .5, "F5"), (1.5, 2.5, "Bb5")], 3: [(0, 1, "A5"), (1, 1, "G5"), (2, 2, "D5")],
          4: [(.5, .5, "E5"), (1, .5, "G5"), (1.5, 1.5, "C6"), (3, 1, "B5")], 5: [(0, 1, "A5"), (1, .5, "F#5"), (1.5, .5, "Eb5"), (2, 2, "C5")],
          6: [(0, 1.5, "Bb4"), (1.5, .5, "D5"), (2, 2, "F5")], 7: [(0, 2, "F5"), (2, .5, "G5"), (2.5, .5, "F5"), (3, 1, "D5")],
          8: [(.5, .5, "C5"), (1, .5, "E5"), (1.5, 2.5, "A5")], 9: [(0, 1, "G5"), (1, 1, "Eb5"), (2, 2, "C5")],
          10: [(.5, .5, "D5"), (1, .5, "F5"), (1.5, 1.5, "A5"), (3, 1, "G5")], 11: [(0, 1.5, "F5"), (1.5, .5, "Db5"), (2, 2, "G5")],
          12: [(0, 2, "E5"), (2, .5, "G5"), (2.5, 1.5, "C5")], 13: [(0, 1, "B4"), (1, 1, "D5"), (2, 2, "F5")],
          14: [(0, 1, "Bb4"), (1, .5, "A4"), (1.5, .5, "G4"), (2, 2, "D5")], 15: [(0, 2.5, "E5")]}
TUNE_A_END = dict(TUNE_A)
TUNE_A_END.update({14: [(0, 1, "Bb4"), (1, .5, "D5"), (1.5, .5, "G5"), (2, 1, "F5"), (3, 1, "E5")], 15: [(0, 3.5, "F5")]})
TUNE_B = {0: [(0, 1.5, "A5"), (1.5, .5, "G5"), (2, 2, "F5")], 1: [(0, 1, "E5"), (1, 1, "D5"), (2, 2, "C5")],
          2: [(0, 1.5, "D5"), (1.5, .5, "F5"), (2, 2, "A5")], 3: [(0, 3, "G5")],
          4: [(0, 1.5, "F5"), (1.5, .5, "Bb5"), (2, 2, "D6")], 5: [(0, 1, "C6"), (1, 1, "Bb5"), (2, 2, "G5")],
          6: [(0, 2, "A5"), (2, 1, "G5"), (3, 1, "E5")], 7: [(0, 3, "F5")],
          8: [(0, 1.5, "G5"), (1.5, .5, "Bb5"), (2, 2, "D6")], 9: [(0, 1, "C6"), (1, 1, "Bb5"), (2, 2, "G5")],
          10: [(0, 1.5, "C6"), (1.5, .5, "Eb6"), (2, 2, "G5")], 11: [(0, 3, "Ab5")],
          12: [(0, 1, "Bb5"), (1, 1, "A5"), (2, 2, "F5")], 13: [(0, 1, "E5"), (1, 1, "G5"), (2, 2, "Bb5")],
          14: [(0, 2, "A5"), (2, 2, "C5")], 15: [(0, 2, "D5"), (2, 2, "E5")]}
# the countermelody answering the tune's long notes from below (A')
COUNTER = {0: [(2.5, .5, "F4"), (3, 1, "A4")], 2: [(2.5, .5, "G4"), (3, 1, "Bb4")], 4: [(3, 1, "E4")],
           6: [(2.5, 1.5, "D4")], 8: [(2.5, .5, "F4"), (3, 1, "A4")], 10: [(2.5, .5, "F4"), (3, .5, "A4"), (3.5, .5, "C5")],
           11: [(2.5, 1.5, "Bb4")], 13: [(2.5, 1.5, "Ab4")], 15: [(1, 1, "C4"), (2, 1, "E4"), (3, 1, "G4")]}


def line(pid, bar, bars, vel, **kw):
    for k, notes in bars.items():
        P.put(pid, bar + k, notes, vel=vel, **kw)


def rhythm(bar, nbars, gvel=56, bvel=80, perc=1.0, fuller=False, skip_guitar=()):
    # bass: root on one, fifth on three, an anticipation of the next root on the and-of-four
    for i in range(nbars):
        b = bar + i
        r = M.nearest(n("C3"), [M.info(P.chord(b))[2] % 12], n("E2"), n("D3"))
        f = M.nearest(r + 7, [(r + 7) % 12], n("E2"), n("D3") + 3)
        P.put("bass", b, [(0, 1.4, r, bvel), (2, 1.3, f, bvel - 8)])
    # guitar: the two-bar bossa cell
    M.comp(P, "guitar", bar, nbars, lambda k, rng: [(0, .9), (1.5, .9), (3, .9)] if k % 2 == 0 else [(1, .9), (2.5, 1.2)],
           lo=n("E3"), hi=n("D4") + 2, vel=gvel, seed=bar, skip=skip_guitar)
    # percussion: shaker eighths, rim clave (3-2), a soft low drum on one and three
    for i in range(nbars):
        b = bar + i
        for k in range(8):
            P.hit("perc", b, k * .5, "shaker", int((44 if k % 2 else 30) * perc))
        for t in ((0, 1.5, 3) if i % 2 == 0 else (1, 2.5)):
            P.hit("perc", b, t, "claves", int(50 * perc))
        P.hit("perc", b, 0, "tumba", int(54 * perc)); P.hit("perc", b, 2, "tumba", int(44 * perc))
        if fuller:
            P.hit("perc", b, 1.5, "conga", int(46 * perc)); P.hit("perc", b, 3.5, "quinto", int(40 * perc))


def strings(bar, chords_count, vel=46):
    for i in range(chords_count):
        b = bar + i
        for beat, sym in P.chords[b]:
            nxt = [x[0] for x in P.chords[b] if x[0] > beat]
            d = (nxt[0] if nxt else 4) - beat
            P.put("strings", b, [(beat + .05, d - .15, M.voicing(sym, n("A3"), n("F4") + 2, 3), vel)])


# ---------------------------------------------------------------- INTRO
M.comp(P, "guitar", intro, 4, lambda k, rng: [(0, .9), (1.5, .9), (3, .9)] if k % 2 == 0 else [(1, .9), (2.5, 1.2)],
       lo=n("E3"), hi=n("D4") + 2, vel=52, seed=1)
for i in range(4):
    for k in range(8): P.hit("perc", intro + i, k * .5, "shaker", 40 if k % 2 else 26)
for i in (2, 3):
    r = M.nearest(n("C3"), [M.info(P.chord(intro + i))[2] % 12], n("E2"), n("D3"))
    P.put("bass", intro + i, [(0, 1.4, r, 78), (2, 1.3, r + 7, 70)])
P.put("strings", intro + 3, [(0, 3.8, ["E4", "G4", "Bb4"], 40)])

# ---------------------------------------------------------------- A, B, A'
line("melody", a1, TUNE_A, 76, art="legato"); rhythm(a1, 16)
line("melody", b1, TUNE_B, 80, art="legato"); rhythm(b1, 16, gvel=54, perc=.9); strings(b1, 16, 44)
line("melody", a2, TUNE_A_END, 78, art="legato"); line("counter", a2, COUNTER, 66, art="legato"); rhythm(a2, 16)
strings(a2 + 8, 8, 38)

# ---------------------------------------------------------------- the melody's solo; the countermelody's interlude
M.improv(P, "melody", so, 8, seed=21, lo=n("C5"), hi=n("C6") + 2, vel=74, phrase=(5, 9), rest=(2, 4), start_rest=1,
         cells=[[(0, .5), (.5, .5)], [(0, 1)], [(0, 1.5)], [(.5, .5)], [(0, 2)], [(0, .5), (.5, 1)]])
rhythm(so, 8, gvel=54, fuller=True)
for i in range(8):                                                  # the strings hold under it
    P.put("strings", so + i, [(0, 3.8, M.voicing(P.chord(so + i), n("A3"), n("F4") + 2, 3), 34)])
M.improv(P, "counter", it, 8, seed=33, lo=n("F3"), hi=n("G4") + 2, vel=72, phrase=(6, 11), rest=(1, 3), start_rest=0,
         cells=[[(0, 1)], [(0, .5), (.5, .5)], [(0, 1.5)], [(0, 2)], [(.5, .5)]])
rhythm(it, 8, gvel=44, bvel=70, perc=.6, skip_guitar=(1, 3, 5, 7))
P.put("melody", it + 7, [(2, .5, "C5", 70), (2.5, .5, "E5", 72), (3, 1, "G5", 74)])     # a pickup back into the tune

# ---------------------------------------------------------------- A'', everyone
line("melody", a3, TUNE_A_END, 82, art="legato"); line("counter", a3, COUNTER, 70, art="legato")
rhythm(a3, 16, gvel=60, bvel=84, fuller=True); strings(a3, 16, 46)

# ---------------------------------------------------------------- CODA: home, by way of D-flat and G-flat
rhythm(co, 4, gvel=50, perc=.7)
line("melody", co, {0: [(0, 1, "D5"), (1, 1, "F5"), (2, 1, "Bb5"), (3, 1, "A5")], 1: [(0, 3, "A5")],
                    2: [(.5, .5, "Ab5"), (1, .5, "F5"), (1.5, 2.5, "C6")], 3: [(0, 1, "Bb5"), (1, 1, "F5"), (2, 2, "Db6")],
                    4: [(.5, .5, "C5"), (1, .5, "E5"), (1.5, 2.5, "A5")], 5: [(0, 3, "F5")]}, 74, art="legato")
line("counter", co, {2: [(0, 3.5, "F4")], 3: [(0, 3.5, "F4")], 4: [(0, 3.5, "E4")]}, 60)
strings(co, 5, 40)
for pid, ps, v in [("bass", ["F2"], 76), ("guitar", ["F3", "A3", "C4", "E4", "G4"], 52), ("strings", ["A3", "C4", "E4"], 42), ("counter", ["C4"], 58)]:
    P.put(pid, co + 5, [(0, 3.5, ps, v)])
P.hit("perc", co + 5, 0, "tumba", 50); P.hit("perc", co + 5, 1.5, "claves", 40)

for pid in ("melody", "counter"):
    M.drop_overlaps(P, pid)

tpl = P.template(
    {"id": "velvet-hour", "title": "The Velvet Hour", "genre": "jazz", "style": "Bossa nova",
     "source": "New for the Music Lab (Claudette), Oct 25 2026", "bpm": 128, "key": "F", "feel": "straight eighths, bossa syncopation"},
    [("bass", "Bass", "bass", 1, None, "Root on one, fifth on three: the bossa's slow heartbeat."),
     ("guitar", "Bossa guitar", "comp", 4, "held", "The two-bar bossa chords."),
     ("perc", "Percussion", "rhythm", 1, None, "Shaker, rim clave, a soft low drum; congas when it's fuller."),
     ("melody", "Melody", "melody", 1, "legato", "The long-breathed tune (A B A, A), a light solo, a coda."),
     ("counter", "Countermelody", "harmony", 1, "legato", "Low answers in the tune's long notes -- and the interlude's solo."),
     ("strings", "Strings", "pad", 3, None, "Held chords: under the bridge, the solo, the last A and the coda.")],
    [("bass", "Bass"), ("guitar", "Bossa guitar"), ("perc", "Percussion"), ("melody", "Melody"), ("counter", "Countermelody"),
     ("strings", "Strings")])
write(tpl)
