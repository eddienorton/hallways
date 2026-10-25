"""NIGHT PORTER -- the full piece (Oct 25 2026). Soul-jazz blues, G, 100 bpm, 4/4. ~2 min 50 s, 70 bars.

Grown from the Hallways Original (lab/genres/soul.py): its head, riff, chops, horn answers, guitar and organ
solos and shout are all here, now inside a whole performance with new material between them.

  Intro       4   drums alone, a fill; the bass riff and chops come in under an organ swell
  Head       12   the tune, the horns' three-note answers
  Solo       12   the ANSWERS layer takes a solo (the old guitar and organ solos, then a new turnaround);
                  the melody rests; held chords comp underneath; the horns' backing on the last four bars
  Breakdown  12   quiet: two-feel bass, hats and rim; the tune whispered in long notes; the LOW HARMONY layer
                  sings a slow countermelody; it builds back up from bar 9 with a big fill
  Trading    12   MELODY and HARMONY trade two-bar phrases (call and response); drum fills every four bars
  Shout      12   everyone: the horns' shout chorus in three-part harmony over the riff
  Head out    4   the tune's last line
  Ending      2   a held G7(#9) with a drum roll -- and a final button

Layers (unchanged): Bass line, Groove, Chords, Held chords, Melody, Answers, Harmony, Low harmony.
"""
import sys
sys.path.insert(0, "/home/claude/band/templates")
from tplkit import Piece, Collector, write, n
import soul as S
from labkit import voicing, harm_below

BL = S.BLUES
P = Piece(4)
intro = P.section("Intro", 4, ["G7", "G7", "G7", "G7"])
head = P.section("Head", 12, BL)
solo = P.section("Solo", 12, BL)
brk = P.section("Breakdown", 12, BL)
trade = P.section("Trading", 12, BL)
shout = P.section("Shout", 12, BL)
hout = P.section("Head out", 4, ["D7", "C7", "G7", "D7"])
end = P.section("Ending", 2, ["G7", "G7"])

KIT = {36: "kick", 38: "snare", 42: "hat", 46: "openhat", 49: "crash", 50: "tomhi", 45: "tomlo"}


def collect(fn, *a, **k):
    c = Collector("x", 5)
    fn(c, *a, **k)
    return c.notes


def take(pid, notes):
    P.notes.setdefault(pid, []).extend(notes)


def drums(bar0, nbars, **kw):
    for b, d, m, v in collect(S.drums, bar0 + 1, nbars, **kw):
        piece = KIT[m]
        if piece == "snare" and v < 50: piece = "ghost"
        P.hits.setdefault("drums", []).append((b, piece, v))


def chords_at(bar0, nbars):
    return [P.chord(bar0 + i) for i in range(nbars)]


# ---------------------------------------------------------------- INTRO (0-3)
drums(intro, 2, fills=(2,))
drums(intro + 2, 2, vel=.9, fills=(2,))
take("bass", collect(S.bass, intro + 3, ["G7", "G7"]))
take("comp", collect(S.chops, intro + 3, ["G7", "G7"], vel=62))
P.put("organ", intro + 2, [(0, 7.5, [n(m) for m in ["F3", "B3", "D4", "A4"]], 54)])

# ---------------------------------------------------------------- HEAD (4-15)
take("melody", collect(S.line, head + 1, S.HEAD, vel=96, bpb=4, bpm=S.BPM, swell=False, legato=.9))
horns = {"trumpet": Collector("t", 1), "sax": Collector("s", 2), "trombone": Collector("b", 3)}
S.horn_hits(horns, head + 1, BL, S.ANSWERS)
take("answer1", horns["trumpet"].notes); take("answer2", horns["sax"].notes); take("answer3", horns["trombone"].notes)
take("comp", collect(S.chops, head + 1, BL))
take("bass", collect(S.bass, head + 1, BL))
drums(head, 12, fills=(12,), crash=(1,))
for i, sym in enumerate(BL[8:]):                                  # held chords lift the last line
    P.put("organ", head + 8 + i, [(0, 3.8, voicing(sym, 0, lo=n("B3"), hi=n("F4"))[:3], 50)])

# ---------------------------------------------------------------- SOLO (16-27): the Answers layer's spotlight
take("answer1", collect(S.line, solo + 1, S.GUITAR_SOLO, vel=90, bpb=4, bpm=S.BPM, swell=False, legato=.92))
take("answer1", collect(S.line, solo + 1, S.ORGAN_SOLO, vel=92, bpb=4, bpm=S.BPM, swell=False, legato=.92))
P.line("answer1", solo + 8, {
    0: [(0, .25, "F#5"), (.25, .25, "G5"), (.5, .5, "A5"), (1, .5, "C6"), (1.5, .5, "A5"), (2, 1, "F#5"), (3, 1, "D5")],
    1: [(0, .5, "E5"), (.5, .5, "G5"), (1, .5, "Bb5"), (1.5, 1.5, "G5"), (3, .5, "E5"), (3.5, .5, "C5")],
    2: [(0, .33, "D5"), (.33, .33, "F5"), (.67, .33, "G5"), (1, 1, "Bb5"), (2, .5, "B5"), (2.5, 1.5, "G5")],
    3: [(0, .5, "F5"), (.5, .5, "D5"), (1, 1, "C5"), (2, 1, "A4"), (3, .5, "F#4")]}, vel=90)
for i, (a, b) in enumerate([("C5", "F#4"), ("Bb4", "E4"), ("B4", "F4"), ("C5", "F#4")]):     # horn backing, last line
    P.put("answer2", solo + 8 + i, [(0, 3.7, a, 62)]); P.put("answer3", solo + 8 + i, [(0, 3.7, b, 60)])
take("organ", collect(S.organ_comp, solo + 1, BL, vel=56))
take("comp", collect(S.chops, solo + 1, BL, vel=60, skip=(1, 2, 3, 4)))
# the bass walks under the first four bars (a change from the riff), then the riff
walk = {0: ["G2", "B2", "D3", "F3"], 1: ["G3", "F3", "D3", "B2"], 2: ["G2", "A2", "Bb2", "B2"], 3: ["D3", "C3", "B2", "A2"]}
for k, ns in walk.items():
    P.put("bass", solo + k, [(i, .85, m, 86 + (6 if i == 0 else 0)) for i, m in enumerate(ns)])
take("bass", collect(S.bass, solo + 5, BL[4:]))
drums(solo, 12, fills=(4, 8, 12), crash=(1,))

# ---------------------------------------------------------------- BREAKDOWN (28-39): quiet, then building
P.line("melody", brk, {
    0: [(.5, .5, "D5"), (1, 1.5, "F5"), (2.5, 1.5, "G5")],
    1: [(0, 3, "G5")],
    2: [(.5, .5, "D5"), (1, 1.5, "F5"), (2.5, 1.5, "Bb5")],
    3: [(0, 2, "A5"), (2, 2, "G5")],
    4: [(.5, .5, "G4"), (1, 1.5, "Bb4"), (2.5, 1.5, "C5")],
    5: [(0, 3, "E5")],
    6: [(0, 1, "D5"), (1, 1, "B4"), (2, 2, "G4")],
    8: [(0, 1, "A4"), (1, 1, "C5"), (2, 2, "F#5")],
    9: [(0, 1, "G5"), (1, 1, "E5"), (2, 2, "C5")],
    10: [(0, 3.5, "D5")],
    11: [(3, .5, "D5"), (3.5, .5, "F5")]}, vel=72)
P.line("answer1", brk, {6: [(3, .5, "F5")], 7: [(0, 1, "D5"), (1, 1, "B4"), (2, 2, "G4")], 11: [(0, 1, "C5"), (1, 1, "A4")]}, vel=64)
P.line("answer3", brk, {0: [(0, 3.8, "B3")], 1: [(0, 1.8, "C4"), (2, 1.8, "D4")], 2: [(0, 3.8, "F4")], 3: [(0, 1.8, "E4"), (2, 1.8, "D4")],
                        4: [(0, 3.8, "E4")], 5: [(0, 1.8, "Bb3"), (2, 1.8, "G3")], 6: [(0, 3.8, "B3")], 7: [(0, 1.8, "D4"), (2, 1.8, "F4")]}, vel=66)
for i in range(12):
    sym = P.chord(brk + i)
    P.put("organ", brk + i, [(0, 3.85, voicing(sym, 0, lo=n("B3"), hi=n("F4"))[:3], 40 if i < 8 else 50)])
    if 4 <= i < 8:
        P.put("comp", brk + i, [(3.5, .2, voicing(sym.replace("7", "9"), 0, lo=n("D4"), hi=n("B4"))[:3], 52)])
    if i < 8:                                             # two-feel bass: the root, then the fifth
        r = n(S.ROOTS[sym])
        P.put("bass", brk + i, [(0, 1.8, r, 84), (2, 1.8, r + 7, 76)])
        P.hit("drums", brk + i, 0, "kick", 70)
        for k in range(8):
            P.hit("drums", brk + i, k * .5, "hat", 46 if k % 2 else 58)
        for b in (1, 3):
            P.hit("drums", brk + i, b, "rim", 64)
take("bass", collect(S.bass, brk + 9, BL[8:], vel=88))
take("comp", collect(S.chops, brk + 9, BL[8:], vel=62))
drums(brk + 8, 4, vel=.85, fills=(4,), crash=(1,))
for k, (t, pc) in enumerate([(0, "snare"), (.5, "snare"), (1, "tomhi"), (1.5, "tomhi"), (2, "tomlo"), (2.5, "tomlo")]):   # (the fill's run-up)
    P.hit("drums", brk + 11, t, pc, 60 + 4 * k)

# ---------------------------------------------------------------- TRADING (40-51): melody calls, harmony answers
P.line("melody", trade, {
    0: [(0, .25, "Bb5"), (.25, .75, "B5"), (1, .5, "D6"), (1.5, .5, "B5"), (2, 1, "G5"), (3, .5, "F5"), (3.5, .5, "D5")],
    1: [(0, 1, "F5"), (1, .5, "D5"), (1.5, 1.5, "G5")],
    4: [(0, .5, "E5"), (.5, .5, "G5"), (1, .5, "Bb5"), (1.5, .5, "G5"), (2, 1, "E5"), (3, 1, "C5")],
    5: [(0, .5, "Eb5"), (.5, .5, "E5"), (1, 2, "G5")],
    8: [(0, .5, "A5"), (.5, .5, "F#5"), (1, .5, "D5"), (1.5, .5, "C5"), (2, 2, "A4")],
    9: [(0, .5, "G4"), (.5, .5, "Bb4"), (1, 1, "C5"), (2, 1, "E5"), (3, 1, "G5")]}, vel=94)
P.line("answer2", trade, {
    2: [(0, .5, "G4"), (.5, .5, "Bb4"), (1, .5, "C5"), (1.5, .5, "C#5"), (2, 1, "D5"), (3, 1, "F5")],
    3: [(0, .5, "D5"), (.5, .5, "C5"), (1, 1, "Bb4"), (2, 2, "G4")],
    6: [(0, .5, "D5"), (.5, .5, "F5"), (1, 1, "G5"), (2, .5, "F5"), (2.5, .5, "D5"), (3, 1, "B4")],
    7: [(0, 3, "G4")],
    10: [(0, .5, "B4"), (.5, .5, "D5"), (1, .5, "F5"), (1.5, .5, "D5"), (2, 2, "G4")],
    11: [(2, .5, "F#4"), (2.5, .5, "A4"), (3, 1, "C5")]}, vel=90)
take("comp", collect(S.chops, trade + 1, BL, vel=66))
take("bass", collect(S.bass, trade + 1, BL))
for i in range(8, 12):
    P.put("organ", trade + i, [(0, 3.8, voicing(P.chord(trade + i), 0, lo=n("B3"), hi=n("F4"))[:3], 46)])
drums(trade, 12, fills=(4, 8, 12), crash=(1,))

# ---------------------------------------------------------------- SHOUT (52-63): three-part horns
SHOUT8 = {
    0: [(0, .5, "B5"), (.75, .25, "B5"), (1, .75, "D6"), (2.5, 1.5, "B5")],
    1: [(0, .5, "Bb5"), (.5, .5, "B5"), (1, 1, "G5"), (2.5, .5, "F5"), (3, 1, "G5")],
    2: [(0, .5, "B5"), (.75, .25, "B5"), (1, .75, "D6"), (2.5, 1.5, "D6")],
    3: [(0, 1, "F5"), (1, .5, "D5"), (1.5, .5, "F5"), (2, 2, "G5")],
    4: [(0, .5, "E5"), (.75, .25, "E5"), (1, .75, "G5"), (2.5, 1.5, "Bb5")],
    5: [(0, .5, "A5"), (.5, .5, "G5"), (1, 1, "E5"), (2.5, .5, "C5"), (3, 1, "E5")],
    6: [(0, .5, "D5"), (.75, .25, "F5"), (1, .75, "G5"), (2, .5, "B5"), (2.5, 1.5, "D6")],
    7: [(0, 1, "D6"), (1, .5, "B5"), (1.5, .5, "G5"), (2, 2, "F5")]}
shout_all = dict(SHOUT8)
shout_all.update({k - 1: v for k, v in S.SHOUT.items()})
for k, notes in shout_all.items():
    sym = BL[k]
    for beat, dur, name in notes:
        top = n(name)
        h1, h2 = harm_below(top, sym, 0, count=2)
        P.put("melody", shout + k, [(beat, dur * .92, top, 98)])
        P.put("answer1", shout + k, [(beat, dur * .92, h1, 88)])
        P.put("answer2", shout + k, [(beat, dur * .92, h2, 86)])
        if dur >= 1:                                         # the low horn on the long notes: the chord's root
            r = n(S.ROOTS[sym]) + 24
            P.put("answer3", shout + k, [(beat, dur * .92, r if r <= n("D4") else r - 12, 84)])
take("comp", collect(S.chops, shout + 1, BL, vel=72))
take("organ", collect(S.organ_comp, shout + 1, BL, vel=58))
take("bass", collect(S.bass, shout + 1, BL, vel=96))
drums(shout, 12, fills=(4, 8, 12), crash=(1, 5, 9))

# ---------------------------------------------------------------- HEAD OUT (64-67) and ENDING (68-69)
take("melody", collect(S.line, hout + 1, {k - 8: v for k, v in S.HEAD.items() if 9 <= k <= 11}, vel=96, bpb=4, bpm=S.BPM, swell=False, legato=.9))
P.put("melody", hout + 3, [(2, .5, "F#5", 90), (2.5, .5, "A5", 94), (3, .5, "C6", 98)])
S.horn_hits(horns := {"trumpet": Collector("t", 1), "sax": Collector("s", 2), "trombone": Collector("b", 3)}, hout + 1, ["D7", "C7", "G7", "D7"], {4: [(2, .4), (2.5, .4)]})
take("answer1", horns["trumpet"].notes); take("answer2", horns["sax"].notes); take("answer3", horns["trombone"].notes)
take("comp", collect(S.chops, hout + 1, ["D7", "C7", "G7", "D7"]))
take("bass", collect(S.bass, hout + 1, ["D7", "C7", "G7", "D7"]))
drums(hout, 4, fills=(4,), crash=(1,))
# the ending: a held G7(#9) with a drum roll, then the button
E = end * 4
for pid, ps, v in [("melody", ["G5"], 100), ("answer1", ["Bb5"], 96), ("answer2", ["F5"], 94), ("answer3", ["B3"], 92),
                   ("organ", ["G3", "F4", "B4", "D5"], 92), ("comp", ["F4", "B4", "Bb4"], 84), ("bass", ["G1"], 100)]:
    P.put(pid, end, [(0, 3.6, ps, v)])
    P.put(pid, end + 1, [(0, .45, ps, v + 6)])
P.hit("drums", end, 0, "crash", 110); P.hit("drums", end, 0, "kick", 110)
for k in range(12):
    P.hit("drums", end, 1 + k * .25, "tomlo" if k < 6 else "tomhi", 50 + 4 * k)
P.hit("drums", end + 1, 0, "crash", 118); P.hit("drums", end + 1, 0, "kick", 118); P.hit("drums", end + 1, 0, "snare", 110)

# ---------------------------------------------------------------- write
tpl = P.template(
    {"id": "night-porter", "title": "Night Porter", "genre": "blues", "style": "Soul-jazz blues (boogaloo)",
     "source": "Hallways Originals #3 (lab/genres/soul.py), developed into a full piece Oct 25 2026",
     "bpm": 100, "key": "G", "feel": "straight sixteenths", "sung": False},
    [("bass", "Bass line", "bass", 1, None, "The boogaloo riff; a walk in the solo, a two-feel in the breakdown."),
     ("drums", "Groove", "rhythm", 1, None, "The boogaloo groove; hats and rim in the breakdown; fills; a roll and a button to end."),
     ("comp", "Chords", "comp", 3, lambda d: "staccato" if d < .3 else "held", "Offbeat chops; quiet stabs in the breakdown."),
     ("organ", "Held chords", "pad", 3, None, "An organ swell, comping under the solo, soft chords through the breakdown."),
     ("melody", "Melody", "melody", 1, "legato", "The head; the whispered tune; calls in the trading chorus; the shout's top line."),
     ("answer1", "Answers", "answer", 1, None, "The horn answers -- and a whole solo chorus."),
     ("answer2", "Harmony", "harmony", 1, None, "Answers' middle voice; the replies in the trading chorus; the shout's harmony."),
     ("answer3", "Low harmony", "harmony", 1, None, "The lowest horn; a slow countermelody in the breakdown.")],
    [("bass", "Bass line"), ("drums", "Groove"), ("comp", "Chords"), ("organ", "Held chords"), ("melody", "Melody"),
     ("answer1", "Answers"), ("answer2", "Harmony"), ("answer3", "Low harmony")])
write(tpl)
