"""HALLWAYS ORIGINALS #1 -- "The Night Shift Waltz" (working title).

An original jazz waltz for four Hallwaysians, composed for the Music Lab.

  Juanita  lead melody            clarinet          (GM 71)
  Tinky    rhythm / tin + kalimba kalimba (GM 108) + mute triangle, shaker,
                                  open triangle (GM drum kit, channel 10)
  Gloria   bass                   acoustic (upright) bass (GM 32)
  Eileen   harmony / countermelody nylon-string guitar (GM 24)

3/4, 120 bpm (one bar = 1.5 s), A minor.

ONE COMPOSITION, TWO FORMS, ONE MATERIAL:
  LOOP (the lab's switchable version) -- 48 bars, 72 s, seamless:
      A  (16)  the theme, Eileen comping and answering Juanita's phrase ends
      B  (16)  the bridge, in the relative major (C/F), the bass walking
      A' (16)  the theme varied, new answers; its last bar turns back to A
  PERFORMANCE (the finished version) -- 85 bars, about 2:15:
      Intro (8)        Tinky alone, then Gloria
      A1 (16)          Juanita's theme over bass and kalimba
      A2 (16)          Eileen arrives: comping, answering Juanita
      B  (16)          roles swap: Eileen sings the bridge on guitar while
                       Juanita plays a slow descending line underneath
      Interlude (8)    a conversation: two bars each, Juanita / Eileen
      A3 (12)          the theme returns, walking bass, Tinky's fills
      Coda (9)         the tag twice (a deceptive cadence the first time),
                       slowing, ending on a held A minor (add 9)

Harmony (A): Am | Am/G | Fmaj7 | E7 | Am | Am/G | D9 | Fmaj7 |
             Dm7 | G7 | Cmaj7 | Fmaj7#11 | Bm7b5 | E7 | Am | E7
         (B): Fmaj7 | G6 | Em7 | Am7 | Dm7 | G7 | Cmaj7 | C7 |
             Fmaj7 | Fm6 | Em7 | A7 | Dm7 | G7 | Esus4 | E7
The A section opens on the old descending "lament" bass (A G F E), a
centuries-old idiom; the melody, countermelody, bass lines, kalimba figures and
the arrangement are new for Hallways.

Rendering: FluidSynth with the FluidR3_GM General MIDI sound library (Frank
Wen, MIT licence) -- every part rendered separately on one timeline.
"""
import json
import os
import random
import subprocess
import sys
import wave

import numpy as np
import mido
import fluidsynth

SR = 44100
BPB = 3                       # beats per bar
BPM = 120.0
TPB = 480
SF2 = "/usr/share/sounds/sf2/FluidR3_GM.sf2"
SWING = 0.06                  # off-beat eighths a touch late (beats)
rng = random.Random(24)

NAMES = {"C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5, "F#": 6, "Gb": 6,
         "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11}


def n(name):
    return 12 * (int(name[-1]) + 1) + NAMES[name[:-1]]


# ------------------------------------------------------------------ harmony
#   bass root, bass second note (beat 3 of the waltz), chord third (walking),
#   guitar voicing (Eileen's comp), kalimba tones low -> high (Tinky)
CH = {
    "Am":       ("A1", "E2", "C2", ["E3", "A3", "C4", "E4"], ["A4", "C5", "E5", "A5", "B5", "E6"]),
    "Am/G":     ("G1", "E2", "C2", ["E3", "G3", "C4", "E4"], ["G4", "C5", "E5", "A5", "C6", "E6"]),
    "Fmaj7":    ("F1", "C2", "A1", ["F3", "A3", "C4", "E4"], ["F4", "A4", "E5", "G5", "A5", "E6"]),
    "E7":       ("E1", "B1", "G#1", ["E3", "G#3", "B3", "D4"], ["B4", "D5", "E5", "G#5", "B5", "E6"]),
    "D9":       ("D2", "A2", "F#2", ["F#3", "C4", "E4"], ["A4", "C5", "E5", "F#5", "A5", "E6"]),
    "Dm7":      ("D2", "A2", "F2", ["F3", "A3", "C4", "D4"], ["A4", "C5", "D5", "F5", "A5", "D6"]),
    "G7":       ("G1", "D2", "B1", ["F3", "B3", "D4", "G4"], ["B4", "D5", "F5", "G5", "B5", "D6"]),
    "Cmaj7":    ("C2", "G2", "E2", ["E3", "G3", "B3", "D4"], ["G4", "B4", "E5", "G5", "B5", "D6"]),
    "Fmaj7#11": ("F1", "C2", "A1", ["F3", "A3", "C4", "E4"], ["F4", "A4", "E5", "G5", "A5", "E6"]),   # (the #11 is the melody's alone)
    "Bm7b5":    ("B1", "F2", "D2", ["F3", "A3", "B3", "D4"], ["A4", "B4", "D5", "F5", "A5", "D6"]),
    "G6":       ("G1", "D2", "B1", ["G3", "B3", "D4", "E4"], ["B4", "D5", "E5", "G5", "B5", "E6"]),
    "Em7":      ("E1", "B1", "G1", ["G3", "B3", "D4", "E4"], ["B4", "D5", "E5", "G5", "B5", "D6"]),
    "Am7":      ("A1", "E2", "C2", ["G3", "A3", "C4", "E4"], ["A4", "C5", "E5", "G5", "A5", "E6"]),
    "C7":       ("C2", "G2", "E2", ["E3", "Bb3", "C4", "G4"], ["Bb4", "C5", "E5", "G5", "Bb5", "E6"]),
    "Fm6":      ("F1", "C2", "Ab1", ["F3", "Ab3", "C4", "D4"], ["Ab4", "C5", "D5", "F5", "Ab5", "D6"]),
    "A7":       ("A1", "E2", "C#2", ["G3", "C#4", "E4", "A4"], ["A4", "C#5", "E5", "G5", "A5", "E6"]),
    "Esus4":    ("E1", "B1", "A1", ["E3", "A3", "B3", "E4"], ["A4", "B4", "E5", "A5", "B5", "E6"]),
    "Am9":      ("A1", "E2", "C2", ["A3", "C4", "G4", "B4"], ["A4", "C5", "E5", "G5", "A5", "B5"]),
}
PROG_A = ["Am", "Am/G", "Fmaj7", "E7", "Am", "Am/G", "D9", "Fmaj7",
          "Dm7", "G7", "Cmaj7", "Fmaj7#11", "Bm7b5", "E7", "Am", "E7"]
PROG_B = ["Fmaj7", "G6", "Em7", "Am7", "Dm7", "G7", "Cmaj7", "C7",
          "Fmaj7", "Fm6", "Em7", "A7", "Dm7", "G7", "Esus4", "E7"]
PROG_LAMENT = ["Am", "Am/G", "Fmaj7", "E7"] * 2
PROG_A3 = PROG_A[:12]
PROG_CODA = ["Bm7b5", "E7", "Am", "Fmaj7#11", "Bm7b5", "E7", "Am9", "Am9", "Am9"]

# ------------------------------------------------------------------ melodies (bar -> [(beat, dur, note)])
A_MEL = {1: [(1, 1, "E4"), (2, 1, "A4")], 2: [(0, 3, "C5")], 3: [(0, 2, "A4"), (2, 1, "B4")], 4: [(0, 3, "G#4")],
         5: [(1, 1, "E4"), (2, 1, "A4")], 6: [(0, 1, "C5"), (1, 2, "E5")], 7: [(0, 2, "F#5"), (2, 1, "E5")], 8: [(0, 3, "C5")],
         9: [(1, 1, "D5"), (2, 1, "F5")], 10: [(0, 2, "A5"), (2, 1, "G5")], 11: [(0, 3, "E5")], 12: [(1, 1, "B4"), (2, 1, "C5")],
         13: [(0, 2, "D5"), (2, 1, "F5")], 14: [(0, 1, "E5"), (1, 1, "D5"), (2, 1, "B4")], 15: [(0, 3, "A4")], 16: []}
A2_MEL = dict(A_MEL)
A2_MEL.update({2: [(0, 1.5, "C5"), (1.5, 0.5, "D5"), (2, 1, "C5")],
               7: [(0, 1, "F#5"), (1, 1, "A5"), (2, 1, "E5")],
               11: [(0, 2, "E5"), (2, 0.5, "D5"), (2.5, 0.5, "E5")],
               14: [(0, 1, "E5"), (1, 0.5, "D5"), (1.5, 0.5, "B4"), (2, 1, "G#4")]})
B_MEL = {1: [(0, 2, "A4"), (2, 1, "C5")], 2: [(0, 3, "E5")], 3: [(0, 1, "D5"), (1, 1, "B4"), (2, 1, "G4")], 4: [(0, 3, "C5")],
         5: [(0, 2, "A4"), (2, 1, "D5")], 6: [(0, 2, "F5"), (2, 1, "E5")], 7: [(0, 1, "E5"), (1, 1, "D5"), (2, 1, "B4")], 8: [(0, 3, "Bb4")],
         9: [(0, 2, "A4"), (2, 1, "C5")], 10: [(0, 3, "Ab4")], 11: [(0, 2, "G4"), (2, 1, "B4")], 12: [(0, 2, "C#5"), (2, 1, "E5")],
         13: [(0, 2, "F5"), (2, 1, "D5")], 14: [(0, 1, "C5"), (1, 2, "B4")], 15: [(0, 3, "A4")], 16: [(0, 2, "G#4"), (2, 1, "B4")]}
# Juanita under Eileen's bridge (performance B): a slow line falling by half steps
B_UNDER = ["E4", "E4", "D4", "C4", "C4", "B3", "B3", "Bb3", "A3", "Ab3", "G3", "G3", "F3", "F3", "E3", "G#3"]
# Eileen's answers in the gaps of Juanita's phrases (bar -> notes)
ANS_A = {4: [(1, 0.5, "B4"), (1.5, 0.5, "D5"), (2, 1, "E5")], 8: [(1, 0.5, "A4"), (1.5, 0.5, "G4"), (2, 1, "F4")],
         11: [(1, 0.5, "G4"), (1.5, 0.5, "A4"), (2, 1, "B4")],
         16: [(0, 1, "B4"), (1, 0.5, "A4"), (1.5, 0.5, "G#4"), (2, 1, "D4")]}
ANS_A2 = {4: [(1, 0.5, "E5"), (1.5, 0.5, "D5"), (2, 1, "B4")], 8: [(1, 0.5, "C5"), (1.5, 0.5, "A4"), (2, 1, "G4")],
          12: [(0, 1, "A4")],
          16: [(0, 0.5, "E4"), (0.5, 0.5, "G#4"), (1, 0.5, "B4"), (1.5, 0.5, "D5"), (2, 1, "B4")]}
ANS_B = {4: [(1, 0.5, "E4"), (1.5, 0.5, "G4"), (2, 1, "A4")], 8: [(1, 0.5, "G4"), (1.5, 0.5, "E4"), (2, 1, "C4")]}
# The interlude's conversation (bars 1-8): Juanita, Eileen, Juanita, Eileen -- two bars each
TALK_J = {1: [(0, 0.5, "A4"), (0.5, 0.5, "B4"), (1, 1, "C5"), (2, 1, "E5")], 2: [(0, 1.5, "D5"), (1.5, 0.5, "C5"), (2, 1, "B4")],
          5: [(0, 0.5, "E5"), (0.5, 0.5, "F5"), (1, 1, "E5"), (2, 1, "C5")], 6: [(0, 1.5, "B4"), (1.5, 0.5, "C5"), (2, 1, "D5")]}
TALK_E = {3: [(0, 0.5, "C5"), (0.5, 0.5, "B4"), (1, 1, "A4"), (2, 1, "C5")], 4: [(0, 1.5, "B4"), (1.5, 0.5, "A4"), (2, 1, "G#4")],
          7: [(0, 1, "C5"), (1, 1, "A4"), (2, 1, "F4")], 8: [(0, 1, "E4"), (1, 1, "G#4"), (2, 1, "B4")]}
CODA_J = {1: [(0, 2, "F5"), (2, 1, "D5")], 2: [(0, 1, "D5"), (1, 1, "B4"), (2, 1, "G#4")], 3: [(0, 3, "A4")],
          5: [(0, 2, "D5"), (2, 1, "F5")], 6: [(0, 1, "E5"), (1, 1, "D5"), (2, 1, "B4")], 7: [(0, 9, "A4")]}
CODA_E_ANS = {4: [(0, 1, "B4"), (1, 1, "C5"), (2, 1, "E5")]}


# ------------------------------------------------------------------ parts
class Part:
    def __init__(self, name, who, program, channel, vol, pan, reverb):
        self.name, self.who, self.program, self.channel = name, who, program, channel
        self.vol, self.pan, self.reverb = vol, pan, reverb
        self.notes = []            # (beat, dur, midi, vel)
        self.cc = []               # (beat, controller, value)

    def add(self, beat, dur, note, vel, swing=True, jitter_ms=6):
        b = beat
        frac = b - int(b)
        if swing and abs(frac - 0.5) < 1e-6:
            b += SWING
        b += rng.uniform(-jitter_ms, jitter_ms) / 1000 * BPM / 60
        self.notes.append((max(0.0, b), dur, n(note) if isinstance(note, str) else note, max(1, min(127, int(vel)))))


def new_parts():
    return {
        "juanita": [Part("Juanita -- clarinet (melody)", "juanita", 71, 0, 100, 50, 52)],
        "eileen": [Part("Eileen -- nylon guitar (harmony, countermelody)", "eileen", 24, 1, 104, 80, 46)],
        "gloria": [Part("Gloria -- upright bass", "gloria", 32, 2, 112, 64, 26)],
        "tinky": [Part("Tinky -- kalimba", "tinky", 108, 3, 96, 72, 58),
                  Part("Tinky -- tin percussion", "tinky", 0, 9, 84, 58, 34)],
    }


def melody(p, bar0, mel, vel=78, phrase_lift=True, swell=True):
    """Juanita's line: phrase arcs (louder toward each phrase's top), breath swells on held notes."""
    for bar, notes in mel.items():
        for beat, dur, note in notes:
            b = (bar0 + bar - 2) * BPB + beat
            arc = 6 * np.sin(np.pi * (((bar - 1) % 4) + beat / 3) / 4) if phrase_lift else 0
            v = vel + arc + rng.randint(-3, 3) + (4 if dur >= 2 else 0)
            p.add(b, dur * 0.97, note, v)
            if swell and p.channel == 0:
                if dur >= 1.5:
                    p.cc += [(b, 11, 86), (b + dur * 0.4, 11, 112), (b + dur * 0.92, 11, 94), (b + 0.35, 1, 22), (b + dur * 0.95, 1, 0)]
                else:
                    p.cc += [(b, 11, 102)]


def guitar_line(p, bar0, mel, vel=70):
    for bar, notes in mel.items():
        for beat, dur, note in notes:
            p.add((bar0 + bar - 2) * BPB + beat, dur * 0.95, note, vel + rng.randint(-4, 4))


def comp(p, bar0, prog, skip=(), vel=44, strum=0.018):
    """Eileen's waltz comp: the chord on beats 2 and 3 ("oom-PAH-PAH" with Gloria's oom)."""
    for i, ch in enumerate(prog, start=1):
        if i in skip:
            continue
        voicing = CH[ch][3]
        for beat, v in [(1, vel), (2, vel - 6)]:
            for k, note in enumerate(voicing):
                p.add((bar0 + i - 2) * BPB + beat + k * strum, 0.8, note, v + rng.randint(-3, 3), swing=False, jitter_ms=4)


def waltz_bass(p, bar0, prog, walk_into=True, vel=80):
    """Gloria: the root on 1, a chord tone on 3; at phrase ends a step toward the next root."""
    for i, ch in enumerate(prog, start=1):
        root, second, third = CH[ch][0], CH[ch][1], CH[ch][2]
        b = (bar0 + i - 2) * BPB
        p.add(b, 1.7, root, vel + rng.randint(-3, 3), swing=False)
        nxt = prog[i] if i < len(prog) else prog[0]
        if walk_into and i % 4 == 0:
            target = n(CH[nxt][0])
            p.add(b + 1, 0.9, third, vel - 18, swing=False)
            p.add(b + 2, 0.9, target + (1 if target + 1 <= n("D3") else -1), vel - 14, swing=False)
        else:
            p.add(b + 2, 0.9, second, vel - 16, swing=False)


def walking_bass(p, bar0, prog, vel=76):
    """Gloria walks: root, a chord tone, then a half step into the next root."""
    for i, ch in enumerate(prog, start=1):
        root, second, third = n(CH[ch][0]), n(CH[ch][1]), n(CH[ch][2])
        nxt = n(CH[prog[i] if i < len(prog) else prog[0]][0])
        b = (bar0 + i - 2) * BPB
        mid = third if i % 2 else second
        approach = nxt - 1 if (nxt - 1) != mid and abs(nxt - 1 - mid) <= abs(nxt + 1 - mid) else nxt + 1
        for k, (note, v) in enumerate([(root, vel), (mid, vel - 14), (approach, vel - 10)]):
            p.add(b + k, 0.92, note, v + rng.randint(-3, 3), swing=False)


KAL, PERC = 0, 1
MUTE_TRI, OPEN_TRI, SHAKER, WOOD = 80, 81, 82, 76


def tinky(parts, bar0, prog, style="p1", shaker=False, first_open=True, fills=(), vel=50):
    kal, perc = parts[KAL], parts[PERC]
    for i, ch in enumerate(prog, start=1):
        t = [n(x) for x in CH[ch][4]]
        b = (bar0 + i - 2) * BPB
        if style == "p1":
            if i % 2 == 1:
                kal.add(b, 0.6, t[0], vel - 12)
            for beat, idx, dv in [(0.5, 2, 2), (1.5, 1, -4), (2.0, 3, 0), (2.5, 2, -6)]:
                kal.add(b + beat, 0.45, t[idx], vel + dv + rng.randint(-4, 3))
            perc.add(b + 1, 0.2, MUTE_TRI, 38 + rng.randint(-3, 3), swing=False)
            perc.add(b + 2, 0.2, MUTE_TRI, 32 + rng.randint(-3, 3), swing=False)
        elif style == "p2":
            kal.add(b, 0.9, t[1], vel - 6 + rng.randint(-3, 3))
            kal.add(b + 1.5, 0.9, t[3], vel - 2 + rng.randint(-3, 3))
            if i % 2 == 1:
                perc.add(b, 0.3, MUTE_TRI, 36, swing=False)
            if i % 8 == 0:
                kal.add(b + 2.5, 0.5, t[5], vel - 8)
        elif style == "talk":
            if i % 4 == 1:
                kal.add(b, 1.0, t[3], vel - 10)
                perc.add(b, 0.3, OPEN_TRI, 24, swing=False)
        if shaker:
            for e in range(6):
                perc.add(b + e * 0.5, 0.15, SHAKER, (24 if e == 0 else 17 if e % 2 == 0 else 11) + rng.randint(-2, 2))
        if first_open and i == 1:
            perc.add(b, 0.5, OPEN_TRI, 30, swing=False)
        if i in fills:
            for k, idx in enumerate([1, 2, 3, 4, 5]):
                kal.add(b + 0.5 + k * 0.5, 0.4, t[idx], vel - 4 + k * 2)


# ------------------------------------------------------------------ the two forms
LOOP_BARS = 48


def build_loop():
    P = new_parts()
    j, e, g = P["juanita"][0], P["eileen"][0], P["gloria"][0]
    # A
    melody(j, 1, A_MEL)
    comp(e, 1, PROG_A, skip=ANS_A.keys())
    guitar_line(e, 1, ANS_A)
    waltz_bass(g, 1, PROG_A)
    tinky(P["tinky"], 1, PROG_A, "p1")
    # B
    melody(j, 17, B_MEL)
    comp(e, 17, PROG_B, skip=ANS_B.keys(), vel=40)
    guitar_line(e, 17, ANS_B, vel=64)
    walking_bass(g, 17, PROG_B)
    tinky(P["tinky"], 17, PROG_B, "p2")
    # A'
    melody(j, 33, A2_MEL)
    comp(e, 33, PROG_A, skip=ANS_A2.keys())
    guitar_line(e, 33, ANS_A2)
    waltz_bass(g, 33, PROG_A)
    tinky(P["tinky"], 33, PROG_A, "p1", shaker=True)
    return P, [(0, BPM)], LOOP_BARS * BPB


def build_performance():
    P = new_parts()
    j, e, g = P["juanita"][0], P["eileen"][0], P["gloria"][0]
    T = P["tinky"]
    bar = 1
    # Intro (8): Tinky alone, then Gloria
    tinky(T, bar, PROG_LAMENT, "p1", vel=44)
    waltz_bass(g, bar + 4, PROG_LAMENT[4:], walk_into=True, vel=74)
    bar += 8
    # A1 (16): Juanita's theme
    melody(j, bar, A_MEL, vel=76)
    waltz_bass(g, bar, PROG_A)
    tinky(T, bar, PROG_A, "p1", vel=48)
    bar += 16
    # A2 (16): Eileen arrives -- comping, answering
    melody(j, bar, A2_MEL, vel=80)
    comp(e, bar, PROG_A, skip=ANS_A.keys())
    guitar_line(e, bar, ANS_A)
    waltz_bass(g, bar, PROG_A)
    tinky(T, bar, PROG_A, "p1", shaker=True, vel=50)
    bar += 16
    # B (16): Eileen sings the bridge; Juanita's slow falling line beneath
    guitar_line(e, bar, B_MEL, vel=80)
    for i, note in enumerate(B_UNDER, start=1):
        if i > 1 and B_UNDER[i - 2] == note:
            continue                                        # (tied to the bar before)
        span = 1
        while i - 1 + span < len(B_UNDER) and B_UNDER[i - 1 + span] == note:
            span += 1
        melody(j, bar + i - 1, {1: [(0, 3 * span, note)]}, vel=60, phrase_lift=False)
    walking_bass(g, bar, PROG_B, vel=74)
    tinky(T, bar, PROG_B, "p2", vel=48)
    bar += 16
    # Interlude (8): the conversation
    melody(j, bar, TALK_J, vel=80)
    guitar_line(e, bar, TALK_E, vel=78)
    for i, ch in enumerate(PROG_LAMENT, start=1):
        g.add((bar + i - 2) * BPB, 2.7, CH[ch][0], 70, swing=False)
    tinky(T, bar, PROG_LAMENT, "talk", first_open=False, vel=46)
    bar += 8
    # A3 (12): the return -- walking bass, Tinky's fills
    melody(j, bar, {k: v for k, v in A2_MEL.items() if k <= 12}, vel=84)
    comp(e, bar, PROG_A3, skip=[4, 8, 11], vel=46)
    guitar_line(e, bar, {k: v for k, v in ANS_A2.items() if k <= 12} | {11: ANS_A[11]}, vel=72)
    walking_bass(g, bar, PROG_A3, vel=80)
    tinky(T, bar, PROG_A3, "p1", shaker=True, fills=(8,), vel=54)
    bar += 12
    # Coda (9): the tag twice -- a deceptive turn, then home, slowing
    coda0 = bar
    melody(j, bar, CODA_J, vel=80)
    comp(e, bar, PROG_CODA[:6], skip=[4], vel=44)
    guitar_line(e, bar, CODA_E_ANS, vel=72)
    for k, note in enumerate(CH["Am9"][3] + ["A4"]):                 # the last chord, rolled slowly
        e.add((bar + 5) * BPB + k * 0.12, 8.0, note, 56 - k * 2, swing=False, jitter_ms=0)
    waltz_bass(g, bar, PROG_CODA[:6], walk_into=False, vel=76)
    g.add((bar + 5) * BPB, 8.5, "A1", 74, swing=False, jitter_ms=0)
    tinky(T, bar, PROG_CODA[:4], "p1", vel=48)
    tinky(T, bar + 4, PROG_CODA[4:6], "p2", first_open=False, vel=44)
    kal = T[KAL]
    for k, note in enumerate(["A4", "E5", "A5", "B5"]):
        kal.add((bar + 5) * BPB + k * 0.5, 2.5, note, 48 - k * 2, swing=False, jitter_ms=0)
    kal.add((bar + 6) * BPB + 1, 3.0, "A5", 42, swing=False, jitter_ms=0)
    T[PERC].add((bar + 6) * BPB + 1, 1.0, OPEN_TRI, 26, swing=False, jitter_ms=0)
    bar += 9
    total_beats = (bar - 1) * BPB
    # the ending slows: from the second tag on
    c = (coda0 - 1) * BPB
    tempo = [(0, BPM), (c + 12, 114), (c + 13.5, 108), (c + 15, 100), (c + 16.5, 92), (c + 18, 84)]
    return P, tempo, total_beats


# ------------------------------------------------------------------ MIDI and rendering
def midi_for(parts, tempo, total_beats, repeats=1, name="Hallways Originals #1 -- The Night Shift Waltz"):
    mid = mido.MidiFile(type=1, ticks_per_beat=TPB)
    meta = mido.MidiTrack()
    meta.append(mido.MetaMessage("track_name", name=name, time=0))
    meta.append(mido.MetaMessage("time_signature", numerator=3, denominator=4, time=0))
    meta.append(mido.MetaMessage("key_signature", key="Am", time=0))
    ev = []
    for k in range(repeats):
        for b, bpm in tempo:
            ev.append((int(round((b + k * total_beats) * TPB)), mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(bpm), time=0)))
    ev.sort(key=lambda x: x[0])
    last = 0
    for t, m in ev:
        meta.append(m.copy(time=t - last))
        last = t
    mid.tracks.append(meta)
    for p in parts:
        mt = mido.MidiTrack()
        mt.append(mido.MetaMessage("track_name", name=p.name, time=0))
        e = []
        if p.channel != 9:
            e.append((0, 0, mido.Message("program_change", program=p.program, channel=p.channel)))
        for cc, val in [(7, p.vol), (10, p.pan), (91, p.reverb), (93, 0), (11, 104 if p.channel == 0 else 116)]:
            e.append((0, 0, mido.Message("control_change", control=cc, value=val, channel=p.channel)))
        for k in range(repeats):
            off = k * total_beats
            for b, c, v in p.cc:
                e.append((int(round((min(b, total_beats - 0.01) + off) * TPB)), 0,
                          mido.Message("control_change", control=c, value=v, channel=p.channel)))
            for s, d, note, vel in p.notes:
                on = int(round((s + off) * TPB))
                end = (min(s + d, total_beats) if repeats > 1 else s + d) + off
                e.append((on, 1, mido.Message("note_on", note=note, velocity=vel, channel=p.channel)))
                e.append((max(on + 10, int(round(end * TPB))), 0, mido.Message("note_off", note=note, velocity=0, channel=p.channel)))
        e.sort(key=lambda x: (x[0], x[1]))
        last = 0
        for t, _, m in e:
            mt.append(m.copy(time=t - last))
            last = t
        mid.tracks.append(mt)
    return mid


def seconds_of(tempo, beats):
    s, t = 0.0, 0.0
    marks = sorted(tempo) + [(float("inf"), None)]
    for (b0, bpm), (b1, _) in zip(marks, marks[1:]):
        if beats <= b0:
            break
        seg = min(beats, b1) - b0
        s += seg * 60 / bpm
    return s


def render(mid, total):
    fs = fluidsynth.Synth(samplerate=float(SR), gain=0.4)
    sfid = fs.sfload(SF2)
    for ch in range(16):
        fs.program_select(ch, sfid, 128 if ch == 9 else 0, 0)
    fs.set_reverb(roomsize=0.62, damping=0.4, width=0.9, level=0.6)
    fs.set_chorus(nr=3, level=0.0, speed=0.3, depth=4.0, type=0)
    out = np.zeros((total, 2), dtype=np.float32)
    pos, t_abs = 0, 0.0
    for msg in mid:
        t_abs += msg.time
        target = min(total, int(round(t_abs * SR)))
        if target > pos:
            out[pos:target] = np.array(fs.get_samples(target - pos), dtype=np.float32).reshape(-1, 2) / 32768
            pos = target
        if msg.is_meta:
            continue
        if msg.type == "note_on":
            fs.noteon(msg.channel, msg.note, msg.velocity)
        elif msg.type == "note_off":
            fs.noteoff(msg.channel, msg.note)
        elif msg.type == "program_change":
            fs.program_select(msg.channel, sfid, 128 if msg.channel == 9 else 0, msg.program)
        elif msg.type == "control_change":
            fs.cc(msg.channel, msg.control, msg.value)
    if pos < total:
        out[pos:] = np.array(fs.get_samples(total - pos), dtype=np.float32).reshape(-1, 2) / 32768
    fs.delete()
    return out


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "out1"
    os.makedirs(os.path.join(out, "midi"), exist_ok=True)
    who = ["juanita", "tinky", "gloria", "eileen"]
    # LOOP: each musician rendered twice end to end, the second pass kept (tails wrap round)
    LP, ltempo, lbeats = build_loop()
    L = int(round(seconds_of(ltempo, lbeats) * SR))
    loop = {}
    for w in who:
        two = render(midi_for(LP[w], ltempo, lbeats, repeats=2), 2 * L)
        loop[w] = two[L:]
        midi_for(LP[w], ltempo, lbeats, name=f"Night Shift Waltz (loop) -- {w}").save(os.path.join(out, "midi", f"loop-{w}.mid"))
        print("loop", w)
    midi_for([p for w in who for p in LP[w]], ltempo, lbeats, name="Night Shift Waltz (loop) -- all four").save(
        os.path.join(out, "midi", "loop-all.mid"))
    # PERFORMANCE: once through, with its ending (and the reverb's tail)
    PP, ptempo, pbeats = build_performance()
    T = int(round((seconds_of(ptempo, pbeats) + 3.0) * SR))
    perf = {}
    for w in who:
        perf[w] = render(midi_for(PP[w], ptempo, pbeats), T)
        midi_for(PP[w], ptempo, pbeats, name=f"Night Shift Waltz (performance) -- {w}").save(
            os.path.join(out, "midi", f"performance-{w}.mid"))
        print("performance", w)
    midi_for([p for w in who for p in PP[w]], ptempo, pbeats, name="Night Shift Waltz (performance) -- all four").save(
        os.path.join(out, "midi", "performance-all.mid"))
    np.save(os.path.join(out, "loop.npy"), np.stack([loop[w] for w in who]))
    np.save(os.path.join(out, "perf.npy"), np.stack([perf[w] for w in who]))
    json.dump({"who": who, "loopSamples": L, "loopSeconds": L / SR, "perfSamples": T, "perfSeconds": T / SR,
               "loopBars": LOOP_BARS, "perfBars": pbeats // BPB, "bpm": BPM},
              open(os.path.join(out, "info.json"), "w"), indent=1)
    print(json.load(open(os.path.join(out, "info.json"))))
