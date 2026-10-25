"""MINUET -- a new Hallways composition (Claudette, Oct 25 2026). Classical, G major, 3/4, 120 bpm.

A small courtly dance, a little prim and a little cheeky: the tune climbs a G arpeggio and curtsies down;
the accompaniment answers each downbeat with two light chords ("-- pah pah"); the bass steps on the
downbeat. In the middle (B, in D and E minor) the tune asks short questions and the countermelody echoes
them in the gaps. In the last A the countermelody sings along in sixths. Sparkles (little high
arpeggios) mark the cadences.

Form, 32 bars: A (8) / A, the high ending (8) / B (8) / A, the high ending (8) -- back to the top.
Layers, foundation up:  1 Bass   2 Pah-pah chords   3 Melody   4 Countermelody   5 Sparkles
"""
import sys
sys.path.insert(0, "/home/claude/band/templates")
from tplkit import part, write, n
from labkit import chord

BPM = 120
BPB = 3
A_CH = ["G", "G", "C", "G", "Am", "D7", "D7", "G"]
B_CH = ["D", "D", "Em", "Em", "A7", "D", "A7", "D7"]
FORM = A_CH + A_CH + B_CH + A_CH
# the tune, (beat, beats, note) per bar
A1 = {1: [(0, 1, "B4"), (1, 1, "D5"), (2, 1, "G5")],
      2: [(0, .5, "F#5"), (.5, .5, "E5"), (1, 2, "D5")],
      3: [(0, 1, "E5"), (1, 1, "G5"), (2, 1, "E5")],
      4: [(0, 2, "D5"), (2, 1, "B4")],
      5: [(0, 1, "C5"), (1, 1, "A4"), (2, .5, "C5"), (2.5, .5, "E5")],
      6: [(0, 1, "D5"), (1, 1, "F#5"), (2, 1, "A5")],
      7: [(0, 1.5, "B4"), (1.5, .5, "C5"), (2, 1, "A4")],
      8: [(0, 3, "G4")]}
A2 = dict(A1)
A2.update({7: [(0, 1, "A5"), (1, .5, "F#5"), (1.5, .5, "D5"), (2, 1, "C5")],
           8: [(0, 2, "B4"), (2, 1, None)]})
A2[8] = [(0, 2, "G5")]
B = {1: [(0, 1, "A5"), (1, .5, "F#5"), (1.5, .5, "G5"), (2, 1, "A5")],
     2: [(0, 2, "D5")],
     3: [(0, 1, "G5"), (1, .5, "E5"), (1.5, .5, "F#5"), (2, 1, "G5")],
     4: [(0, 2, "B4")],
     5: [(0, .5, "C#5"), (.5, .5, "D5"), (1, 1, "E5"), (2, 1, "A5")],
     6: [(0, 1, "F#5"), (1, 1, "E5"), (2, 1, "D5")],
     7: [(0, 1, "C#5"), (1, 1, "E5"), (2, 1, "G5")],
     8: [(0, 2, "F#5"), (2, 1, "C5")]}
# the countermelody: echoes in B's gaps (bars 2, 4, 6, 8 of B), sixths under the last A
B_ECHO = {2: [(1, .5, "F#4"), (1.5, .5, "G4"), (2, 1, "A4")],
          4: [(1, .5, "E4"), (1.5, .5, "F#4"), (2, 1, "G4")],
          6: [(1, 1, "A4"), (2, 1, "F#4")],
          8: [(1, .5, "A4"), (1.5, .5, "B4"), (2, 1, "A4")]}
# sparkles: a little arpeggio up high at the cadences
SPARK = {(1, 4): [(1, .33, "G5"), (1.33, .33, "B5"), (1.67, .33, "D6")],
         (1, 8): [(1, .33, "D6"), (1.33, .33, "B5"), (1.67, .33, "G5")],
         (2, 4): [(1, .33, "G5"), (1.33, .33, "B5"), (1.67, .33, "D6")],
         (2, 8): [(1, .5, "B5"), (1.5, .5, "D6"), (2, 1, "G6")],
         (3, 2): [(2, .33, "A5"), (2.33, .33, "D6"), (2.67, .33, "F#6")],
         (3, 6): [(2, .33, "A5"), (2.33, .33, "D6"), (2.67, .33, "F#6")],
         (3, 8): [(2.5, .5, "C6")],
         (4, 4): [(1, .33, "G5"), (1.33, .33, "B5"), (1.67, .33, "D6")],
         (4, 8): [(1, .5, "B5"), (1.5, .5, "D6"), (2, 1, "G6")]}


def pcs_of(sym):
    r, pcs, bass, _ = chord(sym)
    return [p % 12 for p in pcs]


def below(m, sym, lo, hi):
    """The chord tone a sixth-ish (8-9 semitones) under m, inside lo..hi."""
    pcs = pcs_of(sym)
    for d in (8, 9, 7, 10, 5, 4, 3):
        c = m - d
        if c % 12 in pcs and lo <= c <= hi:
            return c
    return None


def main():
    bass, pah, mel, counter, spark = [], [], [], [], []
    sections = [A1, A2, B, A2]
    for s, tune in enumerate(sections):
        for bar in range(1, 9):
            idx = s * 8 + bar - 1
            sym = FORM[idx]
            b0 = idx * BPB
            r, pcs, bs, _ = chord(sym)
            root = n("G2") + ((bs - n("G2")) % 12)
            if root > n("D3"): root -= 12
            # bass: the downbeat, held; the fifth on beat 3 most bars; a step up into the cadence bars
            bass.append((b0, 1.6, root, 82))
            if bar in (4, 8):
                pass
            elif bar == 7:
                bass.append((b0 + 1, .9, root + 2, 70)); bass.append((b0 + 2, .9, root + 4, 72))
            else:
                bass.append((b0 + 2, .9, root + 7 if root + 7 <= n("D3") + 2 else root - 5, 70))
            # pah-pah: two light chords on beats 2 and 3 (none under the last bar of each half)
            if bar != 8:
                tones = sorted({n("G3") + ((pc - n("G3")) % 12) for pc in pcs_of(sym)})[:3]
                for beat in (1, 2):
                    for m in tones:
                        pah.append((b0 + beat, .45, m, 56 if beat == 1 else 50))
            # the tune
            for beat, d, name in tune.get(bar, []):
                if name is None: continue
                mel.append((b0 + beat, d * .95, n(name), 80 + (6 if beat == 0 else 0)))
            # the countermelody
            if s == 2:
                for beat, d, name in B_ECHO.get(bar, []):
                    counter.append((b0 + beat, d * .95, n(name), 66))
            elif s == 3:
                for beat, d, name in tune.get(bar, []):
                    if name is None: continue
                    c = below(n(name), sym, n("D4"), n("D5"))
                    if c: counter.append((b0 + beat, d * .95, c, 64))
            for beat, d, name in SPARK.get((s + 1, bar), []):
                spark.append((b0 + beat, d * .9, n(name), 60))
    tpl = {
        "format": "hallways-composition/1", "id": "minuet", "title": "Minuet", "genre": "classical",
        "style": "Minuet (a courtly dance)", "source": "New for the Music Lab (Claudette), Oct 25 2026",
        "bpm": BPM, "meter": [3, 4], "key": "G", "feel": "straight; three to a bar, light",
        "bars": 32, "loop": True,
        "sections": [{"name": "A", "start": 0, "bars": 8}, {"name": "A again", "start": 8, "bars": 8},
                     {"name": "B", "start": 16, "bars": 8}, {"name": "A, last time", "start": 24, "bars": 8}],
        "chords": [[[0, s]] for s in FORM],
        "parts": [
            part("bass", "Bass", "bass", bass, desc="The downbeat, held; the fifth on three; a little climb into each cadence."),
            part("pahpah", "Pah-pah chords", "comp", pah, poly=3, art="staccato", desc="Two light chords on beats 2 and 3."),
            part("melody", "Melody", "melody", mel, art="legato", desc="Up the G arpeggio, a curtsy down; B asks short questions."),
            part("counter", "Countermelody", "harmony", counter, art="legato", desc="Echoes the B section's questions; sixths under the last A."),
            part("sparkles", "Sparkles", "answer", spark, desc="Little high arpeggios at the cadences."),
        ],
        "layers": [{"part": "bass", "name": "Bass"}, {"part": "pahpah", "name": "Pah-pah chords"}, {"part": "melody", "name": "Melody"},
                   {"part": "counter", "name": "Countermelody"}, {"part": "sparkles", "name": "Sparkles"}],
    }
    write(tpl)


if __name__ == "__main__":
    main()
