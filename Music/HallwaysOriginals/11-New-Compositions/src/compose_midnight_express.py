"""MIDNIGHT EXPRESS -- a new Hallways composition (Claudette, Oct 25 2026). Swing, B-flat, 168 bpm, 4/4,
swung eighths. ~2 min 28 s, 104 bars. Lively, playful, a little mischievous: a night train of a tune.

  Intro       4   the drums' train-chug on the snare, the bass on one note, the horns' two-note whistle
  Head       32   A A B A: the tune (a tumbling, chromatic little melody that keeps catching itself), the
                  woodwinds teasing it in its gaps; the bridge climbs through the cycle D7-G7-C7-F7
  Solo       16   the ANSWERS layer takes two A's; the brass (HARMONY) riffs behind the second
  Solo       16   the HARMONY layer over the bridge and an A; the woodwinds riff behind it
  Trading     8   the MELODY and the ANSWERS trade two-bar breaks; the band stops for them (stop-time)
  Shout       8   the whole band on a new, brassy line
  Head out   16   the bridge and the last A
  Ending      4   a train-whistle tag, a stop, the last chord

Layers: Walking bass, Drums, Piano (comping), Melody, Answers (woodwinds), Harmony (brass), Long notes.
"""
import sys
sys.path.insert(0, "/home/claude/band/templates")
from tplkit import Piece, write, n, sw
import music as M

A1 = [[[0, "Bb6"], [2, "G7"]], [[0, "Cm7"], [2, "F7"]], [[0, "Bb6"], [2, "G7"]], [[0, "Cm7"], [2, "F7"]],
      [[0, "Fm7"], [2, "Bb7"]], [[0, "Eb6"], [2, "Ab7"]], [[0, "Bb6"], [2, "G7"]], [[0, "Cm7"], [2, "F7"]]]
A2 = A1[:6] + [[[0, "Cm7"], [2, "F7"]], [[0, "Bb6"]]]
BR = [[[0, "D7"]], [[0, "D7"]], [[0, "G7"]], [[0, "G7"]], [[0, "C7"]], [[0, "C7"]], [[0, "F7"]], [[0, "F7"]]]

P = Piece(4)
intro = P.section("Intro", 4, [[[0, "Bb6"]], [[0, "Bb6"]], [[0, "Cm7"], [2, "F7"]], [[0, "Cm7"], [2, "F7"]]])
hA1 = P.section("A", 8, A1)
hA2 = P.section("A", 8, A2)
hB = P.section("Bridge", 8, BR)
hA3 = P.section("A", 8, A2)
s1 = P.section("Solo (Answers)", 16, A1 + A2)
s2 = P.section("Solo (Harmony)", 16, BR + A2)
trd = P.section("Trading", 8, A1)
sh = P.section("Shout", 8, A2)
oB = P.section("Bridge", 8, BR)
oA = P.section("Last A", 8, A1[:6] + [[[0, "Cm7"], [2, "F7"]], [[0, "Bb6"]]])
end = P.section("Ending", 4, [[[0, "Gb7"]], [[0, "F7"]], [[0, "Bb6"]], [[0, "Bb6"]]])


def S(notes):
    return [(sw(x[0]),) + tuple(x[1:]) for x in notes]


def line(pid, bar, bars, vel, **kw):
    for k, notes in bars.items():
        P.put(pid, bar + k, S(notes), vel=vel, **kw)


# ---------------------------------------------------------------- the tune
TUNE_A = {0: [(0, .5, "D5"), (.5, .5, "F5"), (1, 1, "G5"), (2.5, .5, "F5"), (3, 1, "D5")],
          1: [(0, .5, "Eb5"), (.5, .5, "G5"), (1, .5, "Bb5"), (1.5, .5, "A5"), (2, 1.5, "F5"), (3.5, .5, "Eb5")],
          2: [(0, .5, "D5"), (.5, .5, "F5"), (1, 1, "G5"), (2.5, .5, "B5"), (3, 1, "D6")],
          3: [(0, 1, "C6"), (1, .5, "Bb5"), (1.5, .5, "G5"), (2, 1, "A5"), (3, 1, "F5")],
          4: [(0, .5, "Ab5"), (.5, .5, "G5"), (1, .5, "F5"), (1.5, .5, "Ab5"), (2, 1, "D5"), (3, .5, "F5"), (3.5, .5, "Ab5")],
          5: [(0, 1.5, "G5"), (1.5, .5, "Eb5"), (2, 1, "C5"), (3, 1, "Eb5")],
          6: [(0, .5, "D5"), (.5, .5, "Bb4"), (1, .5, "D5"), (1.5, .5, "F5"), (2, 1, "B4"), (3, 1, "D5")],
          7: [(0, 1, "C5"), (1, .5, "Eb5"), (1.5, .5, "G5"), (2, 2, "A5")]}
TUNE_A_END = dict(TUNE_A)
TUNE_A_END.update({6: [(0, 1, "C6"), (1, .5, "A5"), (1.5, .5, "F5"), (2, 1, "Eb5"), (3, 1, "A4")], 7: [(0, 2.5, "Bb4")]})
TUNE_B = {0: [(0, .5, "F#5"), (.5, .5, "A5"), (1, 1, "C6"), (2.5, 1.5, "A5")],
          1: [(0, .5, "C6"), (.5, .5, "A5"), (1, .5, "F#5"), (1.5, .5, "D5"), (2, 2, "E5")],
          2: [(0, .5, "B4"), (.5, .5, "D5"), (1, 1, "F5"), (2.5, 1.5, "D5")],
          3: [(0, .5, "F5"), (.5, .5, "D5"), (1, .5, "B4"), (1.5, .5, "G4"), (2, 2, "A4")],
          4: [(0, .5, "E5"), (.5, .5, "G5"), (1, 1, "Bb5"), (2.5, 1.5, "G5")],
          5: [(0, .5, "Bb5"), (.5, .5, "G5"), (1, .5, "E5"), (1.5, .5, "C5"), (2, 2, "D5")],
          6: [(0, .5, "A4"), (.5, .5, "C5"), (1, 1, "Eb5"), (2.5, 1.5, "C5")],
          7: [(0, 1, "Eb5"), (1, 1, "D5"), (2, 1, "C5"), (3, 1, "A4")]}
# the woodwinds tease the tune in its gaps (beats 3-4 of its long notes)
TEASE = {1: [(3.5, .5, "C5")], 3: [(3, .33, "F4"), (3.33, .33, "A4"), (3.67, .33, "C5")], 5: [(3.5, .5, "Bb4")],
         7: [(2.5, .5, "C5"), (3, .5, "Eb5"), (3.5, .5, "F5")]}
TEASE_B = {1: [(2.5, .5, "F#4"), (3, .5, "A4"), (3.5, .5, "C5")], 3: [(2.5, .5, "B4"), (3, 1, "D5")],
           5: [(2.5, .5, "E4"), (3, .5, "G4"), (3.5, .5, "Bb4")], 7: [(3, .5, "F4"), (3.5, .5, "F#4")]}


def rhythm_section(bar, nbars, seed, comp_vel=60, drums_kw=None):
    M.walking_bass(P, "bass", bar, nbars, seed=seed)
    M.comp(P, "piano", bar, nbars, lambda k, rng: rng.choice([[(0, .3), (1.5, .9)], [(.5, .3), (2.5, .9)], [(1.5, .4), (3, .3)],
                                                              [(0, .3), (2.5, .4)], [(1, .3), (3.5, .5)]]),
           vel=comp_vel, swing_feel=True, seed=seed + 1)
    swing_drums(bar, nbars, **(drums_kw or {}))


def swing_drums(bar, nbars, fills=(), crash=(0,), light=False, stops=()):
    for i in range(nbars):
        b = bar + i
        if i in stops:
            P.hit("drums", b, 0, "crash", 96); P.hit("drums", b, 0, "kick", 96)
            continue
        for k in range(4):                                               # spang -- spang-a -- spang
            P.hit("drums", b, k, "ride", 70 if k % 2 else 60)
            if k % 2 == 1: P.hit("drums", b, sw(k + .5), "ride", 48)
            if k % 2 == 1: P.hit("drums", b, k, "hat", 58 if not light else 44)
            P.hit("drums", b, k, "kick", 34)                              # (feathered)
        if i in fills:
            for j, (t, pc) in enumerate([(2, "snare"), (sw(2.5), "snare"), (3, "tomhi"), (sw(3.5), "tomlo")]):
                P.hit("drums", b, t, pc, 74 + 6 * j)
        elif not light and (i % 2 == 1):
            P.hit("drums", b, sw(3.5), "ghost", 46)                      # (a comping snare)
        if i in crash: P.hit("drums", b, 0, "crash", 92)


# ---------------------------------------------------------------- INTRO: the train
for i in range(4):
    for k in range(8):
        P.hit("drums", intro + i, sw(k * .5), "snare" if k % 2 == 0 else "ghost", 60 + 6 * i if k % 2 == 0 else 38 + 4 * i)
    P.put("bass", intro + i, [(k, .9, "Bb2" if i < 2 else ("C3" if k < 2 else "F2"), 84) for k in range(4)])
line("harmony", intro, {1: [(2, 1.5, ["D5", "F5"])], 3: [(2, 1.5, ["Eb5", "A5"])]}, 92)   # the whistle
line("answers", intro, {3: [(3, .5, "F5"), (3.5, .5, "D5")]}, 70)

# ---------------------------------------------------------------- HEAD
for bar, tune, tease in [(hA1, TUNE_A, TEASE), (hA2, TUNE_A_END, TEASE), (hB, TUNE_B, TEASE_B), (hA3, TUNE_A_END, TEASE)]:
    line("melody", bar, tune, 92, art="legato")
    line("answers", bar, tease, 70)
    rhythm_section(bar, 8, seed=bar, drums_kw={"fills": (7,), "crash": (0,)})
for k in range(8):                                                       # long notes: the bridge's guide tones
    P.put("long", hB + k, [(0, 3.8, ["C5", "C5", "F4", "F4", "Bb4", "Bb4", "Eb5", "Eb5"][k], 60)])

# ---------------------------------------------------------------- SOLOS
M.improv(P, "answers", s1, 16, seed=7, lo=n("D4"), hi=n("F6"), vel=86, swing_feel=True, phrase=(6, 12), rest=(1, 3), start_rest=1)
rhythm_section(s1, 16, seed=31, drums_kw={"fills": (7, 15), "crash": (0, 8)})
for k, (a, b) in enumerate([("D4", "F4"), ("Eb4", "G4")] * 4):         # brass riff behind the second A
    P.put("harmony", s1 + 8 + k, S([(1.5, .4, [a, b], 72), (3, .9, [a, b], 74)]))
M.improv(P, "harmony", s2, 16, seed=11, lo=n("F3"), hi=n("C5"), vel=88, swing_feel=True, phrase=(5, 10), rest=(1, 3), start_rest=1)
rhythm_section(s2, 16, seed=47, drums_kw={"fills": (7, 15), "crash": (0, 8)})
for k in range(8, 16):                                                   # woodwind riff behind it
    P.put("answers", s2 + k, S([(0, .4, "D5", 66), (.5, .4, "F5", 62), (2.5, 1.2, "Bb5" if k % 2 == 0 else "A5", 64)]))
for k, nm in enumerate(["F4", "F4", "E4", "E4", "Eb4", "Eb4", "D4", "D4"]):
    P.put("long", s2 + k, [(0, 3.8, nm, 54)])

# ---------------------------------------------------------------- TRADING: stop-time, two-bar breaks
for i in range(8):
    b = trd + i
    sym = P.chord(b)
    P.put("bass", b, [(0, .45, M.nearest(n("Bb2"), [M.info(sym)[2] % 12], n("E2"), n("D3")), 92)])
    P.put("piano", b, [(0, .4, M.voicing(sym, n("A3"), n("G4") + 2), 74)])
    P.hit("drums", b, 0, "kick", 90); P.hit("drums", b, 0, "crash", 80)
    P.hit("drums", b, 2, "hat", 56)
M.improv(P, "melody", trd, 2, seed=3, lo=n("F4"), hi=n("Eb6"), swing_feel=True, phrase=(5, 7), rest=(3, 3), start_rest=1)
M.improv(P, "answers", trd + 2, 2, seed=5, lo=n("D4"), hi=n("D6"), swing_feel=True, phrase=(5, 7), rest=(3, 3), start_rest=1)
M.improv(P, "melody", trd + 4, 2, seed=9, lo=n("F4"), hi=n("Eb6"), swing_feel=True, phrase=(5, 7), rest=(3, 3), start_rest=1)
M.improv(P, "answers", trd + 6, 2, seed=13, lo=n("D4"), hi=n("D6"), swing_feel=True, phrase=(5, 7), rest=(3, 3), start_rest=1)

# ---------------------------------------------------------------- SHOUT: a new brassy line, three parts
SHOUT = {0: [(0, .5, "F5"), (.5, .5, "F5"), (1, 1, "D5"), (2.5, .5, "Bb4"), (3, 1, "D5")],
         1: [(0, .5, "Eb5"), (.5, .5, "Eb5"), (1, 1, "C5"), (2.5, .5, "A4"), (3, 1, "C5")],
         2: [(0, .5, "F5"), (.5, .5, "F5"), (1, .5, "D5"), (1.5, .5, "F5"), (2, 1, "G5"), (3, 1, "B5")],
         3: [(0, 1.5, "C6"), (2, .5, "Bb5"), (2.5, .5, "A5"), (3, 1, "F5")],
         4: [(0, .5, "Ab5"), (.5, .5, "Ab5"), (1, 1, "F5"), (2.5, .5, "D5"), (3, 1, "F5")],
         5: [(0, .5, "G5"), (.5, .5, "G5"), (1, 1, "Eb5"), (2.5, .5, "C5"), (3, 1, "Eb5")],
         6: [(0, 1, "D5"), (1, .5, "F5"), (1.5, .5, "A5"), (2, 2, "C6")],
         7: [(0, 3.5, "Bb5")]}
for k, notes in SHOUT.items():
    for beat, d, nm in notes:
        sym = P.chord(sh + k, beat)
        top = n(nm)
        h1 = M.nearest(top - 4, M.info(sym)[1], top - 9, top - 3)
        h2 = M.nearest(h1 - 4, M.info(sym)[1], h1 - 9, h1 - 3)
        P.put("melody", sh + k, S([(beat, d * .92, top, 98)]))
        P.put("answers", sh + k, S([(beat, d * .92, h1, 90)]))
        P.put("harmony", sh + k, S([(beat, d * .92, h2 - 12 if h2 > n("C5") else h2, 90)]))
rhythm_section(sh, 8, seed=59, comp_vel=70, drums_kw={"fills": (3, 7), "crash": (0, 4)})
for k, nm in enumerate(["D5", "Eb5", "D5", "Eb5", "F5", "G5", "F5", "F5"]):
    P.put("long", sh + k, [(0, 3.8, nm, 66)])

# ---------------------------------------------------------------- HEAD OUT, ENDING
line("melody", oB, TUNE_B, 92, art="legato"); line("answers", oB, TEASE_B, 70)
rhythm_section(oB, 8, seed=71, drums_kw={"fills": (7,), "crash": (0,)})
line("melody", oA, TUNE_A_END, 94, art="legato"); line("answers", oA, TEASE, 72)
rhythm_section(oA, 7, seed=83, drums_kw={"fills": (6,), "crash": (0,)})
P.put("bass", oA + 7, [(0, .9, "Bb2", 90), (1, .9, "D3", 84), (2, .9, "F3", 86), (3, .9, "Gb2", 88)])
P.put("piano", oA + 7, [(0, .4, ["D4", "F4", "G4", "Bb4"], 70)])
swing_drums(oA + 7, 1, fills=(0,))
# ending: Gb7 -> F7 (a slide down into home), the whistle again, a stop, the final chord
for k, (sym, top) in enumerate([("Gb7", ["Bb4", "E5"]), ("F7", ["A4", "Eb5"])]):
    P.put("melody", end + k, S([(0, .5, "Db6" if k == 0 else "C6", 96), (.5, 2.5, "Bb5" if k == 0 else "A5", 94)]))
    P.put("harmony", end + k, [(0, 3, top, 90)])
    P.put("answers", end + k, S([(3, .5, "E5" if k == 0 else "Eb5", 70), (3.5, .5, "Db5" if k == 0 else "C5", 70)]))
    P.put("piano", end + k, [(0, 3, M.voicing(sym, n("A3"), n("G4") + 2), 72)])
    P.put("bass", end + k, [(0, 3, "Gb2" if k == 0 else "F2", 92)])
    P.put("long", end + k, [(0, 3.8, "E4" if k == 0 else "Eb4", 66)])
    P.hit("drums", end + k, 0, "crash", 100); P.hit("drums", end + k, 0, "kick", 96)
    for j in range(6): P.hit("drums", end + k, 1 + j * .5, "ride", 56)
P.put("harmony", end + 2, [(1, 1.5, ["D5", "F5"], 88)])                          # the whistle, once more -- then
for pid, ps, v in [("melody", ["D6"], 100), ("answers", ["F5"], 92), ("harmony", ["Bb4", "D5"], 92), ("piano", ["D4", "F4", "G4", "C5"], 80),
                   ("bass", ["Bb1"], 100), ("long", ["A4"], 70)]:
    P.put(pid, end + 3, [(0, 3, ps, v)])
P.hit("drums", end + 3, 0, "crash", 116); P.hit("drums", end + 3, 0, "kick", 116)

for pid in ("melody", "answers"):
    M.drop_overlaps(P, pid)

tpl = P.template(
    {"id": "midnight-express", "title": "Midnight Express", "genre": "jazz", "style": "Swing",
     "source": "New for the Music Lab (Claudette), Oct 25 2026", "bpm": 168, "key": "B-flat", "feel": "swing (swung eighths, written on the triplet)"},
    [("bass", "Walking bass", "bass", 1, None, "Four to the bar, stepping chord to chord; one note under the train in the intro."),
     ("drums", "Drums", "rhythm", 1, None, "Ride-cymbal swing, hats on 2 and 4; the train on the snare; stop-time; fills."),
     ("piano", "Piano", "comp", 4, "staccato", "Comping: short chords off the beat, never the same twice."),
     ("melody", "Melody", "melody", 1, "legato", "The tune (A A B A), breaks in the trading, the shout's top line."),
     ("answers", "Answers", "answer", 2, None, "The woodwinds teasing the tune -- a solo chorus -- a riff behind the brass."),
     ("harmony", "Harmony", "harmony", 2, None, "The brass: the train whistle, a riff, a solo of its own, the shout's harmony."),
     ("long", "Long notes", "pad", 1, None, "Held guide tones under the bridge, the second solo and the shout.")],
    [("bass", "Walking bass"), ("drums", "Drums"), ("piano", "Piano"), ("melody", "Melody"), ("answers", "Answers"),
     ("harmony", "Harmony"), ("long", "Long notes")])
write(tpl)
