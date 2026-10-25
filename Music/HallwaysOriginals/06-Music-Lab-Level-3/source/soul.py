"""HALLWAYS GENRE AUDITION -- "Night Porter". Soul-jazz / boogaloo blues, G, 100 bpm, straight sixteenths.

The hook: a five-note organ figure -- "da-da DAAH, da-dah, da-DAAH" (D F G, F D, F G) -- that comes back
over the changes the way blues riffs do: as is over G7, moved up a fourth over C7 (G Bb C), and stretched
to the chord's top over D7 (D F# A C). The horns answer it, the bass riff walks under it (G G Bb C C# D F).

  Hammond organ (synthesized here)    the tune, the comping, a solo
  electric guitar (MuseScore General) offbeat chops; a solo
  electric bass (MuseScore General)   the boogaloo riff
  drums (MuseScore General kit)       the groove, fills, the ending
  trumpet, trombone (VSCO-2 samples), tenor sax (MuseScore General)   answers, the shout

Form: intro 4 / head 12 / solos 12 (guitar 4, organ 4, horns shout 4) / head out 4 / ending 2.
"""
import sys
sys.path.insert(0, "/home/claude/lab"); sys.path.insert(0, "/home/claude/lab/genres")
from labkit import n, chord, voicing, harm_below, place
from common import B, line, add
import studio as S

TITLE = "Night Porter"
SLUG = "A-soul-Night-Porter"
BPM = 100.0
BPB = 4
RT = 1.2

BLUES = ["G7", "G7", "G7", "G7", "C7", "C7", "G7", "G7", "D7", "C7", "G7", "D7"]

M = [(.5, .25, "D5"), (.75, .25, "F5"), (1, .75, "G5"), (2, .25, "F5"), (2.25, .5, "D5"), (3, .25, "F5"), (3.25, .75, "G5")]
M_IV = [(.5, .25, "G4"), (.75, .25, "Bb4"), (1, .75, "C5"), (2, .25, "Bb4"), (2.25, .5, "G4"), (3, .25, "Bb4"), (3.25, .75, "C5")]
M_V = [(.5, .25, "D5"), (.75, .25, "F#5"), (1, .75, "A5"), (2, .25, "C6"), (2.25, .5, "A5"), (3, .25, "F#5"), (3.25, .75, "A5")]
HEAD = {1: M, 3: M,
        4: [(.5, .25, "G5"), (.75, .25, "F5"), (1, .5, "D5"), (1.5, .5, "C5"), (2, .5, "Bb4"), (2.5, 1.5, "G4")],
        5: M_IV, 7: M,
        8: [(.5, .25, "G5"), (.75, .25, "F5"), (1, .5, "D5"), (1.5, .5, "C5"), (2, .5, "Bb4"), (2.5, 1.5, "G4")],
        9: M_V,
        10: [(0, 1, "G5"), (1, .5, "E5"), (1.5, .5, "C5"), (2, .5, "Bb4"), (2.5, 1.5, "G4")],
        11: [(.5, .25, "D5"), (.75, .25, "F5"), (1, 2.5, "G5")]}
# the horns' answers: (bar, [(beat, dur)]) -- voiced on that bar's chord
ANSWERS = {2: [(1.5, .3), (2.25, .3), (2.5, .9)], 6: [(1.5, .3), (2.25, .3), (2.5, .9)], 12: [(2, .4), (2.5, .4), (3, .9)]}
GUITAR_SOLO = {1: [(0, .25, "Bb4"), (.25, .25, "B4"), (.5, .5, "D5"), (1, .5, "G5"), (1.5, .25, "F5"), (1.75, .25, "D5"), (2, 1, "F5")],
               2: [(0, .5, "D5"), (.5, .5, "C5"), (1, .5, "Bb4"), (1.5, .5, "G4"), (2, 1.5, "Bb4")],
               3: [(0, .25, "Bb4"), (.25, .25, "B4"), (.5, .5, "D5"), (1, .5, "G5"), (1.5, .5, "Bb5"), (2, .25, "G5"), (2.25, .75, "F5"), (3, .5, "D5")],
               4: [(0, .25, "G5"), (.25, .25, "F5"), (.5, .25, "D5"), (.75, .25, "C5"), (1, .25, "Bb4"), (1.25, .25, "G4"), (1.5, 1.5, "G4")]}
ORGAN_SOLO = {5: [(0, .25, "C5"), (.25, .25, "Eb5"), (.5, .25, "E5"), (.75, .25, "G5"), (1, 1, "Bb5"), (2.5, .5, "G5"), (3, .5, "E5"), (3.5, .5, "C5")],
              6: [(0, 2, "Bb4"), (2.5, .5, "G5"), (3, 1, "Bb5")],
              7: [(0, .25, "D6"), (.25, .25, "Bb5"), (.5, .25, "G5"), (.75, .25, "F5"), (1, .25, "D5"), (1.25, .75, "F5"), (2, 2, "G5")],
              8: [(0, .5, "F5"), (.5, .5, "D5"), (1, 1, "G4"), (2, .5, "Bb4"), (2.5, .5, "B4"), (3, 1, "D5")]}
SHOUT = {9: [(0, .5, "A5"), (.75, .25, "A5"), (1, .75, "C6"), (2.5, 1.5, "A5")],
         10: [(0, .5, "G5"), (.75, .25, "G5"), (1, .75, "Bb5"), (2.5, 1.5, "G5")],
         11: M,
         12: [(2, .5, "F#5"), (2.5, .5, "A5"), (3, 1, "C6")]}

WHO = ["organ", "guitar", "bass", "drums", "trumpet", "sax", "trombone"]


def band():
    v = lambda f: ("sfz", f"{S.VSCO}/{f}.sfz")
    drums = S.ep("Drums (MuseScore General kit)", "drums", ("sf", S.MSG, 0), channel=9)
    return {
        "organ": S.ep("Hammond organ (synthesized)", "organ", ("hammond", {"drawbars": "888600000", "perc": 3, "leslie": 6.4, "drive": 1.4})),
        "guitar": S.ep("Electric guitar (MuseScore General)", "guitar", ("sf", S.MSG, 27)),
        "bass": S.ep("Electric bass (MuseScore General)", "bass", ("sf", S.MSG, 33)),
        "drums": drums,
        "trumpet": S.ep("Trumpet (VSCO-2)", "trumpet", v("TrumpetSus")),
        "sax": S.ep("Tenor sax (MuseScore General)", "sax", ("sf", S.MSG, 66)),
        "trombone": S.ep("Trombone (VSCO-2)", "trombone", v("TromboneSus")),
    }


ROOTS = {"G7": "G1", "C7": "C2", "D7": "D2", "G9": "G1"}


def bass(p, bar0, chords, vel=92):
    for i, sym in enumerate(chords, 1):
        r = n(ROOTS.get(sym, "G1"))
        b0 = B(bar0, i, BPB)
        for beat, dur, iv, v in [(0, .7, 0, 0), (.75, .2, 0, -14), (1.5, .45, 3, -6), (2, .22, 5, -8), (2.5, .2, 6, -10),
                                 (2.75, .7, 7, -2), (3.5, .45, 10, -8)]:
            add(p, b0 + beat, dur, r + iv, vel + v + p.rng.randint(-4, 3), bpm=BPM, jitter_ms=3)


def drums(p, bar0, nbars, vel=1.0, fills=(), crash=(), stop=()):
    K, SN, HH, OH, CR, TH, TL = 36, 38, 42, 46, 49, 50, 45
    for i in range(1, nbars + 1):
        b0 = B(bar0, i, BPB)
        if i in stop:
            continue
        for k in range(8):
            if i in fills and k >= 4:
                continue
            add(p, b0 + k * .5, .2, OH if (k == 7 and i % 2 == 0) else HH, int((70 if k % 2 == 0 else 50) * vel) + p.rng.randint(-5, 5), bpm=BPM, jitter_ms=3)
        for beat in (0, .75, 2.5):
            add(p, b0 + beat, .2, K, int(92 * vel) + p.rng.randint(-4, 4), bpm=BPM, jitter_ms=2)
        for beat in (1, 3):
            if not (i in fills and beat == 3):
                add(p, b0 + beat, .2, SN, int(96 * vel) + p.rng.randint(-4, 4), bpm=BPM, jitter_ms=2)
        for beat in (1.75, 3.25) + ((3.75,) if i % 2 == 0 and i not in fills else ()):
            add(p, b0 + beat, .1, SN, int(34 * vel) + p.rng.randint(-5, 5), bpm=BPM, jitter_ms=4)
        if i in fills:
            for k, (beat, m) in enumerate([(2, SN), (2.25, SN), (2.5, TH), (2.75, TH), (3, TL), (3.25, TL), (3.5, SN), (3.75, SN)]):
                add(p, b0 + beat, .15, m, int((66 + 4 * k) * vel), bpm=BPM, jitter_ms=2)
    for i in crash:
        add(p, B(bar0, i, BPB), 1, CR, int(100 * vel), bpm=BPM)
        add(p, B(bar0, i, BPB), .2, K, int(100 * vel), bpm=BPM)


def chops(p, bar0, chords, vel=70, skip=()):
    """Guitar: short ninth-chord chops on the 'and' of 2 and of 4, a muted sixteenth before each."""
    for i, sym in enumerate(chords, 1):
        if i in skip:
            continue
        v = voicing(sym.replace("7", "9"), 0, lo=n("D4"), hi=n("B4"))[:3]
        for beat in (1.5, 3.5):
            for k, m in enumerate(v):
                add(p, B(bar0, i, BPB) + beat + k * .006, .14, m, vel + p.rng.randint(-4, 4), bpm=BPM, jitter_ms=2)
            add(p, B(bar0, i, BPB) + beat - .25, .05, v[0], 30, bpm=BPM, jitter_ms=2)


def organ_comp(p, bar0, chords, vel=60, skip=()):
    for i, sym in enumerate(chords, 1):
        if i in skip:
            continue
        v = voicing(sym, 0, lo=n("B3"), hi=n("F4"))[:3]
        for beat, dur in [(0, 1.4), (2.5, 1.2)]:
            for m in v:
                add(p, B(bar0, i, BPB) + beat, dur, m, vel, bpm=BPM)


HIT_VOICING = {"C7": "C7sus4"}      # (the riff's blue Eb sounds with the hit: no E against it)


def horn_hits(P, bar0, chords, hits, vel=84):
    """Each hit voiced on its bar's chord: trumpet on top, sax and trombone below (close)."""
    for bar, rhythm in hits.items():
        sym = HIT_VOICING.get(chords[bar - 1], chords[bar - 1])
        top = voicing(sym, 0, lo=n("D5"), hi=n("A5"))[-1]
        sax, tbn = harm_below(top, sym, 0, count=2)
        while tbn > n("F4"):
            tbn -= 12
        for beat, dur in rhythm:
            b = B(bar0, bar, BPB) + beat
            add(P["trumpet"], b, dur, top, vel, bpm=BPM)
            add(P["sax"], b, dur, sax, vel - 6, bpm=BPM)
            add(P["trombone"], b, dur, tbn, vel - 4, bpm=BPM)


def horn_line(P, bar0, chords, mel, vel=86):
    """A line for the three horns: trumpet on it, sax and trombone in harmony beneath."""
    for bar, notes in mel.items():
        sym = chords[bar - 1]
        for beat, dur, name in notes:
            top = n(name)
            sax, tbn = harm_below(top, sym, 0, count=2)
            while tbn > n("F4"):
                tbn -= 12
            b = B(bar0, bar, BPB) + beat
            add(P["trumpet"], b, dur * .92, top, vel, bpm=BPM)
            add(P["sax"], b, dur * .92, sax, vel - 6, bpm=BPM)
            add(P["trombone"], b, dur * .92, tbn, vel - 4, bpm=BPM)


def build():
    P = band()
    bar = 1
    # intro: Tinky-style drums alone (2, the 2nd with a fill), then the bass riff, guitar chops, an organ swell
    drums(P["drums"], bar, 4, fills=(2, 4))
    bass(P["bass"], bar + 2, ["G7", "G7"])
    chops(P["guitar"], bar + 2, ["G7", "G7"])
    for m in voicing("G9", 0, lo=n("B3"), hi=n("A4")):
        add(P["organ"], B(bar, 3, BPB), 7.5, m, 56, bpm=BPM)
    bar += 4
    # the head
    line(P["organ"], bar, HEAD, vel=96, bpb=BPB, bpm=BPM, swell=False, legato=.9)
    horn_hits(P, bar, BLUES, ANSWERS)
    chops(P["guitar"], bar, BLUES)
    bass(P["bass"], bar, BLUES)
    drums(P["drums"], bar, 12, fills=(12,), crash=(1,))
    bar += 12
    # solos: guitar (1-4, organ comps), organ (5-8, guitar chops), the horns' shout (9-12)
    line(P["guitar"], bar, GUITAR_SOLO, vel=88, bpb=BPB, bpm=BPM, swell=False, legato=.9)
    organ_comp(P["organ"], bar, BLUES, skip=range(5, 13))
    line(P["organ"], bar, ORGAN_SOLO, vel=98, bpb=BPB, bpm=BPM, swell=False, legato=.9)
    chops(P["guitar"], bar, BLUES, skip=(1, 2, 3, 4))
    horn_line(P, bar, BLUES, SHOUT, vel=90)
    organ_comp(P["organ"], bar, BLUES, skip=range(1, 9), vel=56)
    bass(P["bass"], bar, BLUES)
    drums(P["drums"], bar, 12, fills=(4, 8, 12), crash=(1, 5, 9))
    bar += 12
    # head out: the last four bars of the head, then the ending
    outro = BLUES[8:]
    line(P["organ"], bar, {k - 8: v for k, v in HEAD.items() if k >= 9}, vel=98, bpb=BPB, bpm=BPM, swell=False, legato=.9)
    horn_hits(P, bar, outro, {4: [(2, .4), (2.5, .4)]})
    chops(P["guitar"], bar, outro)
    bass(P["bass"], bar, outro)
    drums(P["drums"], bar, 4, fills=(4,), crash=(1,))
    bar += 4
    # the ending: one band hit (G7#9), a held organ G9 with the Leslie, a last crash
    hit = B(bar, 1, BPB)
    for m in [n("G2"), n("F3"), n("B3"), n("Bb4"), n("D5")]:
        add(P["organ"], hit, 6, m, 100, bpm=BPM)
    for who, m in [("trumpet", n("Bb5")), ("sax", n("F5")), ("trombone", n("B3"))]:
        add(P[who], hit, 3.5, m, 96, bpm=BPM)
    for k, m in enumerate([n("G3"), n("B3"), n("F4"), n("Bb4")]):
        add(P["guitar"], hit + k * .02, 3.5, m, 84, bpm=BPM)
    add(P["bass"], hit, 3.5, n("G1"), 100, bpm=BPM)
    add(P["drums"], hit, 3, 49, 112, bpm=BPM); add(P["drums"], hit, .3, 36, 112, bpm=BPM)
    total = hit + 8
    return P, [(0, BPM)], total


COMBOS = [
    (["bass", "drums"], "bass and drums"),
    (["bass", "drums", "guitar"], "bass, drums, guitar"),
    (["bass", "drums", "organ"], "organ trio (organ, bass, drums)"),
    (["bass", "drums", "guitar", "organ"], "the rhythm section (no horns)"),
    (["trumpet", "sax", "trombone"], "the three horns alone"),
    (["organ"], "organ alone"),
    (["drums"], "drums alone"),
]
LEVELS = {"organ": -20.0, "guitar": -22.5, "bass": -20.0, "drums": -20.5, "trumpet": -23.5, "sax": -24.5, "trombone": -25.0}
PAN = {"organ": -0.2, "guitar": 0.4, "bass": 0.0, "drums": 0.0, "trumpet": 0.25, "sax": -0.35, "trombone": 0.45}
ROOM = {"organ": 0.15, "guitar": 0.15, "bass": 0.04, "drums": 0.12, "trumpet": 0.22, "sax": 0.22, "trombone": 0.22}


def build_loop():
    """The lab's loop (24 bars, 57.6 s): the head, then the solo chorus (guitar, organ, the horns' shout);
    its last bar (D7) turns straight back into the head."""
    P = band()
    bar = 1
    line(P["organ"], bar, HEAD, vel=96, bpb=BPB, bpm=BPM, swell=False, legato=.9)
    horn_hits(P, bar, BLUES, ANSWERS)
    chops(P["guitar"], bar, BLUES)
    bass(P["bass"], bar, BLUES)
    drums(P["drums"], bar, 12, fills=(12,), crash=(1,))
    bar += 12
    line(P["guitar"], bar, GUITAR_SOLO, vel=88, bpb=BPB, bpm=BPM, swell=False, legato=.9)
    organ_comp(P["organ"], bar, BLUES, skip=range(5, 13))
    line(P["organ"], bar, ORGAN_SOLO, vel=98, bpb=BPB, bpm=BPM, swell=False, legato=.9)
    chops(P["guitar"], bar, BLUES, skip=(1, 2, 3, 4))
    horn_line(P, bar, BLUES, SHOUT, vel=90)
    organ_comp(P["organ"], bar, BLUES, skip=range(1, 9), vel=56)
    bass(P["bass"], bar, BLUES)
    drums(P["drums"], bar, 12, fills=(4, 8, 12), crash=(1, 5, 9))
    return P, [(0, BPM)], 24 * BPB


build_performance = build
LAB = {
    "id": "night-porter", "title": "Night Porter", "subtitle": "Hallways Originals #3",
    "genre": "Soul-jazz blues", "order": 4, "bpm": 100, "beatsPerBar": 4,
    "parts": {
        "organ": ("Organ", "Hammond organ", "#C8553D"),
        "guitar": ("Guitar", "electric guitar", "#9C5B3B"),
        "bass": ("Bass", "electric bass", "#5B4B8A"),
        "drums": ("Drums", "drum kit", "#8A9BA8"),
        "trumpet": ("Trumpet", "trumpet", "#D49A2A"),
        "sax": ("Sax", "tenor sax", "#2E8B6E"),
        "trombone": ("Trombone", "trombone", "#B0517E"),
    },
}
LAB_COMBOS = [(["bass", "drums"], "bass and drums"), (["bass", "drums", "organ"], "organ trio"),
              (["bass", "drums", "organ", "guitar"], "rhythm section"), (["trumpet", "sax", "trombone"], "the horns")]
