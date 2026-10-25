"""HALLWAYS ORIGINALS -- "Rua das Lâmpadas", with singers (Oct 24). Bossa nova, D major, 140 bpm.

The instrumental audition (bossa.py), now with Hallenese singers written for it:
  Singer A (temporary: "the crooner")   the tune, an octave below the flute's register -- warm, low
  Singer B (temporary: "the soul voice") harmony: a chord tone below the written tune (a sixth above the crooner)
The flute no longer carries the verses: it answers in the singers' long notes and sings the bridge.
Every verse opens on the same syllables -- "ra-mi-do-re-na" -- the hook you can sing back.

LAB LOOP (32 bars, 54.9 s): verse 1 (crooner; flute answers) / verse 2 (crooner + harmony; piano answers)
  / bridge (flute; piano pads; the singers rest) / verse 3 (both singers; flute and piano answer).
PERFORMANCE (~1:28): intro / the flute states the tune / verse 1 / verse 2 with harmony / bridge /
  verse 3, home / the sung tag (x2) / the last chord.
"""
import sys
sys.path.insert(0, "/home/claude/lab"); sys.path.insert(0, "/home/claude/lab/genres")
from labkit import n, harm_below, voicing, chord
from common import B, line, chord_at, spans, add
import studio as S
import bossa as Bo

TITLE = "Rua das Lâmpadas"
SLUG = "C-bossa-vocal-Rua-das-Lampadas"
BPM = Bo.BPM
BPB = 4

WHO = ["lead", "harmony", "flute", "guitar", "piano", "bass", "congas", "bongos", "shaker", "claves"]

# Hallenese, one syllable a note (kana, as Sinsy sings them). Each verse opens on the hook: ra-mi-do-re-na.
V1 = {1: "らみどれな", 2: "そらり", 3: "まにとれな", 4: "そらみ", 5: "ぱりねらも", 6: "かりそね", 7: "るまそら", 8: "りでらみ"}
V2 = {1: "らみどれな", 2: "さらい", 3: "とにのれな", 4: "さらみ", 5: "ぱらねらも", 6: "かのそね", 7: "るまそら", 8: "りでらみ"}
V3_END = {1: "らみどれな", 2: "そらり", 3: "まにとれな", 4: "そらみ", 5: "ぱりねらも", 6: "かりそね", 7: "るまそら", 8: "あ"}
TAG_WORDS = {1: "らみどれな", 2: "そらみ", 3: "らみどれな", 4: "そらみ", 5: "あ"}

# the flute's answers in the singers' long notes (the piano's answers, an octave up)
FLUTE_ANS = {k: [(b, d, nm[:-1] + str(int(nm[-1]) + 1)) for b, d, nm in v] for k, v in Bo.ANSWERS.items()}


def singers():
    return {
        "lead": S.voice_part("Singer A (temporary) -- Hallenese lead, the crooner", "lead",
                             {"shift": -12, "formant": 0.80, "breath": 0.22, "vib": 22, "fall": True}),
        "harmony": S.voice_part("Singer B (temporary) -- Hallenese harmony, the soul voice", "harmony",
                                {"shift": 0, "breath": 0.10, "vib": 18, "fall": False}),
    }


def sing(p, bar0, mel, words, octave=0, vel=80):
    for bar, notes in mel.items():
        syl = words[bar]
        assert len(syl) == len(notes), (bar, syl, notes)
        for (beat, dur, name), k in zip(notes, syl):
            S.sing_note(p, B(bar0, bar, BPB) + beat, dur, n(name) + 12 * octave, k, vel)


def sing_harmony(p, bar0, mel, words, prog, vel=74):
    """A chord tone below each written note, at the written octave -- never one a half-step from another
    tone of the chord (the guitar plays them: no D against the maj7's C#)."""
    for bar, notes in mel.items():
        syl = words[bar]
        for (beat, dur, name), k in zip(notes, syl):
            sym = Bo.soft(chord_at(prog, bar, beat))
            r, pcs, _, _ = chord(sym)
            safe = [pc for pc in pcs if not any((pc - q) % 12 in (1, 11) for q in pcs)] or pcs
            lead = n(name)
            h = next(m for m in range(lead - 3, lead - 13, -1) if m % 12 in safe)
            S.sing_note(p, B(bar0, bar, BPB) + beat, dur, h, k, vel)


def band():
    P = Bo.band()
    P.update(singers())
    return P


def rhythm(P, bar0, prog, nbars=8, **kw):
    Bo.guitar(P["guitar"], bar0, prog)
    Bo.bass(P["bass"], bar0, prog)
    Bo.kitchen(P, bar0, nbars, **kw)


def pads(P, bar0, prog, vel=40):
    for i, b, length, sym in spans(prog):
        for m in voicing(Bo.soft(sym), 0, lo=n("A3"), hi=n("F#4") + 2):
            add(P["piano"], B(bar0, i, BPB) + b + 0.5, length - 0.6, m, vel, bpm=BPM)


def build_loop():
    P = band()
    bar = 1
    # verse 1: the crooner; the flute answers
    sing(P["lead"], bar, Bo.TUNE_A, V1, octave=-1)
    line(P["flute"], bar, FLUTE_ANS, vel=60, bpb=BPB, bpm=BPM, swell=False)
    rhythm(P, bar, Bo.A, bongos=False)
    bar += 8
    # verse 2: the harmony singer joins; the piano answers
    sing(P["lead"], bar, Bo.TUNE_A, V2, octave=-1)
    sing_harmony(P["harmony"], bar, Bo.TUNE_A, V2, Bo.A)
    line(P["piano"], bar, Bo.ANSWERS, vel=58, bpb=BPB, bpm=BPM, swell=False)
    rhythm(P, bar, Bo.A, fill_last=True)
    bar += 8
    # bridge: the flute sings; piano pads; the singers breathe
    line(P["flute"], bar, Bo.TUNE_B, vel=72, bpb=BPB, bpm=BPM)
    pads(P, bar, Bo.BR)
    rhythm(P, bar, Bo.BR, bongos=False, vel=0.85)
    bar += 8
    # verse 3: both singers; flute (2, 4) and piano (6, 8) answer; turns back to the top
    sing(P["lead"], bar, Bo.TUNE_A, V1, octave=-1)
    sing_harmony(P["harmony"], bar, Bo.TUNE_A, V1, Bo.A)
    line(P["flute"], bar, {k: v for k, v in FLUTE_ANS.items() if k <= 4}, vel=60, bpb=BPB, bpm=BPM, swell=False)
    line(P["piano"], bar, {k: v for k, v in Bo.ANSWERS.items() if k > 4}, vel=58, bpb=BPB, bpm=BPM, swell=False)
    rhythm(P, bar, Bo.A)
    return P, [(0, BPM)], 32 * BPB


def build_performance():
    P = band()
    bar = 1
    # intro: guitar alone, then bass and the kitchen
    Bo.guitar(P["guitar"], bar, Bo.INTRO)
    Bo.bass(P["bass"], bar + 2, Bo.INTRO[2:])
    Bo.kitchen(P, bar + 2, 2, vel=0.8, bongos=False, fill_last=True)
    bar += 4
    # the flute states the tune
    line(P["flute"], bar, Bo.TUNE_A, vel=74, bpb=BPB, bpm=BPM)
    rhythm(P, bar, Bo.A, bongos=False)
    bar += 8
    # verse 1: the crooner; the flute answers
    sing(P["lead"], bar, Bo.TUNE_A, V1, octave=-1)
    line(P["flute"], bar, FLUTE_ANS, vel=58, bpb=BPB, bpm=BPM, swell=False)
    rhythm(P, bar, Bo.A, bongos=False)
    bar += 8
    # verse 2: with harmony; the piano answers
    sing(P["lead"], bar, Bo.TUNE_A, V2, octave=-1)
    sing_harmony(P["harmony"], bar, Bo.TUNE_A, V2, Bo.A)
    line(P["piano"], bar, Bo.ANSWERS, vel=58, bpb=BPB, bpm=BPM, swell=False)
    rhythm(P, bar, Bo.A, fill_last=True)
    bar += 8
    # bridge: flute
    line(P["flute"], bar, Bo.TUNE_B, vel=72, bpb=BPB, bpm=BPM)
    pads(P, bar, Bo.BR)
    rhythm(P, bar, Bo.BR, bongos=False, vel=0.85)
    bar += 8
    # verse 3, home: both singers, the ending phrase
    sing(P["lead"], bar, Bo.TUNE_A_END, V3_END, octave=-1)
    sing_harmony(P["harmony"], bar, Bo.TUNE_A_END, V3_END, Bo.A_END)
    line(P["flute"], bar, {k: v for k, v in FLUTE_ANS.items() if k <= 4}, vel=58, bpb=BPB, bpm=BPM, swell=False)
    line(P["piano"], bar, {6: Bo.ANSWERS[6]}, vel=56, bpb=BPB, bpm=BPM, swell=False)
    rhythm(P, bar, Bo.A_END)
    bar += 8
    # the tag: the hook sung twice, softer; then the last chord, held by the singers
    sing(P["lead"], bar, Bo.TAG_TUNE, TAG_WORDS, octave=-1, vel=74)
    sing_harmony(P["harmony"], bar, Bo.TAG_TUNE, TAG_WORDS, Bo.TAG, vel=68)
    Bo.guitar(P["guitar"], bar, Bo.TAG[:4], vel=56); Bo.bass(P["bass"], bar, Bo.TAG[:4]); Bo.kitchen(P, bar, 4, vel=0.75)
    end = B(bar, 5, BPB)
    for k, m in enumerate([n("D2"), n("A2"), n("F#3"), n("C#4"), n("E4"), n("A4")]):
        add(P["guitar"], end + k * 0.06, 4, m, 60, bpm=BPM)
    for m in [n("D3"), n("A3"), n("C#4"), n("E4"), n("F#4")]:
        add(P["piano"], end + 0.75, 3.5, m, 44, bpm=BPM)
    add(P["flute"], end + 1, 3, n("A5"), 52, bpm=BPM)
    add(P["bass"], end, 3, n("D2"), 80, bpm=BPM)
    add(P["congas"], end, .4, 64, 50, bpm=BPM)
    add(P["claves"], end + 0.75, .3, 60, 40, bpm=BPM)
    return P, [(0, BPM)], end + 6


# for the lab: who each tile is (temporary identities for the singers -- see README)
LAB = {
    "id": "rua-das-lampadas", "title": "Rua das Lâmpadas", "subtitle": "Hallways Originals #5 · with singers",
    "genre": "Bossa nova", "order": 3, "bpm": 140, "beatsPerBar": 4,
    "parts": {
        "lead": ("Singer A", "lead vocal (temporary)", "#C8553D"),
        "harmony": ("Singer B", "harmony vocal (temporary)", "#B0517E"),
        "flute": ("Flute", "flute", "#3C7DBF"),
        "guitar": ("Guitar", "nylon-string guitar", "#9C5B3B"),
        "piano": ("Piano", "grand piano", "#2E8B6E"),
        "bass": ("Bass", "double bass", "#5B4B8A"),
        "congas": ("Congas", "congas", "#D49A2A"),
        "bongos": ("Bongos", "bongos", "#C27A2C"),
        "shaker": ("Shaker", "shaker", "#8A9BA8"),
        "claves": ("Claves", "claves", "#6E7F8D"),
    },
}
LEVELS = {"lead": -19.0, "harmony": -22.0, "flute": -21.0, "guitar": -22.0, "piano": -23.5, "bass": -21.0,
          "congas": -26.0, "bongos": -29.0, "shaker": -31.0, "claves": -32.0}
PAN = {"lead": 0.0, "harmony": 0.22, "flute": 0.3, "guitar": -0.35, "piano": 0.4, "bass": 0.0, "congas": 0.45, "bongos": -0.5, "shaker": 0.6, "claves": -0.6}
ROOM = {"lead": 0.22, "harmony": 0.24, "flute": 0.28, "guitar": 0.18, "piano": 0.22, "bass": 0.1, "congas": 0.18, "bongos": 0.18, "shaker": 0.2, "claves": 0.22}
RT = 1.6
LAB_COMBOS = [
    (["lead"], "Singer A alone"),
    (["lead", "harmony"], "the two singers"),
    (["lead", "guitar"], "Singer A and the guitar"),
    (["lead", "guitar", "bass", "shaker"], "Singer A with a small group"),
    (["lead", "harmony", "guitar", "bass", "congas", "shaker"], "both singers with the rhythm section"),
    (["flute", "guitar", "piano", "bass", "congas", "bongos", "shaker", "claves"], "the band, no singers"),
]
