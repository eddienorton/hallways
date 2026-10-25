"""AFTER HOURS -- a new Hallways composition (Claudette, Oct 25 2026). Waltz, D minor, 132 bpm, 3/4.
~2 min 22 s, 104 bars. Dreamy, mysterious, theatrical: a music box turning in an empty ballroom, a long-lined
tune, and harmony that now and then steps somewhere it shouldn't (E-flat in D minor; D-flat and A-flat in F;
G-flat in B-flat), ending -- unexpectedly -- in D major.

  Intro          8   the music box alone; the bass and the strings come in under it
  A             16   the tune in D minor (its second phrase turns to E-flat, the Neapolitan, before coming home)
  B             16   F major, opening out -- to D-flat, B-flat minor, A-flat: chromatic steps sideways
  A'            16   the tune again, the countermelody answering it
  Interlude      8   B-flat and G-flat: the music box and strings, the tune in fragments
  Solo          16   the countermelody takes a chorus over A's chords
  A''           16   everyone, fuller
  Coda           8   G minor, B-flat minor, E-flat, A -- and D major, held

Layers: Bass, Waltz chords, Melody, Countermelody, Music box, Strings, Brushes.
"""
import sys
sys.path.insert(0, "/home/claude/band/templates")
from tplkit import Piece, write, n
import music as M

P = Piece(3)
A_CH = ["Dm", "Dm", "Bbmaj7", "Bbmaj7", "Gm6", "Gm6", "A7", "A7", "Dm", "Dm", "Fmaj7", "Fmaj7", "Ebmaj7", "A7b9", "Dm", "Dm"]
B_CH = ["Fmaj7", "Fmaj7", "Dbmaj7", "Dbmaj7", "Bbm6", "Bbm6", "C7", "C7", "Fmaj7", "Fmaj7", "Abmaj7", "Abmaj7", "Gm7", "C#dim7", "Em7b5", "A7"]
intro = P.section("Intro", 8, A_CH[:8])
a1 = P.section("A", 16, A_CH)
b1 = P.section("B", 16, B_CH)
a2 = P.section("A'", 16, A_CH)
il = P.section("Interlude", 8, ["Bbmaj7", "Bbmaj7", "Gbmaj7", "Gbmaj7", "Bbmaj7", "Bbmaj7", "Em7b5", "A7"])
so = P.section("Solo (Countermelody)", 16, A_CH)
a3 = P.section("A''", 16, A_CH)
coda = P.section("Coda", 8, ["Gm6", "Gm6", "Bbm6", "Bbm6", "Ebmaj7", "A7b9", "D", "D"])

THEME_A = {0: [(0, 2, "A4"), (2, 1, "D5")], 1: [(0, 2, "F5"), (2, 1, "E5")], 2: [(0, 3, "D5")], 3: [(0, 1, "A4"), (1, 1, "Bb4"), (2, 1, "D5")],
           4: [(0, 2, "E5"), (2, 1, "D5")], 5: [(0, 1.5, "Bb4"), (1.5, .5, "A4"), (2, 1, "G4")], 6: [(0, 2, "C#5"), (2, 1, "E5")],
           7: [(0, 2, "G5"), (2, 1, "E5")],
           8: [(0, 2, "F5"), (2, 1, "A5")], 9: [(0, 2, "D6"), (2, 1, "C6")], 10: [(0, 3, "A5")], 11: [(0, 1, "G5"), (1, 1, "F5"), (2, 1, "E5")],
           12: [(0, 2, "G5"), (2, 1, "Bb5")], 13: [(0, 1.5, "Bb5"), (1.5, .5, "A5"), (2, 1, "E5")], 14: [(0, 3, "D5")]}
THEME_B = {0: [(0, 2, "C5"), (2, 1, "F5")], 1: [(0, 3, "A5")], 2: [(0, 2, "Ab5"), (2, 1, "F5")], 3: [(0, 3, "C6")],
           4: [(0, 2, "Db6"), (2, 1, "Bb5")], 5: [(0, 1, "G5"), (1, 1, "F5"), (2, 1, "Db5")], 6: [(0, 2, "E5"), (2, 1, "G5")], 7: [(0, 3, "Bb5")],
           8: [(0, 2, "A5"), (2, 1, "C6")], 9: [(0, 2, "E6"), (2, 1, "C6")], 10: [(0, 2, "Eb6"), (2, 1, "C6")], 11: [(0, 3, "G5")],
           12: [(0, 1, "Bb5"), (1, 1, "A5"), (2, 1, "G5")], 13: [(0, 2, "E5"), (2, 1, "G5")], 14: [(0, 2, "Bb5"), (2, 1, "G5")],
           15: [(0, 2, "C#5"), (2, 1, "E5")]}
INTERLUDE = {0: [(0, 3, "D5")], 2: [(0, 3, "Bb5")], 3: [(1, 1, "Ab5"), (2, 1, "F5")], 4: [(0, 3, "A5")],
             6: [(0, 2, "G5"), (2, 1, "Bb5")], 7: [(0, 2, "A5"), (2, 1, "E5")]}
CODA = {0: [(0, 3, "Bb5")], 1: [(0, 2, "A5"), (2, 1, "G5")], 2: [(0, 3, "Db6")], 3: [(0, 2, "C6"), (2, 1, "Bb5")],
        4: [(0, 3, "G5")], 5: [(0, 1.5, "Bb5"), (1.5, 1.5, "A5")], 6: [(0, 3, "F#5")], 7: [(0, 2.9, "F#5")]}


def line(pid, bar, bars, vel, **kw):
    for k, notes in bars.items():
        P.put(pid, bar + k, notes, vel=vel, **kw)


def bass(bar, nbars, vel=84):
    for i in range(nbars):
        b = bar + i
        r, pcs, bs, _ = M.info(P.chord(b))
        root = M.nearest(n("D2") + 12, [bs % 12], n("E2"), n("D3") + 1)
        fifth = M.nearest(root + 7, [(bs + 7) % 12] if (bs + 7) % 12 in pcs else [bs % 12], root - 6, root + 8)
        P.put("bass", b, [(0, 1.6, root if i % 2 == 0 else fifth, vel)])


def oompah(bar, nbars, vel=58, last_short=False):
    for i in range(nbars):
        b = bar + i
        v = M.voicing(P.chord(b), n("A3"), n("G4") + 2, 3)
        P.put("chords", b, [(1, .5, v, vel), (2, .5, v, vel - 6)])


def musicbox(bar, nbars, vel=52, shape="up"):
    for i in range(nbars):
        b = bar + i
        r, pcs, bs, _ = M.info(P.chord(b))
        tones, p = [], n("D5")
        while len(tones) < 4:
            p = M.nearest(p + 1, pcs, p + 1, p + 7)
            tones.append(p)
        seq = tones + tones[2:0:-1] if (i % 2 == 0) == (shape == "up") else tones[::-1] + tones[1:3]
        P.put("box", b, [(k * .5, .45, q, vel + (6 if k == 0 else 0)) for k, q in enumerate(seq[:6])])


def strings(bar, nbars, vel=50, grow=0):
    for i in range(nbars):
        b = bar + i
        P.put("strings", b, [(0, 2.9, M.voicing(P.chord(b), n("D4"), n("C5") + 2, 3), vel + int(grow * i))])


def brushes(bar, nbars, vel=0):
    for i in range(nbars):
        b = bar + i
        P.hit("brush", b, 0, "tap", 58 + vel)
        P.hit("brush", b, 1, "shaker", 40 + vel)
        P.hit("brush", b, 2, "shaker", 44 + vel)
        if i % 4 == 3: P.hit("brush", b, 2.5, "shaker", 30 + vel)


def counter(bar, nbars, seed, vel=70, lo=n("F3") + 12, hi=n("D5") + 1, phrase=(4, 8), rest=(2, 4), start_rest=3):
    M.improv(P, "counter", bar, nbars, seed=seed, lo=lo, hi=hi, vel=vel, cells=M.RHYTHMS_WALTZ, phrase=phrase, rest=rest,
             start_rest=start_rest)


# ---------------------------------------------------------------- INTRO: the music box, then the band under it
musicbox(intro, 8, vel=50)
line("melody", intro, {4: [(0, 3, "D5")], 5: [(0, 2, "Bb4"), (2, 1, "G4")], 6: [(0, 3, "E5")], 7: [(0, 2, "C#5"), (2, 1, "A4")]}, 70, art="legato")
bass(intro + 4, 4, vel=76); strings(intro + 4, 4, vel=40, grow=3)
brushes(intro + 6, 2, vel=-10)

# ---------------------------------------------------------------- A, B
line("melody", a1, THEME_A, 86, art="legato")
bass(a1, 16); oompah(a1, 16); musicbox(a1, 16, vel=40); brushes(a1, 16)
strings(a1 + 8, 8, vel=46)
line("melody", b1, THEME_B, 90, art="legato")
bass(b1, 16, vel=86); oompah(b1, 16, vel=60); strings(b1, 16, vel=50, grow=.8); brushes(b1, 16, vel=4)
musicbox(b1 + 8, 8, vel=40, shape="down")
counter(b1 + 8, 8, seed=7, vel=64, phrase=(3, 6), rest=(3, 6))

# ---------------------------------------------------------------- A' with the countermelody answering
line("melody", a2, THEME_A, 86, art="legato")
for k in range(0, 16, 2):        # an answer in each two-bar phrase's held second half
    r, pcs, bs, _ = M.info(P.chord(a2 + k + 1))
    top = M.nearest(n("A4"), pcs, n("E4"), n("C5"))
    P.put("counter", a2 + k + 1, [(1, 1, M.nearest(top + 2, pcs, top + 1, top + 5), 68), (2, 1, top, 66)], art="legato")
bass(a2, 16); oompah(a2, 16); strings(a2, 16, vel=48); brushes(a2, 16); musicbox(a2, 16, vel=36)

# ---------------------------------------------------------------- INTERLUDE: the sideways step to G-flat
line("melody", il, INTERLUDE, 76, art="legato")
musicbox(il, 8, vel=54); strings(il, 8, vel=54, grow=1.5)
for i in range(8): P.put("bass", il + i, [(0, 2.8, M.nearest(n("D3"), [M.info(P.chord(il + i))[2] % 12], n("E2"), n("D3") + 1), 70)])

# ---------------------------------------------------------------- SOLO: the countermelody's chorus
counter(so, 16, seed=23, vel=84, lo=n("A4"), hi=n("E6"), phrase=(5, 10), rest=(2, 4), start_rest=0)
bass(so, 16); oompah(so, 16, vel=54); brushes(so, 16); strings(so + 8, 8, vel=42)
line("melody", so + 12, {2: [(0, 2, "A5"), (2, 1, "E5")], 3: [(0, 3, "C#5")]}, 70, art="legato")

# ---------------------------------------------------------------- A'': everyone, fuller
line("melody", a3, THEME_A, 94, art="legato")
counter(a3, 16, seed=31, vel=66, phrase=(3, 5), rest=(3, 5), start_rest=4)
bass(a3, 16, vel=90); oompah(a3, 16, vel=64); strings(a3, 16, vel=56, grow=.6); brushes(a3, 16, vel=6); musicbox(a3 + 8, 8, vel=44)

# ---------------------------------------------------------------- CODA: and D major, held
line("melody", coda, CODA, 84, art="legato")
bass(coda, 6, vel=80); oompah(coda, 6, vel=56); strings(coda, 8, vel=54); brushes(coda, 6, vel=-4)
musicbox(coda + 4, 4, vel=48)
P.put("bass", coda + 6, [(0, 2.9, "D3", 82)]); P.put("bass", coda + 7, [(0, 2.9, "D2", 74)])
P.put("chords", coda + 6, [(0, 2.9, M.voicing("D", n("A3"), n("G4") + 2, 3), 58)])
P.put("counter", coda + 7, [(0, 2.9, "A4", 60)])
P.hit("brush", coda + 7, 0, "tap", 50)

for pid in ("melody", "counter"):
    M.drop_overlaps(P, pid)

tpl = P.template(
    {"id": "after-hours", "title": "After Hours", "genre": "classical", "style": "Waltz",
     "source": "New for the Music Lab (Claudette), Oct 25 2026", "bpm": 132, "key": "D minor (ending in D major)", "feel": "3/4"},
    [("bass", "Bass", "bass", 1, None, "The waltz's 'oom': the root on one, the fifth every other bar; held through the interlude."),
     ("chords", "Waltz chords", "comp", 3, "staccato", "The 'pah-pah' on beats two and three."),
     ("melody", "Melody", "melody", 1, None, "The tune (A), its F-major answer (B), interlude fragments, the coda."),
     ("counter", "Countermelody", "answer", 1, None, "Answers in A', a chorus of its own, lines over A''."),
     ("box", "Music box", "answer", 1, "staccato", "Turning arpeggios: alone in the intro, featured in the interlude."),
     ("strings", "Strings", "pad", 3, "legato", "Held chords, swelling in B and the interlude."),
     ("brush", "Brushes", "rhythm", 1, None, "A soft tap on one and brushes on two and three.")],
    [("melody", "Melody"), ("bass", "Bass"), ("chords", "Waltz chords"), ("box", "Music box"), ("counter", "Countermelody"),
     ("strings", "Strings"), ("brush", "Brushes")])
write(tpl)
