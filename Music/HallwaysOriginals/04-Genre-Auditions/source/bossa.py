"""HALLWAYS GENRE AUDITION -- "Rua das Lampadas" (Lamp Street). Bossa nova, D major, 140 bpm.

The hook (A, bars 1-4): a rising four-note phrase that lands on a long note -- "da da da DAAH-da" --
then sighs down; the same shape again a step lower; then a surprising leap up to the 13th.
Bars 5-6 climb the shape once more into the B7(b9) tension; bars 7-8 come home.
B is the bittersweet middle: long notes, the minor-iv (Gm6) turn.

  flute (VSCO-2, sampled)            the tune
  nylon guitar (MuseScore General)   the bossa pattern: thumb bass + syncopated chords
  piano (Salamander Grand, sampled)  answers in the tune's gaps; takes the tune in the last A
  bass (VSCO-2 contrabass pizz)      roots and fifths, with anticipations
  congas, bongos, shaker, claves     (VSCO-2 / VCSL one-shots) the light Brazilian kitchen

Form: intro 4 / A 8 (flute) / A 8 (flute, piano answers) / B 8 / A 8 (piano, then flute) / tag 4 + end.
"""
import sys
sys.path.insert(0, "/home/claude/lab"); sys.path.insert(0, "/home/claude/lab/genres")
from labkit import n, chord, voicing, place
from common import B, line, chord_at, spans, add
import studio as S

TITLE = "Rua das Lâmpadas"
BPM = 140.0
BPB = 4

A = [[(0, "Dmaj9")], [(0, "Bm7")], [(0, "Em9")], [(0, "A13")], [(0, "F#m7")], [(0, "B7b9")], [(0, "Em9")], [(0, "A7sus4"), (2, "A7b9")]]
A_END = A[:6] + [[(0, "Em9"), (2, "A7")], [(0, "Dmaj9")]]
BR = [[(0, "Gmaj9")], [(0, "Gm6")], [(0, "F#m7")], [(0, "B7b9")], [(0, "Em9")], [(0, "A13")], [(0, "F#m7"), (2, "B7")], [(0, "Em7"), (2, "A7")]]
INTRO = [[(0, "Dmaj9")], [(0, "Bm7")], [(0, "Em9")], [(0, "A13")]]
TAG = [[(0, "Em9")], [(0, "A13")], [(0, "Em9")], [(0, "A13")], [(0, "Dmaj9")]]

TUNE_A = {1: [(.5, .5, "A4"), (1, .5, "D5"), (1.5, .5, "E5"), (2, 1.5, "F#5"), (3.5, .5, "E5")],
          2: [(0, 1, "D5"), (1, .5, "C#5"), (1.5, 2.5, "B4")],
          3: [(.5, .5, "G4"), (1, .5, "B4"), (1.5, .5, "D5"), (2, 1.5, "F#5"), (3.5, .5, "E5")],
          4: [(0, 1, "C#5"), (1, .5, "B4"), (1.5, 2.5, "F#5")],
          5: [(.5, .5, "C#5"), (1, .5, "E5"), (1.5, .5, "F#5"), (2, 1.5, "A5"), (3.5, .5, "G#5")],
          6: [(0, 1, "A5"), (1, .5, "F#5"), (1.5, 1, "D#5"), (2.5, 1.5, "C5")],
          7: [(0, 1.5, "B4"), (1.5, .5, "D5"), (2, .5, "E5"), (2.5, 1.5, "G5")],
          8: [(0, 1, "G5"), (1, .5, "E5"), (1.5, .5, "D5"), (2, 2, "E5")]}
TUNE_A_END = dict(TUNE_A)
TUNE_A_END.update({7: [(0, 1.5, "B4"), (1.5, .5, "E5"), (2, .5, "G5"), (2.5, 1.5, "F#5")],
                   8: [(0, 3.5, "D5")]})
TUNE_B = {1: [(0, 1.5, "B4"), (1.5, .5, "A4"), (2, 2, "F#5")],
          2: [(0, 1.5, "E5"), (1.5, .5, "D5"), (2, 2, "Bb4")],
          3: [(0, 1.5, "A4"), (1.5, .5, "C#5"), (2, 2, "E5")],
          4: [(0, 1, "D#5"), (1, 1, "C5"), (2, 2, "A4")],
          5: [(0, 1.5, "G4"), (1.5, .5, "B4"), (2, 2, "F#5")],
          6: [(0, 1.5, "F#5"), (1.5, .5, "E5"), (2, 2, "C#5")],
          7: [(0, 1.5, "A5"), (1.5, .5, "G#5"), (2, 2, "D#5")],
          8: [(0, 2, "G5"), (2, 1, "E5"), (3, 1, "C#5")]}
# the piano's answers, in the tune's long notes (A sections)
ANSWERS = {2: [(2.5, .5, "F#4"), (3, .5, "A4"), (3.5, .5, "B4")],
           4: [(2.5, .5, "A4"), (3, .5, "C#5"), (3.5, .5, "E5")],
           6: [(3, .5, "D#5"), (3.5, .5, "F#5")],
           8: [(2.5, .5, "C#5"), (3, .5, "E5"), (3.5, .5, "A5")]}
# the tag's last phrase (x2), the band's final chord
TAG_TUNE = {1: [(.5, .5, "G4"), (1, .5, "B4"), (1.5, .5, "D5"), (2, 1.5, "F#5"), (3.5, .5, "E5")],
            2: [(0, 1, "C#5"), (1, .5, "B4"), (1.5, 2.5, "F#5")],
            3: [(.5, .5, "G4"), (1, .5, "B4"), (1.5, .5, "D5"), (2, 1.5, "F#5"), (3.5, .5, "E5")],
            4: [(0, 1, "C#5"), (1, .5, "B4"), (1.5, 2.5, "A5")],
            5: [(0, 4, "F#5")]}

def soft(sym):
    """Accompaniment voicings: no 9th under the tune (a minor ninth against its third), no b9 in the pads."""
    return sym.replace("m9", "m7").replace("7b9", "7").replace("maj9", "maj7").replace("13", "9")


WHO = ["flute", "guitar", "piano", "bass", "congas", "bongos", "shaker", "claves"]


def band():
    perc = lambda: {}
    return {
        "flute": S.ep("Flute (VSCO-2)", "flute", ("sfz", f"{S.VSCO}/FluteSusVib.sfz")),
        "guitar": S.ep("Nylon guitar (MuseScore General)", "guitar", ("sf", S.MSG, 24)),
        "piano": S.ep("Piano (Salamander Grand)", "piano", ("sfz", S.SALAMANDER)),
        "bass": S.ep("Bass pizz (VSCO-2)", "bass", ("sfz", f"{S.VSCO}/ContrabassPizz.sfz")),
        "congas": S.ep("Congas (VSCO-2)", "congas", ("perc", {
            62: S.vsco_perc("Quinto-HitN"), 63: S.vsco_perc("Conga-HitN"), 64: S.vsco_perc("Tumba-HitN"),
            60: S.vsco_perc("Conga-Tap1")})),
        "bongos": S.ep("Bongos (VCSL)", "bongos", ("perc", {
            60: [S.vcsl_dir("Membranophones/Struck Membranophones/Bongos", f"BongoH_HitMuted1_v{v}_*.wav") for v in (1, 2, 3)],
            61: [S.vcsl_dir("Membranophones/Struck Membranophones/Bongos", f"BongoH_Hit1_v{v}_*.wav") for v in (1, 2, 3)],
            62: [S.vcsl_dir("Membranophones/Struck Membranophones/Bongos", f"BongoL_Hit1_v{v}_*.wav") for v in (1, 2, 3)]})),
        "shaker": S.ep("Shaker (VCSL)", "shaker", ("perc", {
            60: [S.vcsl_dir("Idiophones/Struck Idiophones/Shaker, Small", "*Double_Down*.wav")],
            61: [S.vcsl_dir("Idiophones/Struck Idiophones/Shaker, Small", "*Double_Up*.wav")]})),
        "claves": S.ep("Claves (VSCO-2)", "claves", ("perc", {60: S.vsco_perc("Claves1_Hit")})),
    }


def guitar(p, bar0, prog, t=0, vel=62):
    """Thumb on 1 and 3 (root, fifth), the chord on the bossa's syncopation (2-bar cell: 0, 1.5, 3 | 1, 2.5)."""
    cell = [(0, 0), (0, 1.5), (0, 3), (1, 1), (1, 2.5)]
    for i in range(1, len(prog) + 1):
        b0 = B(bar0, i, BPB)
        for beat in (0, 2):
            sym = chord_at(prog, i, beat)
            r, pcs, bass, _ = chord(sym, t)
            m = place(bass if beat == 0 else pcs[2], n("D2"), n("D3"))
            add(p, b0 + beat, 1.6, m, vel + 6, swing=False, bpm=BPM)
        for which, beat in cell:
            if (i - 1) % 2 != which:
                continue
            sym = soft(chord_at(prog, i, beat))
            v = voicing(sym, t, lo=n("E3"), hi=n("C#4") + 2)[:4]
            for k, m in enumerate(v):
                add(p, b0 + beat + k * 0.008, 0.9, m, vel - 4 + p.rng.randint(-3, 3), swing=False, bpm=BPM)


def bass(p, bar0, prog, t=0, vel=82):
    for i, b, length, sym in spans(prog):
        b0 = B(bar0, i, BPB) + b
        r, pcs, bs, _ = chord(sym, t)
        root = place(bs, n("D1") + 2, n("D2") + 2)
        add(p, b0, min(1.5, length) * 0.9, root, vel, swing=False, bpm=BPM)
        if length >= 4:
            add(p, b0 + 2, 1.4, place(pcs[2], root - 5, root + 7), vel - 8, swing=False, bpm=BPM)


def kitchen(P, bar0, nbars, vel=1.0, congas=True, bongos=True, shaker=True, claves=True, fill_last=False):
    for i in range(1, nbars + 1):
        b0 = B(bar0, i, BPB)
        if shaker:
            for k in range(8):
                add(P["shaker"], b0 + k * 0.5, 0.3, 60 if k % 2 == 0 else 61, int((58 if k % 2 else 40) * vel), swing=False, bpm=BPM)
        if congas:
            for beat, m, v in [(1, 60, 34), (1.5, 63, 46), (3, 64, 58), (3.5, 64, 52)] + ([(2.5, 62, 40)] if i % 2 == 0 else []):
                add(P["congas"], b0 + beat, 0.4, m, int(v * vel), swing=False, bpm=BPM)
        if bongos:
            for k in range(8):
                m = 61 if k in (0, 4) else (62 if k == 7 else 60)
                add(P["bongos"], b0 + k * 0.5, 0.3, m, int((40 if k % 2 else 52) * vel), swing=False, bpm=BPM)
        if claves:
            for beat in ([0, 1.5, 3] if i % 2 == 1 else [1, 2.5]):
                add(P["claves"], b0 + beat, 0.3, 60, int(44 * vel), swing=False, bpm=BPM)
        if fill_last and i == nbars:
            for k, (beat, m) in enumerate([(2, 62), (2.5, 62), (3, 63), (3.25, 63), (3.5, 64), (3.75, 64)]):
                add(P["congas"], b0 + beat, 0.3, m, int((60 + 6 * k) * vel), swing=False, bpm=BPM)


def build():
    P = band()
    bar = 1
    # intro: guitar alone (2), then bass and the kitchen
    guitar(P["guitar"], bar, INTRO)
    bass(P["bass"], bar + 2, INTRO[2:])
    kitchen(P, bar + 2, 2, vel=0.8, bongos=False, fill_last=True)
    bar += 4
    # A1: the flute's tune
    line(P["flute"], bar, TUNE_A, vel=74, bpb=BPB, bpm=BPM)
    guitar(P["guitar"], bar, A); bass(P["bass"], bar, A); kitchen(P, bar, 8, bongos=False)
    bar += 8
    # A2: the tune again; the piano answers in its long notes
    line(P["flute"], bar, TUNE_A_END, vel=78, bpb=BPB, bpm=BPM)
    line(P["piano"], bar, ANSWERS, vel=58, bpb=BPB, bpm=BPM, swell=False)
    guitar(P["guitar"], bar, A_END); bass(P["bass"], bar, A_END); kitchen(P, bar, 8, fill_last=True)
    bar += 8
    # B: the bittersweet middle -- flute, the piano's chords pad underneath
    line(P["flute"], bar, TUNE_B, vel=70, bpb=BPB, bpm=BPM)
    for i, b, length, sym in spans(BR):
        for m in voicing(soft(sym), 0, lo=n("A3"), hi=n("F#4") + 2):
            add(P["piano"], B(bar, i, BPB) + b + 0.5, length - 0.6, m, 40, swing=False, bpm=BPM)
    guitar(P["guitar"], bar, BR, vel=58); bass(P["bass"], bar, BR); kitchen(P, bar, 8, vel=0.85, congas=True, bongos=False)
    bar += 8
    # A3: the piano sings the first half, the flute the second; the flute answers first
    first = {k: v for k, v in TUNE_A_END.items() if k <= 4}
    second = {k: v for k, v in TUNE_A_END.items() if k > 4}
    line(P["piano"], bar, first, vel=70, bpb=BPB, bpm=BPM, swell=False)
    line(P["flute"], bar, {2: [(2.5, .5, "F#5"), (3, .5, "A5"), (3.5, .5, "B5")], 4: [(2.5, .5, "A5"), (3, .5, "C#6"), (3.5, .5, "E6")]},
         vel=60, bpb=BPB, bpm=BPM, swell=False)
    line(P["flute"], bar, second, vel=80, bpb=BPB, bpm=BPM)
    guitar(P["guitar"], bar, A_END); bass(P["bass"], bar, A_END); kitchen(P, bar, 8)
    bar += 8
    # tag: the hook's last phrase twice, then home -- softer each time
    line(P["flute"], bar, TAG_TUNE, vel=72, bpb=BPB, bpm=BPM)
    guitar(P["guitar"], bar, TAG[:4], vel=56); bass(P["bass"], bar, TAG[:4]); kitchen(P, bar, 4, vel=0.75)
    end = B(bar, 5, BPB)
    for k, m in enumerate([n("D2"), n("A2"), n("F#3"), n("C#4"), n("E4"), n("A4")]):
        add(P["guitar"], end + k * 0.06, 4, m, 60, swing=False, bpm=BPM)
    for m in [n("D3"), n("A3"), n("C#4"), n("E4"), n("F#4")]:
        add(P["piano"], end + 0.75, 3.5, m, 44, swing=False, bpm=BPM)
    add(P["bass"], end, 3, n("D1") + 12, 80, swing=False, bpm=BPM)
    add(P["congas"], end, .4, 64, 50, swing=False, bpm=BPM)
    add(P["claves"], end + 0.75, .3, 60, 40, swing=False, bpm=BPM)
    total = end + 6
    return P, [(0, BPM)], total


# The listening combinations (who is on), in the order of the files.
COMBOS = [
    (["guitar"], "guitar alone (the bossa pattern)"),
    (["guitar", "bass", "congas", "shaker"], "rhythm - guitar, bass, congas, shaker"),
    (["guitar", "bass", "congas", "bongos", "shaker", "claves"], "rhythm + all the percussion"),
    (["flute", "guitar"], "flute and guitar (a duo)"),
    (["flute", "guitar", "bass", "shaker"], "flute with a small group"),
    (["flute", "piano", "guitar", "bass"], "no percussion"),
    (["congas", "bongos", "shaker", "claves"], "percussion alone"),
    (["flute"], "flute alone"),
]
LEVELS = {"flute": -19.5, "guitar": -22.0, "piano": -23.0, "bass": -21.0, "congas": -26.0, "bongos": -29.0, "shaker": -31.0, "claves": -32.0}
PAN = {"flute": 0.1, "guitar": -0.35, "piano": 0.3, "bass": 0.0, "congas": 0.45, "bongos": -0.5, "shaker": 0.6, "claves": -0.6}
ROOM = {"flute": 0.28, "guitar": 0.18, "piano": 0.22, "bass": 0.1, "congas": 0.18, "bongos": 0.18, "shaker": 0.2, "claves": 0.22}
SLUG = "C-bossa-Rua-das-Lampadas"
