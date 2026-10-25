"""CLOCKWORK -- a new Hallways composition (Claudette, Oct 25 2026). Funk, E (E7#9), 104 bpm, 4/4, straight
sixteenths. ~2 min 23 s, 62 bars. Quirky and mechanical: a tick-tock that never stops, a bass riff that turns
like a gear, chords chopped into sixteenths, and a tune that answers itself.

  Intro          4   the tick-tock and the hats alone; the bass riff engages
  Groove A       8   theme one: a two-bar call (MELODY), a two-bar reply (ANSWERS, in thirds)
  Groove B       8   up to A9: theme two sings longer notes; back to E for its second half
  Break          4   stop-time: everyone on the same gear-click rhythm; a drum fill
  Bridge         8   C9 / B7#9 / D9: the tune high and held, the long notes swelling
  Solo           8   the ANSWERS layer solos over the vamp, the tick-tock keeping time
  Bass break     2   the bass riff alone with the hats
  Trading        8   MELODY and BRASS HITS trade two-bar phrases
  Groove A out   8   theme one, everyone
  Ending         4   the clock winds down -- the tick-tock slows, the band hits fewer and fewer beats -- ding

Layers: Bass riff, Drums, Clav, Tick-tock, Melody, Answers, Brass hits, Long notes.
"""
import sys
sys.path.insert(0, "/home/claude/band/templates")
from tplkit import Piece, write, n
import music as M

P = Piece(4)
E, A9 = "E7#9", "A9"
intro = P.section("Intro", 4, [E] * 4)
ga = P.section("Groove A", 8, [E] * 8)
gb = P.section("Groove B", 8, [A9] * 4 + [E] * 4)
brk = P.section("Break", 4, [E] * 4)
br = P.section("Bridge", 8, ["C9", "C9", "B7#9", "B7#9", "C9", "C9", "D9", "D9"])
so = P.section("Solo (Answers)", 8, [E] * 8)
bb = P.section("Bass break", 2, [E] * 2)
tr = P.section("Trading", 8, [E] * 4 + [A9] * 2 + [E] * 2)
go = P.section("Groove A out", 8, [E] * 8)
end = P.section("Ending", 4, [E] * 4)

ROOTS = {"E7#9": "E2", "A9": "A2", "C9": "C2", "B7#9": "B1", "D9": "D2"}
RIFF = [(0, .4, 0, 96), (.75, .2, 0, 80), (1.5, .25, 3, 84), (1.75, .25, 4, 86), (2, .4, 5, 90), (2.75, .2, 7, 82), (3, .25, 10, 84),
        (3.5, .25, 7, 80), (3.75, .2, 0, 76)]
RIFF_TURN = RIFF[:6] + [(3, .25, 12, 88), (3.25, .25, 10, 84), (3.5, .25, 7, 82), (3.75, .25, 3, 80)]


def bass(bar, nbars, vel=0, turn_every=4):
    for i in range(nbars):
        b = bar + i
        root = n(ROOTS[P.chord(b)])
        pat = RIFF_TURN if (i % turn_every == turn_every - 1) else RIFF
        P.put("bass", b, [(t, d, root + iv + 12, v + vel) for t, d, iv, v in pat])


def drums(bar, nbars, fills=(), crash=(0,), light=False):
    for i in range(nbars):
        b = bar + i
        fill = i in fills
        for k in range(16):
            if fill and k >= 12: continue
            P.hit("drums", b, k * .25, "hat", (62 if k % 4 == 0 else 48 if k % 2 == 0 else 34) - (10 if light else 0))
        for t in (0, .75, 2.5):
            P.hit("drums", b, t, "kick", 96 if t == 0 else 84)
        P.hit("drums", b, 1, "snare", 100 if not light else 82)
        if not fill: P.hit("drums", b, 3, "snare", 104 if not light else 84)
        for t in (1.75, 2.25, 3.75):
            if not (fill and t > 3): P.hit("drums", b, t, "ghost", 36)
        if i in crash: P.hit("drums", b, 0, "crash", 98)
        if fill:
            for j, (t, pc) in enumerate([(3, "snare"), (3.25, "tomhi"), (3.5, "tomlo"), (3.75, "tomlo")]):
                P.hit("drums", b, t, pc, 80 + 6 * j)


def clav(bar, nbars, vel=62, skip=()):
    M.comp(P, "clav", bar, nbars, [(.25, .14), (.75, .14), (1.5, .2), (2.25, .14), (2.75, .14), (3.5, .2)],
           lo=n("G3"), hi=n("F4") + 2, vel=vel, count=3, seed=bar, skip=skip)


def ticktock(bar, nbars, vel=58, pitches=None):
    for i in range(nbars):
        b = bar + i
        hi, lo = pitches(b) if pitches else ("B5", "E5")
        for k in range(8):
            P.put("tick", b, [(k * .5, .14, hi if k % 2 == 0 else lo, vel + (8 if k == 0 else 0))])


def line(pid, bar, bars, vel, **kw):
    for k, notes in bars.items():
        P.put(pid, bar + k, notes, vel=vel, **kw)


def chord_tones(b):
    r, pcs, bass_, _ = M.info(P.chord(b))
    top = M.nearest(n("B5"), pcs, n("G5"), n("D6"))
    low = M.nearest(n("E5"), pcs, n("C5"), n("G5"))
    return top, low


THEME1 = {0: [(0, .25, "E4"), (.25, .25, "G4"), (.5, .5, "A4"), (1.5, .25, "Bb4"), (1.75, .25, "B4"), (2, 1, "D5"), (3.5, .5, "B4")],
          1: [(0, .5, "D5"), (.75, .25, "E5"), (1, 1, "G5"), (2.5, .5, "E5")],
          4: [(0, .25, "E5"), (.25, .25, "G5"), (.5, .5, "A5"), (1.5, .25, "Bb5"), (1.75, .25, "B5"), (2, 1.5, "D6")],
          5: [(0, .5, "B5"), (.5, .5, "A5"), (1, .5, "G5"), (1.5, .5, "E5"), (2, 2, "D5")],
          6: [(0, .25, "E5"), (.5, .25, "E5"), (1, .25, "E5"), (1.5, 1, "G5"), (3, .5, "E5")],
          7: [(0, .25, "D5"), (.5, .25, "D5"), (1, .25, "D5"), (1.5, 1, "B4")]}
REPLY = {2: [(.75, .25, ["D5", "B4"]), (1, .5, ["E5", "G4"]), (2.25, .25, ["D5", "B4"]), (2.5, 1, ["G5", "D5"])],
         3: [(0, .25, ["E5", "B4"]), (.5, .25, ["E5", "B4"]), (1.5, .5, ["D5", "A4"]), (2, 1.5, ["B4", "G4"])],
         6: [(2.75, .25, ["G4", "D4"]), (3.25, .5, ["B4", "G4"])], 7: [(2.75, .25, ["A4", "E4"]), (3.25, .5, ["B4", "G#4"])]}
THEME2 = {0: [(0, 1.5, "E5"), (1.5, .5, "F#5"), (2, 1, "G5"), (3, 1, "A5")], 1: [(0, 2, "B5"), (2.5, .5, "A5"), (3, 1, "G5")],
          2: [(0, .5, "E5"), (.5, .5, "C#5"), (1, 1, "E5"), (2, 2, "G5")], 3: [(0, 3, "F#5")],
          4: [(0, .25, "G5"), (.25, .25, "G#5"), (.5, .5, "B5"), (1, 1, "D6"), (2.5, 1.5, "B5")], 5: [(0, 1, "A5"), (1, 1, "G5"), (2, 2, "E5")],
          6: [(0, .5, "D5"), (.5, .5, "E5"), (1, .5, "G5"), (1.5, .5, "A5"), (2, 2, "B5")], 7: [(0, 2, "G5"), (2, 2, "E5")]}
BRIDGE = {0: [(0, 2, "E5"), (2, 2, "G5")], 1: [(0, 3, "Bb5")], 2: [(0, 2, "A5"), (2, 2, "D#5")], 3: [(0, 3, "F#5")],
          4: [(0, 1, "G5"), (1, 1, "Bb5"), (2, 2, "D6")], 5: [(0, 3, "C6")], 6: [(0, 1, "A5"), (1, 1, "F#5"), (2, 2, "E5")],
          7: [(0, 1, "D5"), (1, .5, "E5"), (1.5, .5, "F#5"), (2, 1, "A5"), (3, .5, "C6")]}
HITS = [(0, .2), (.75, .2), (2.5, .3), (3.25, .2)]                     # the brass's stab rhythm


def brass_hits(bar, nbars, vel=78, every=2):
    for i in range(nbars):
        if i % every != every - 1: continue
        b = bar + i
        P.put("brass", b, [(t, d, M.voicing(P.chord(b), n("D4"), n("C5") + 2, 3), vel) for t, d in HITS])


# ---------------------------------------------------------------- INTRO
ticktock(intro, 4, vel=54)
for i in range(2):
    for k in range(16): P.hit("drums", intro + i, k * .25, "hat", 50 if k % 4 == 0 else 30)
bass(intro + 2, 2)
drums(intro + 2, 2, fills=(1,), crash=(0,))

# ---------------------------------------------------------------- GROOVE A, GROOVE B
line("melody", ga, THEME1, 92); line("answers", ga, REPLY, 86)
bass(ga, 8); drums(ga, 8, fills=(7,)); clav(ga, 8); ticktock(ga, 8)
line("melody", gb, THEME2, 90, art="legato")
bass(gb, 8); drums(gb, 8, fills=(3, 7)); clav(gb, 8, vel=58); ticktock(gb, 8, pitches=chord_tones); brass_hits(gb, 8)
for k, nm in enumerate(["G4", "G4", "G4", "G4", "D5", "D5", "D5", "D5"]):
    P.put("long", gb + k, [(0, 3.85, nm, 56)])

# ---------------------------------------------------------------- BREAK: gear clicks, everyone
GEAR = [(0, .2), (.75, .2), (1.5, .2), (2.25, .2), (3, .4)]
for i in range(4):
    b = brk + i
    v = M.voicing(E, n("G3"), n("F4") + 2, 3)
    for t, d in (GEAR if i < 3 else GEAR[:3]):
        P.put("clav", b, [(t, d, v, 80)]); P.put("bass", b, [(t, d, "E3", 96)]); P.put("brass", b, [(t, d, M.voicing(E, n("D4"), n("C5") + 2, 3), 86)])
        P.put("melody", b, [(t, d, "B5" if i % 2 == 0 else "D6", 92)]); P.put("answers", b, [(t, d, ["G5", "E5"], 84)])
        P.put("tick", b, [(t, d, "E6", 70)])
        P.hit("drums", b, t, "kick", 96); P.hit("drums", b, t, "hat", 60)
    P.put("long", b, [(0, 3.85, "B4", 50)])
for j, (t, pc) in enumerate([(2, "snare"), (2.25, "snare"), (2.5, "tomhi"), (2.75, "tomhi"), (3, "tomlo"), (3.25, "tomlo"), (3.5, "snare"), (3.75, "snare")]):
    P.hit("drums", brk + 3, t, pc, 70 + 5 * j)

# ---------------------------------------------------------------- BRIDGE
line("melody", br, BRIDGE, 88, art="legato")
bass(br, 8, turn_every=2); drums(br, 8, fills=(7,), crash=(0, 4)); clav(br, 8, vel=56); ticktock(br, 8, vel=50, pitches=chord_tones)
for i in range(8):
    P.put("long", br + i, [(0, 3.85, M.voicing(P.chord(br + i), n("G4"), n("E5") + 2, 1), 60 + 2 * i)])
brass_hits(br, 8, vel=74)

# ---------------------------------------------------------------- SOLO (Answers), BASS BREAK
M.improv(P, "answers", so, 8, seed=41, lo=n("B4"), hi=n("E6"), vel=88, phrase=(5, 10), rest=(1, 3), start_rest=0,
         cells=[[(0, .25), (.25, .25), (.5, .5)], [(0, .5), (.5, .5)], [(0, .75), (.75, .25)], [(0, 1)], [(.5, .5)], [(0, 1.5)]])
bass(so, 8); drums(so, 8, fills=(3, 7)); clav(so, 8, vel=56, skip=(0, 2, 4, 6)); ticktock(so, 8, vel=50)
P.put("bass", bb, [(t, d, n("E2") + 12 + iv, v) for t, d, iv, v in RIFF])
P.put("bass", bb + 1, [(t, d, n("E2") + 12 + iv, v) for t, d, iv, v in RIFF_TURN])
for i in range(2):
    for k in range(16): P.hit("drums", bb + i, k * .25, "hat", 54 if k % 4 == 0 else 32)
for j, t in enumerate((3, 3.25, 3.5, 3.75)): P.hit("drums", bb + 1, t, "snare", 76 + 6 * j)

# ---------------------------------------------------------------- TRADING: melody and brass, two bars each
M.improv(P, "melody", tr, 2, seed=51, lo=n("D5"), hi=n("E6"), vel=90, phrase=(6, 7), rest=(2, 2), start_rest=0)
M.improv(P, "brass", tr + 2, 2, seed=53, lo=n("E4"), hi=n("E5") + 2, vel=88, phrase=(6, 7), rest=(2, 2), start_rest=0)
M.improv(P, "melody", tr + 4, 2, seed=57, lo=n("D5"), hi=n("E6"), vel=90, phrase=(6, 7), rest=(2, 2), start_rest=0)
M.improv(P, "brass", tr + 6, 2, seed=59, lo=n("E4"), hi=n("E5") + 2, vel=88, phrase=(6, 7), rest=(2, 2), start_rest=0)
bass(tr, 8); drums(tr, 8, fills=(1, 3, 5, 7)); clav(tr, 8, vel=58); ticktock(tr, 8, vel=48, pitches=chord_tones)

# ---------------------------------------------------------------- GROOVE A OUT, everyone
line("melody", go, THEME1, 96); line("answers", go, REPLY, 90)
bass(go, 8, vel=4); drums(go, 8, fills=(7,), crash=(0, 4)); clav(go, 8, vel=66); ticktock(go, 8, vel=60); brass_hits(go, 8, vel=82)
for k in range(8):
    P.put("long", go + k, [(0, 3.85, "D5" if k % 2 == 0 else "B4", 58)])

# ---------------------------------------------------------------- ENDING: the clock winds down
for i, (tick_step, hits) in enumerate([(.5, [0, .75, 1.5, 2.5, 3.25]), (1, [0, 1.5, 3]), (2, [0, 2]), (4, [0])]):
    b = end + i
    for k in range(int(4 / tick_step)):
        P.put("tick", b, [(k * tick_step, .14, "B5" if k % 2 == 0 else "E5", 60 - 4 * i)])
    for t in hits:
        P.put("clav", b, [(t, .2, M.voicing(E, n("G3"), n("F4") + 2, 3), 70 - 4 * i)])
        P.put("bass", b, [(t, .3, "E3", 92 - 4 * i)])
        P.put("brass", b, [(t, .25, M.voicing(E, n("D4"), n("C5") + 2, 3), 80 - 4 * i)])
        P.hit("drums", b, t, "kick", 90 - 5 * i); P.hit("drums", b, t, "snare" if t else "crash", 80 - 5 * i)
P.put("melody", end, [(0, .25, "E5", 90), (.25, .25, "G5", 90), (.5, .5, "A5", 90), (1.5, .25, "Bb5", 88), (1.75, .25, "B5", 88), (2, 1.5, "D6", 92)])
P.put("melody", end + 1, [(0, 1, "B5", 84), (1.5, 1, "G5", 78)])
P.put("answers", end + 2, [(0, 1.5, ["G5", "D5"], 76)])
P.put("melody", end + 3, [(0, 2.5, "E6", 86)])                               # ding
P.put("long", end + 3, [(0, 3, "B4", 50)])

for pid in ("melody",):
    M.drop_overlaps(P, pid)

tpl = P.template(
    {"id": "clockwork", "title": "Clockwork", "genre": "rock", "style": "Funk",
     "source": "New for the Music Lab (Claudette), Oct 25 2026", "bpm": 104, "key": "E (E7#9)", "feel": "straight sixteenths"},
    [("bass", "Bass riff", "bass", 1, None, "A sixteenth-note riff that turns like a gear; a turn every fourth bar; alone in the bass break."),
     ("drums", "Drums", "rhythm", 1, None, "Funk: sixteenth hats, ghost notes, kick on one, the a-of-one and the and-of-three; fills."),
     ("clav", "Clav", "comp", 3, "staccato", "Chords chopped into sixteenths."),
     ("tick", "Tick-tock", "answer", 1, "staccato", "The clock: eighth notes that never stop -- until the ending winds them down."),
     ("melody", "Melody", "melody", 1, None, "Theme one (a call), theme two (singing), the bridge, trading."),
     ("answers", "Answers", "answer", 2, None, "Theme one's reply in thirds -- and a solo."),
     ("brass", "Brass hits", "harmony", 3, "staccato", "Stabs every other bar; gear clicks in the break; a solo in the trading."),
     ("long", "Long notes", "pad", 1, None, "Held notes under theme two, the bridge (swelling) and the last groove.")],
    [("bass", "Bass riff"), ("drums", "Drums"), ("clav", "Clav"), ("tick", "Tick-tock"), ("melody", "Melody"), ("answers", "Answers"),
     ("brass", "Brass hits"), ("long", "Long notes")])
write(tpl)
