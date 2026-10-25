"""ROCK SHUFFLE -- the full song (Oct 25 2026). Rock / boogie shuffle, A, 132 bpm, 4/4, swung eighths.
~2 min 7 s, 70 bars. Grown from the Stage A shuffle: its boogie bass, stabs, hook and answers are all here.

  Intro riff     4   the signature riff on bass (and stabs), alone; drums come in, a fill
  Verse 1       12   a low, talky verse tune over the 12-bar; the answers punch in its rests
  Chorus         8   up to D7: the HOOK, louder, higher; driving octave bass; long notes swell underneath
  Verse 2       12   the verse again, different -- and climbing; the long notes add a slow counterline
  Chorus         8   the hook again, the long notes now high
  Break         12   stop-time: the band hits beat one, the ANSWERS layer solos in the gaps; then a full-band solo
                     chorus; the last two bars are the bass alone (the intro riff) with just the hats
  Last chorus    8   everyone
  Tag            4   the riff and the hook's first bars, traded
  Ending         2   the classic shuffle ending: a run down the blues scale in unison, a last A7(#9) and a crash

Layers (unchanged): Boogie bass, Drums, Chord stabs, Hook, Answers, Long notes.
"""
import sys
sys.path.insert(0, "/home/claude/band/templates")
from tplkit import Piece, write, n, sw

TWELVE = ["A7", "D7", "A7", "A7", "D7", "D7", "A7", "A7", "E7", "D7", "A7", "E7"]
CHORUS = ["D7", "D7", "A7", "A7", "D7", "D7", "E7", "E7"]
ROOT = {"A7": "A1", "D7": "D2", "E7": "E2"}
TONES = {"A7": ["C#4", "E4", "G4"], "D7": ["C4", "D4", "F#4"], "E7": ["D4", "E4", "G#4"]}

P = Piece(4)
intro = P.section("Intro riff", 4, ["A7"] * 4)
v1 = P.section("Verse 1", 12, TWELVE)
c1 = P.section("Chorus", 8, CHORUS)
v2 = P.section("Verse 2", 12, TWELVE)
c2 = P.section("Chorus", 8, CHORUS)
brk = P.section("Break", 12, TWELVE[:10] + ["A7", "E7"])
c3 = P.section("Last chorus", 8, CHORUS)
tag = P.section("Tag", 4, ["A7"] * 4)
end = P.section("Ending", 2, ["A7", "A7"])


def S(notes):
    """Swing the written eighths of [(beat, dur, pitch, vel?)]."""
    return [(sw(x[0]),) + tuple(x[1:]) for x in notes]


def line(pid, bar, bars, vel, **kw):
    for k, notes in bars.items():
        P.put(pid, bar + k, S(notes), vel=vel, **kw)


RIFF = {0: [(0, .5, "A2"), (.5, .5, "A2"), (1, .5, "C3"), (1.5, .5, "C#3"), (2, .5, "E3"), (2.5, .5, "F#3"), (3, .5, "G3"), (3.5, .5, "F#3")],
        1: [(0, .5, "E3"), (.5, .5, "C#3"), (1, 1, "A2"), (2, .5, "E2"), (2.5, .5, "G2"), (3, 1, "A2")]}


def riff(pid, bar, vel, shift=0):
    for k in (0, 1):
        P.put(pid, bar + k, S(RIFF[k]), vel=vel, shift=shift)


def boogie(bar, syms, vel=92, octaves=False):
    for i, sym in enumerate(syms):
        r = n(ROOT[sym])
        ivs = [0, 12, 0, 12, 0, 12, 0, 12] if octaves else ([0, 4, 7, 9, 10, 9, 7, 4] if i != len(syms) - 1 else [0, 4, 7, 9, 10, 9, 7, 6])
        P.put("bass", bar + i, [(sw(k * .5), .55 if k % 2 == 0 else .3, r + iv, vel if k % 2 == 0 else vel - 14) for k, iv in enumerate(ivs)])


def stabs(bar, syms, vel=72, chorus=False):
    for i, sym in enumerate(syms):
        hits = [(0, .9), (sw(1.5), .3), (3, .5)] if chorus else [(1, .3), (3, .3)]
        for beat, d in hits:
            P.put("stabs", bar + i, [(beat, d, TONES[sym], vel)])
        if not chorus and i % 4 == 3:
            P.put("stabs", bar + i, [(sw(3.5), .3, TONES[syms[(i + 1) % len(syms)]], vel - 6)])


def drums(bar, nbars, chorus=False, fills=(), crash=(0,), light=False):
    for i in range(nbars):
        fill = i in fills
        for k in range(8):
            if fill and k >= 4: continue
            pc = "openhat" if (chorus and k % 2 == 0) else "hat"
            P.hit("drums", bar + i, sw(k * .5), pc, (64 if k % 2 == 0 else 46) if not light else (50 if k % 2 == 0 else 36))
        for b in (0, 2):
            P.hit("drums", bar + i, b, "kick", 98 if chorus else 92)
        P.hit("drums", bar + i, sw(1.5), "kick", 70)
        P.hit("drums", bar + i, 1, "snare", 100 if not light else 80)
        if not fill: P.hit("drums", bar + i, 3, "snare", 104 if not light else 84)
        if i in crash: P.hit("drums", bar + i, 0, "crash", 108 if chorus else 100)
        if fill:
            for k, (t, pc) in enumerate([(2, "snare"), (2 + 1/3, "snare"), (2 + 2/3, "tomhi"), (3, "tomhi"), (3 + 1/3, "tomlo"), (3 + 2/3, "tomlo")]):
                P.hit("drums", bar + i, t, pc, 70 + 6 * k)


# ---------------------------------------------------------------- INTRO RIFF
riff("bass", intro, 96); riff("bass", intro + 2, 96)
riff("stabs", intro, 78, shift=12); riff("stabs", intro + 2, 80, shift=12)
for k in range(8):
    P.hit("drums", intro + 1, sw(k * .5), "hat", 60 if k % 2 == 0 else 42)
drums(intro + 2, 2, fills=(1,), crash=(0,))

# ---------------------------------------------------------------- VERSES
VERSE1 = {0: [(0, .5, "E4"), (.5, .5, "G4"), (1, 1, "A4"), (2.5, .5, "G4"), (3, 1, "E4")],
          1: [(0, .5, "F#4"), (.5, .5, "A4"), (1, .5, "C5"), (1.5, .5, "A4"), (2, 2, "F#4")],
          2: [(0, .5, "E4"), (.5, .5, "G4"), (1, .5, "A4"), (1.5, .5, "C5"), (2, 1, "C#5"), (3, 1, "A4")],
          4: [(0, .5, "A4"), (.5, .5, "C5"), (1, 1, "D5"), (2.5, .5, "C5"), (3, 1, "A4")],
          5: [(0, .5, "F#4"), (.5, .5, "G4"), (1, 2, "A4")],
          6: [(0, .5, "C#5"), (.5, .5, "E5"), (1, .5, "C#5"), (1.5, .5, "A4"), (2, 2, "G4")],
          8: [(0, .5, "B4"), (.5, .5, "B4"), (1, .5, "D5"), (1.5, .5, "E5"), (2, 1.5, "G#4")],
          9: [(0, .5, "A4"), (.5, .5, "A4"), (1, .5, "C5"), (1.5, .5, "D5"), (2, 1.5, "F#4")],
          10: [(0, 1, "E4"), (1, .5, "G4"), (1.5, .5, "A4"), (2, 2, "E4")],
          11: [(2, .5, "G#4"), (2.5, .5, "B4"), (3, 1, "D5")]}
VERSE2 = {0: [(.5, .5, "E4"), (1, .5, "G4"), (1.5, 1, "A4"), (2.5, .5, "C5"), (3, 1, "A4")],
          1: [(0, .5, "F#4"), (.5, .5, "A4"), (1, .5, "C5"), (1.5, .5, "D5"), (2, 2, "F#5")],
          2: [(0, .5, "E5"), (.5, .5, "C#5"), (1, .5, "A4"), (1.5, .5, "G4"), (2, 1, "A4"), (3, 1, "C5")],
          4: [(0, .5, "D5"), (.5, .5, "C5"), (1, 1, "A4"), (2.5, .5, "C5"), (3, 1, "D5")],
          5: [(0, .5, "F#5"), (.5, .5, "E5"), (1, 2, "D5")],
          6: [(0, .5, "C#5"), (.5, .5, "E5"), (1, .5, "G5"), (1.5, .5, "E5"), (2, 2, "A5")],
          8: [(0, .5, "B4"), (.5, .5, "D5"), (1, .5, "E5"), (1.5, .5, "G#5"), (2, 1.5, "B5")],
          9: [(0, .5, "A5"), (.5, .5, "F#5"), (1, .5, "D5"), (1.5, .5, "C5"), (2, 1.5, "A4")],
          10: [(0, 1, "C#5"), (1, .5, "E5"), (1.5, .5, "C#5"), (2, 2, "A4")],
          11: [(2, .5, "G#4"), (2.5, .5, "B4"), (3, 1, "D5")]}
line("hook", v1, VERSE1, 86, art="legato")
line("hook", v2, VERSE2, 90, art="legato")
line("answers", v1, {3: [(1, .25, ["E5", "C#5"]), (1.5, .25, ["E5", "C#5"]), (2, 1.5, ["G5", "E5"])],
                     7: [(0, .5, ["A5", "E5"]), (.5, .5, ["G5", "E5"]), (1, 1, ["E5", "C#5"]), (2, 1, ["C#5", "A4"])]}, 86)
line("answers", v2, {3: [(0, .5, ["C#5", "A4"]), (.5, .5, ["E5", "C#5"]), (1, 1.5, ["G5", "E5"])],
                     7: [(1, .25, ["A5", "E5"]), (1.5, .25, ["A5", "E5"]), (2, 1.5, ["G5", "C#5"])]}, 88)
for i, nm in enumerate(["G4", "F#4", "E4", "G4", "A4", "F#4", "E4", "G4", "G#4", "A4", "C#5", "B4"]):    # verse 2's counterline
    P.put("long", v2 + i, [(0, 3.85, nm, 62)])
for bar in (v1, v2):
    boogie(bar, TWELVE)
    stabs(bar, TWELVE)
    drums(bar, 12, fills=(11,), crash=(0,))

# ---------------------------------------------------------------- CHORUSES
CHORUS_HOOK = {0: [(0, .5, "D5"), (.5, .5, "F5"), (1, .5, "G5"), (1.5, .5, "Ab5"), (2, 1.5, "A5"), (3.5, .5, "C6")],
               1: [(0, 1, "D6"), (1, .5, "C6"), (1.5, .5, "A5"), (2, 2, "F#5")],
               2: [(0, .5, "A4"), (.5, .5, "C5"), (1, .5, "D5"), (1.5, .5, "Eb5"), (2, 1.5, "E5"), (3.5, .5, "G5")],
               3: [(0, 1, "A5"), (1, .5, "G5"), (1.5, .5, "E5"), (2, 2, "A4")],
               4: [(0, .5, "D5"), (.5, .5, "F5"), (1, .5, "G5"), (1.5, .5, "Ab5"), (2, 1.5, "A5"), (3.5, .5, "C6")],
               5: [(0, .5, "C6"), (.5, .5, "A5"), (1, 1, "F#5"), (2, 2, "D5")],
               6: [(0, .5, "B4"), (.5, .5, "D5"), (1, 1, "E5"), (2, 1, "G#5"), (3, 1, "B5")],
               7: [(0, 2, "B5"), (2.5, .5, "G#5"), (3, 1, "E5")]}
CHORUS_ANS = {1: [(3, .5, ["F#5", "D5"]), (3.5, .5, ["A5", "F#5"])], 3: [(3, .5, ["E5", "C#5"]), (3.5, .5, ["G5", "E5"])],
              5: [(3, .5, ["F#5", "D5"]), (3.5, .5, ["A5", "F#5"])], 7: [(2, .5, ["G#5", "E5"]), (2.5, .5, ["B5", "G#5"])]}
for bar, longs, hv in [(c1, ["C5", "C#5", "C5", "B4"], 96), (c2, ["F#5", "E5", "F#5", "G#5"], 100), (c3, ["F#5", "E5", "F#5", "G#5"], 104)]:
    line("hook", bar, CHORUS_HOOK, hv, art="legato")
    line("answers", bar, CHORUS_ANS, 90)
    for k, nm in enumerate(longs):
        P.put("long", bar + 2 * k, [(0, 7.8, nm, 70)])
    boogie(bar, CHORUS, vel=96, octaves=True)
    stabs(bar, CHORUS, vel=78, chorus=True)
    drums(bar, 8, chorus=True, fills=(7,), crash=(0, 4))

# ---------------------------------------------------------------- BREAK: stop-time, a solo, the bass alone
BS = TWELVE[:10] + ["A7", "E7"]
for i in range(4):                                               # stop-time: everyone hits beat one
    sym = BS[i]
    P.put("bass", brk + i, [(0, .5, n(ROOT[sym]) + 12, 100)])
    P.put("stabs", brk + i, [(0, .5, TONES[sym], 90)])
    P.hit("drums", brk + i, 0, "kick", 104); P.hit("drums", brk + i, 0, "crash", 96)
    for b in (1, 2, 3):
        P.hit("drums", brk + i, b, "hat", 40)
SOLO = {0: [(.5, .5, "E5"), (1, .5, "G5"), (1.5, .5, "A5"), (2, .5, "C6"), (2.5, .5, "A5"), (3, 1, "G5")],
        1: [(.5, .5, "F#5"), (1, .5, "A5"), (1.5, .5, "C6"), (2, 1.5, "D6"), (3.5, .5, "C6")],
        2: [(.5, .33, "A5"), (.83, .33, "G5"), (1.17, .33, "E5"), (1.5, .5, "Eb5"), (2, 1, "D5"), (3, 1, "C5")],
        3: [(.5, .5, "A4"), (1, .5, "C5"), (1.5, .5, "C#5"), (2, 2, "E5")],
        4: [(0, .5, "F#5"), (.5, .5, "A5"), (1, 1, "C6"), (2, .5, "A5"), (2.5, .5, "F#5"), (3, 1, "D5")],
        5: [(0, 1.5, "F5"), (1.5, .5, "F#5"), (2, 2, "A5")],
        6: [(0, .5, "E5"), (.5, .5, "G5"), (1, .5, "A5"), (1.5, .5, "C6"), (2, .5, "C#6"), (2.5, 1.5, "E6")],
        7: [(0, 1, "D6"), (1, .5, "C6"), (1.5, .5, "A5"), (2, 1, "G5"), (3, 1, "E5")],
        8: [(0, .5, "G#5"), (.5, .5, "B5"), (1, 1, "D6"), (2, 1, "B5"), (3, 1, "G#5")],
        9: [(0, .5, "A5"), (.5, .5, "F#5"), (1, .5, "D5"), (1.5, .5, "C5"), (2, 2, "A4")]}
line("answers", brk, SOLO, 94, art="legato")
boogie(brk + 4, BS[4:10])
stabs(brk + 4, BS[4:10])
drums(brk + 4, 6, crash=(0,))
riff("bass", brk + 10, 100)                                      # the bass alone, with the hats
for i in (10, 11):
    for k in range(8):
        P.hit("drums", brk + i, sw(k * .5), "hat", 56 if k % 2 == 0 else 38)
for k, (t, pc) in enumerate([(3, "snare"), (3 + 1/3, "snare"), (3 + 2/3, "tomlo")]):
    P.hit("drums", brk + 11, t, pc, 84 + 8 * k)

# ---------------------------------------------------------------- TAG and ENDING
riff("bass", tag, 96); riff("bass", tag + 2, 96)
line("hook", tag, {0: CHORUS_HOOK[2], 1: CHORUS_HOOK[3]}, 96, art="legato")
line("answers", tag, {2: [(0, .5, ["A5", "E5"]), (.5, .5, ["G5", "E5"]), (1, 1, ["E5", "C#5"]), (2, 1, ["C#5", "A4"])],
                      3: [(1, .25, ["E5", "C#5"]), (1.5, .25, ["E5", "C#5"]), (2, 1.5, ["G5", "E5"])]}, 92)
stabs(tag, ["A7"] * 4, vel=76)
P.put("long", tag, [(0, 15.6, "E5", 66)])
drums(tag, 4, fills=(3,), crash=(0,))
RUN = [(0, .5, "A5"), (.5, .5, "G5"), (1, .5, "E5"), (1.5, .5, "Eb5"), (2, .5, "D5"), (2.5, .5, "C5"), (3, 1, "A4")]
for pid, sh, v in [("hook", 0, 100), ("answers", 0, 92), ("stabs", -12, 88), ("bass", -36, 100), ("long", -12, 76)]:
    P.put(pid, end, S(RUN), vel=v, shift=sh)
for k in range(8):
    P.hit("drums", end, k * .5, "snare" if k < 6 else "tomlo", 70 + 5 * k)
LAST = {"hook": ["C6"], "answers": ["G5", "E5"], "stabs": ["C#4", "G4", "C5"], "bass": ["A1"], "long": ["A4"]}
for pid, ps in LAST.items():
    P.put(pid, end + 1, [(0, 3, ps, 104)])
P.hit("drums", end + 1, 0, "crash", 120); P.hit("drums", end + 1, 0, "kick", 120)

tpl = P.template(
    {"id": "rock-shuffle", "title": "Rock Shuffle", "genre": "rock", "style": "Rock shuffle (boogie)",
     "source": "New for the Music Lab (Claudette), Oct 25 2026; developed into a full song the same day",
     "bpm": 132, "key": "A", "feel": "shuffle (swung eighths, written on the triplet)"},
    [("bass", "Boogie bass", "bass", 1, None, "The intro riff; the boogie line in the verses; driving octaves in the choruses; alone in the break."),
     ("drums", "Drums", "rhythm", 1, None, "Shuffle; open hats in the choruses; stop-time hits; fills; the ending roll and crash."),
     ("stabs", "Chord stabs", "comp", 3, "staccato", "The riff an octave up in the intro; backbeat stabs; fuller chorus hits."),
     ("hook", "Hook", "melody", 1, "legato", "The talky verse tune (twice, differently) and the chorus hook."),
     ("answers", "Answers", "answer", 2, None, "Punches in thirds -- and the solo in the break."),
     ("long", "Long notes", "pad", 1, None, "Held notes under the choruses; a slow counterline in verse 2.")],
    [("bass", "Boogie bass"), ("drums", "Drums"), ("stabs", "Chord stabs"), ("hook", "Hook"), ("answers", "Answers"), ("long", "Long notes")])
write(tpl)
