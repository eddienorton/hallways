"""HALLWAYS GENRE AUDITION -- "The Lantern Room". A cinematic waltz, D minor -> D major, 3/4, 76 bpm.

The hook: a rising fourth into a long note (A-D), a little turn above it (E-F-E), then a stepwise fall --
and when it comes back the leap widens to a sixth (A-F). Bar 7's E over B-flat (the lydian #11) is the
'slightly magical' colour. The second half lifts into F major (C-A, a sixth), then a deceptive cadence
onto B-flat instead of home. The coda brings the music box back -- in D MAJOR.

  glockenspiel (VSCO-2)          the music box: the motif, at the start and the end
  harp (VSCO-2)                  arpeggios, the pulse of the waltz
  flute (VSCO-2)                 the theme, first time
  solo violin (VSCO-2)           the theme, second time
  violins / violas / cellos      (VSCO-2 sections) pads, answers, the climax (melody in octaves)
  contrabass (VSCO-2)            the floor
  French horn (VSCO-2)           warmth under the climax
"""
import sys
sys.path.insert(0, "/home/claude/lab"); sys.path.insert(0, "/home/claude/lab/genres")
from labkit import n, chord, place
from common import B, line, add
import studio as S

TITLE = "The Lantern Room"
SLUG = "B-cinematic-The-Lantern-Room"
BPM = 76.0
BPB = 3
RT = 2.4

CH = ["Dm", "Dm/C", "Bb", "A7", "Dm", "Gm", "Bb", "A7", "F", "C/E", "Dm", "Bb", "Gm7", "A7", "Bb", "A7"]
THEME = {1: [(0, 1, "A4"), (1, 2, "D5")],
         2: [(0, 1.5, "E5"), (1.5, .5, "F5"), (2, 1, "E5")],
         3: [(0, 1, "D5"), (1, 1, "C5"), (2, 1, "Bb4")],
         4: [(0, 3, "A4")],
         5: [(0, 1, "A4"), (1, 2, "F5")],
         6: [(0, 1.5, "G5"), (1.5, .5, "F5"), (2, 1, "E5")],
         7: [(0, 1, "F5"), (1, 1, "E5"), (2, 1, "D5")],
         8: [(0, 3, "C#5")],
         9: [(0, 1, "C5"), (1, 2, "A5")],
         10: [(0, 1.5, "G5"), (1.5, .5, "F5"), (2, 1, "E5")],
         11: [(0, 1, "F5"), (1, 1, "D5"), (2, 1, "A4")],
         12: [(0, 2, "Bb4"), (2, 1, "D5")],
         13: [(0, 1, "D5"), (1, 1, "Bb4"), (2, 1, "G4")],
         14: [(0, 2, "E5"), (2, 1, "C#5")],
         15: [(0, 3, "D5")],
         16: [(0, 3, "C#5")]}
# the cellos' answers in the theme's long notes
ANSWER = {4: [(.5, .5, "E3"), (1, .5, "G3"), (1.5, .5, "A3"), (2, 1, "C#4")],
          8: [(.5, .5, "A3"), (1, .5, "B3"), (1.5, .5, "C#4"), (2, 1, "E4")],
          16: [(.5, .5, "A2"), (1, .5, "C#3"), (1.5, .5, "E3"), (2, 1, "G3")]}
BOX = {1: [(0, 1, "A5"), (1, 2, "D6")], 2: [(0, 1.5, "E6"), (1.5, .5, "F6"), (2, 1, "E6")]}
BOX_MAJOR = {1: [(0, 1, "A5"), (1, 2, "D6")], 2: [(0, 1.5, "E6"), (1.5, .5, "F#6"), (2, 1, "E6")], 3: [(0, 3, "D6")]}

WHO = ["glock", "harp", "flute", "violin", "violins", "violas", "cellos", "basses", "horn"]


def band():
    v = lambda f: ("sfz", f"{S.VSCO}/{f}.sfz")
    return {
        "glock": S.ep("Glockenspiel (VSCO-2)", "glock", v("Glockenspiel")),
        "harp": S.ep("Harp (VSCO-2, release shortened: damped between chords)", "harp", v("HarpDamped")),
        "flute": S.ep("Flute (VSCO-2)", "flute", v("FluteSusVib")),
        "violin": S.ep("Solo violin (VSCO-2)", "violin", v("SViolinVib")),
        "violins": S.ep("Violins (VSCO-2 section)", "violins", v("ViolinEnsSusVib")),
        "violas": S.ep("Violas (VSCO-2 section)", "violas", v("ViolaEnsSusVib")),
        "cellos": S.ep("Cellos (VSCO-2 section)", "cellos", v("CelloEnsSusVib")),
        "basses": S.ep("Contrabass (VSCO-2)", "basses", v("ContrabassSusVB")),
        "horn": S.ep("French horn (VSCO-2)", "horn", v("FHornSus")),
    }


def tones(sym):
    r, pcs, bass, q = chord(sym)
    return r, pcs, bass


def harp(p, bar0, chords, vel=56):
    """Six eighths a bar: the chord's tones up and back (bass, fifth, then the upper tones)."""
    for i, sym in enumerate(chords, 1):
        r, pcs, bass = tones(sym)
        lo = place(bass, n("D2"), n("C#3"))
        up = sorted({place(pc, lo + 5, lo + 17) for pc in pcs})
        seq = [lo] + up[:3] + [up[min(3, len(up) - 1)] + 12 if len(up) > 3 else up[-1] + 12]
        pattern = [seq[0], seq[1], seq[2], seq[3] if len(seq) > 3 else seq[2] + 12, seq[2], seq[1]]
        for k, m in enumerate(pattern):
            add(p, B(bar0, i, BPB) + k * 0.5, min(1.6, BPB - k * 0.5 - 0.05), m, vel + (6 if k == 0 else 0) + p.rng.randint(-4, 4), bpm=BPM)


def pad(p, bar0, chords, lo, hi, vel=50, which=(1, 2)):
    """Sustained chord tones (by index into the chord: 0 root, 1 third, 2 fifth, 3 seventh) moving smoothly."""
    prev = None
    for i, sym in enumerate(chords, 1):
        r, pcs, bass = tones(sym)
        for j in which:
            pc = pcs[min(j, len(pcs) - 1)]
            m = place(pc, lo, hi, prev[j] if prev and j in prev else (lo + hi) // 2)
            add(p, B(bar0, i, BPB), 2.9, m, vel + p.rng.randint(-3, 3), bpm=BPM)
        prev = {j: place(pcs[min(j, len(pcs) - 1)], lo, hi, (lo + hi) // 2) for j in which}


def bassline(p, bar0, chords, lo, hi, vel=58):
    for i, sym in enumerate(chords, 1):
        r, pcs, bass = tones(sym)
        add(p, B(bar0, i, BPB), 2.9, place(bass, lo, hi), vel + p.rng.randint(-3, 3), bpm=BPM)


def build():
    P = band()
    bar = 1
    # intro: the music box, over the harp and a soft cello D
    intro = ["Dm", "Dm/C", "Bb", "A7"]
    line(P["glock"], bar, BOX, vel=58, bpb=BPB, bpm=BPM, swell=False)
    harp(P["harp"], bar, intro, vel=46)
    bassline(P["cellos"], bar, intro, n("Bb2"), n("A3"), vel=40)
    bar += 4
    # the theme: flute; harp; violas pad; cellos answer in the long notes; basses
    line(P["flute"], bar, THEME, vel=70, bpb=BPB, bpm=BPM)
    harp(P["harp"], bar, CH)
    pad(P["violas"], bar, CH, n("F3"), n("D4"), vel=42)
    line(P["cellos"], bar, ANSWER, vel=58, bpb=BPB, bpm=BPM, swell=False)
    bassline(P["basses"], bar, CH, n("E1"), n("D2"), vel=50)
    bar += 16
    # the solo violin takes the theme (first half); the flute sings long notes above; violins pad
    first = {k: v for k, v in THEME.items() if k <= 8}
    line(P["violin"], bar, first, vel=72, bpb=BPB, bpm=BPM)
    line(P["flute"], bar, {2: [(0, 3, "A5")], 4: [(0, 3, "G5")], 6: [(0, 3, "Bb5")], 8: [(0, 3, "A5")]}, vel=52, bpb=BPB, bpm=BPM)
    harp(P["harp"], bar, CH[:8], vel=50)
    pad(P["violins"], bar, CH[:8], n("A3"), n("F4"), vel=44, which=(1, 2))
    pad(P["violas"], bar, CH[:8], n("D3"), n("A3"), vel=40, which=(0,))
    line(P["cellos"], bar, {4: ANSWER[4], 8: ANSWER[8]}, vel=60, bpb=BPB, bpm=BPM, swell=False)
    bassline(P["basses"], bar, CH[:8], n("E1"), n("D2"), vel=52)
    bar += 8
    # the climax: the second half in octaves -- violins above, cellos below; horn and violas fill
    second = {k - 8: v for k, v in THEME.items() if k > 8}
    line(P["violins"], bar, second, vel=84, bpb=BPB, bpm=BPM)
    line(P["cellos"], bar, second, vel=78, bpb=BPB, bpm=BPM, octave=-2)
    pad(P["horn"], bar, CH[8:], n("C3"), n("A3"), vel=58, which=(1,))
    pad(P["violas"], bar, CH[8:], n("F3"), n("D4"), vel=56, which=(1, 2))
    harp(P["harp"], bar, CH[8:], vel=64)
    bassline(P["basses"], bar, CH[8:], n("E1"), n("D2"), vel=66)
    bar += 8
    # coda: the music box again -- now in D MAJOR; a held flute A; strings ppp
    coda = ["D", "D", "D", "D", "D", "D"]
    line(P["glock"], bar, BOX_MAJOR, vel=60, bpb=BPB, bpm=BPM, swell=False)
    line(P["flute"], bar + 3, {1: [(0, 9, "A5")]}, vel=48, bpb=BPB, bpm=BPM)
    harp(P["harp"], bar, coda[:3], vel=44)
    for m in [n("D4"), n("F#4"), n("A4")]:
        add(P["violins"], B(bar, 2, BPB), 13, m, 36, bpm=BPM)
    for m in [n("D3"), n("A3")]:
        add(P["violas"], B(bar, 2, BPB), 13, m, 34, bpm=BPM)
    add(P["cellos"], B(bar, 1, BPB), 16, n("D2") + 12, 36, bpm=BPM)
    add(P["basses"], B(bar, 1, BPB), 16, n("D2"), 36, bpm=BPM)
    for k, m in enumerate([n("D3"), n("A3"), n("D4"), n("F#4"), n("A4"), n("D5")]):        # a last harp roll
        add(P["harp"], B(bar, 5, BPB) + k * 0.18, 4, m, 50, bpm=BPM)
    total = B(bar, 7, BPB) + 3
    return P, [(0, BPM), (B(bar, 4, BPB), 70), (B(bar, 5, BPB), 62)], total


COMBOS = [
    (["harp"], "harp alone (the waltz's pulse)"),
    (["harp", "flute"], "flute and harp (a duo)"),
    (["harp", "flute", "cellos", "basses"], "flute, harp, cellos and basses"),
    (["violin", "harp", "violins", "violas"], "solo violin with strings and harp"),
    (["violins", "violas", "cellos", "basses"], "the string section alone"),
    (["glock", "harp", "flute", "violin"], "the light ones - glock, harp, flute, violin"),
    (["violins", "cellos", "horn", "harp", "basses"], "the climax players"),
]
LEVELS = {"glock": -27.0, "harp": -24.0, "flute": -19.5, "violin": -19.5, "violins": -21.5, "violas": -25.5,
          "cellos": -22.5, "basses": -26.0, "horn": -25.0}
PAN = {"glock": 0.3, "harp": -0.35, "flute": 0.15, "violin": -0.1, "violins": -0.4, "violas": 0.15, "cellos": 0.4, "basses": 0.5, "horn": 0.2}
ROOM = {w: 0.4 for w in WHO}


ECHO_A7 = [(.5, .5, "E6"), (1, .5, "C#6"), (1.5, 1.5, "A5")]
ECHO_BB = [(.5, .5, "F6"), (1, .5, "D6"), (1.5, 1.5, "Bb5")]


def build_loop():
    """The lab's loop (32 bars, 75.8 s): the theme (flute), the violin's half, the climax; the climax's last
    bar (A7) turns back to the theme. The glockenspiel -- the music box -- answers in the theme's held notes."""
    P = band()
    bar = 1
    line(P["flute"], bar, THEME, vel=70, bpb=BPB, bpm=BPM)
    harp(P["harp"], bar, CH)
    pad(P["violas"], bar, CH, n("F3"), n("D4"), vel=42)
    line(P["cellos"], bar, ANSWER, vel=58, bpb=BPB, bpm=BPM, swell=False)
    bassline(P["basses"], bar, CH, n("E1"), n("D2"), vel=50)
    line(P["glock"], bar, {4: ECHO_A7, 8: ECHO_A7, 12: ECHO_BB, 16: ECHO_A7}, vel=50, bpb=BPB, bpm=BPM, swell=False)
    bar += 16
    first = {k: v for k, v in THEME.items() if k <= 8}
    line(P["violin"], bar, first, vel=72, bpb=BPB, bpm=BPM)
    line(P["flute"], bar, {2: [(0, 3, "A5")], 4: [(0, 3, "G5")], 6: [(0, 3, "Bb5")], 8: [(0, 3, "A5")]}, vel=52, bpb=BPB, bpm=BPM)
    harp(P["harp"], bar, CH[:8], vel=50)
    pad(P["violins"], bar, CH[:8], n("A3"), n("F4"), vel=44, which=(1, 2))
    pad(P["violas"], bar, CH[:8], n("D3"), n("A3"), vel=40, which=(0,))
    line(P["cellos"], bar, {4: ANSWER[4], 8: ANSWER[8]}, vel=60, bpb=BPB, bpm=BPM, swell=False)
    bassline(P["basses"], bar, CH[:8], n("E1"), n("D2"), vel=52)
    bar += 8
    second = {k - 8: v for k, v in THEME.items() if k > 8}
    line(P["violins"], bar, second, vel=84, bpb=BPB, bpm=BPM)
    line(P["cellos"], bar, second, vel=78, bpb=BPB, bpm=BPM, octave=-2)
    pad(P["horn"], bar, CH[8:], n("C3"), n("A3"), vel=58, which=(1,))
    pad(P["violas"], bar, CH[8:], n("F3"), n("D4"), vel=56, which=(1, 2))
    harp(P["harp"], bar, CH[8:], vel=64)
    bassline(P["basses"], bar, CH[8:], n("E1"), n("D2"), vel=66)
    return P, [(0, BPM)], 32 * BPB


build_performance = build
LAB = {
    "id": "lantern-room", "title": "The Lantern Room", "subtitle": "Hallways Originals #4",
    "genre": "Cinematic waltz", "order": 5, "bpm": 76, "beatsPerBar": 3,
    "parts": {
        "glock": ("Glockenspiel", "the music box", "#D49A2A"),
        "harp": ("Harp", "harp", "#9C5B3B"),
        "flute": ("Flute", "flute", "#3C7DBF"),
        "violin": ("Violin", "solo violin", "#C8553D"),
        "violins": ("Violins", "violin section", "#B0517E"),
        "violas": ("Violas", "viola section", "#8A9BA8"),
        "cellos": ("Cellos", "cello section", "#2E8B6E"),
        "basses": ("Double bass", "contrabass", "#5B4B8A"),
        "horn": ("Horn", "French horn", "#6E7F8D"),
    },
}
LAB_COMBOS = [(["harp", "flute"], "flute and harp"), (["violins", "violas", "cellos", "basses"], "the strings"),
              (["glock", "harp"], "music box and harp")]
