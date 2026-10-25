"""HALLWAYS ORIGINALS #2 -- "Going Up!" (working title). An eight-piece swing.

  Juanita   trumpet          lead melody (the head), the shout
  Telephone tenor sax        harmony under the trumpet; the bridge's melody
  Chair     trombone         pads and "wah" answers; the bridge's melody (2nd chorus)
  Pottle    clarinet         answers in the trumpet's gaps; descant; tops the shout
  Camera    vibraphone       "click!" stabs; the melody (2nd chorus A1)
  Eileen    piano            comping (Charleston rhythm), the Basie "plink" ending
  Gloria    upright bass     walking
  Tinky     drums (GM Jazz kit): ride, hi-hat on 2 & 4, feathered kick, fills

B-flat major, 4/4, 168 bpm, swung eighths. A 32-bar AABA song form:
  A: Bb6 Gm7 | Cm7 F7 | Bb6 Gm7 | Cm7 F7 | Fm7 Bb7 | Eb6 Edim7 | Bb6/F G7 | Cm7 F7
  B: D7 | D7 | G7 | G7 | C7 | C7 | F7 | F7     (the bridge: round the dominants)
These are long-public swing idioms (the I-vi-ii-V turnaround, the dominant-cycle
bridge). The melodies, riffs, answers and arrangement are new for Hallways.

LOOP (64 bars, 91.4 s): the head chorus, then a "feature" chorus in which the
melody moves round the band (vibes, clarinet, trombone) and a shout to finish.
PERFORMANCE (~2:25): intro (drums, then bass and piano, then horn hits) / head /
feature chorus with sax-trumpet trading / stop-time drum break / a key change
UP a whole step (to C) for the bridge and the shout / tag x3 / the Basie
"plink, plink ... BAM" ending.
"""
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from labkit import (Part, n, chord, voicing, harm_below, place, midi_for, seconds_of, render, clash_report)

BPM = 168.0
BPB = 4


def B(bar0, i):
    return (bar0 + i - 2) * BPB


# ------------------------------------------------------------------ harmony
A1 = [[(0, "Bb6"), (2, "Gm7")], [(0, "Cm7"), (2, "F7")], [(0, "Bb6"), (2, "Gm7")], [(0, "Cm7"), (2, "F7")],
      [(0, "Fm7"), (2, "Bb7")], [(0, "Eb6"), (2, "Edim7")], [(0, "Bb6/F"), (2, "G7")], [(0, "Cm7"), (2, "F7")]]
A2 = A1[:6] + [[(0, "Cm7"), (2, "F7")], [(0, "Bb6"), (2, "A7")]]
BR = [[(0, "D7")], [(0, "D7")], [(0, "G7")], [(0, "G7")], [(0, "C7")], [(0, "C7")], [(0, "F7")], [(0, "F7")]]
A3 = A1[:6] + [[(0, "Cm7"), (2, "F7")], [(0, "Bb6"), (2, "F7")]]           # (turns back to the top)
A3_END = A1[:6] + [[(0, "Cm7"), (2, "F7")], [(0, "Bb6")]]
VAMP = [[(0, "Bb6"), (2, "Gm7")], [(0, "Cm7"), (2, "F7")]] * 4
TAG = [[(0, "Cm7"), (2, "F7")]] * 4


def chord_at(prog, i, beat):
    sym = prog[i - 1][0][1]
    for b, s in prog[i - 1]:
        if b <= beat + 1e-6:
            sym = s
    return sym


def spans(prog):
    """(bar i, start beat, length, symbol) for every chord."""
    out = []
    for i, bar in enumerate(prog, start=1):
        for k, (b, s) in enumerate(bar):
            end = bar[k + 1][0] if k + 1 < len(bar) else BPB
            out.append((i, b, end - b, s))
    return out


# ------------------------------------------------------------------ the tunes (concert pitch, B-flat)
HEAD_A1 = {1: [(0, .5, "Bb4"), (.5, .5, "D5"), (1, .5, "F5"), (1.5, 1.5, "G5")],
           2: [(0, .5, "F5"), (.5, .5, "Eb5"), (1, .5, "C5"), (1.5, .5, "A4"), (2, 1, "C5")],
           3: [(0, .5, "Bb4"), (.5, .5, "D5"), (1, .5, "F5"), (1.5, 1.5, "Bb5")],
           4: [(0, .5, "A5"), (.5, .5, "G5"), (1, .5, "F5"), (1.5, .5, "Eb5"), (2, 1.5, "C5")],
           5: [(.5, .5, "C5"), (1, .5, "Eb5"), (1.5, .5, "F5"), (2, 1, "Ab5"), (3, .5, "G5")],
           6: [(0, 1.5, "G5"), (1.5, .5, "F5"), (2, 1, "E5"), (3, .5, "G5")],
           7: [(0, .5, "F5"), (.5, .5, "D5"), (1, 1, "Bb4"), (2, .5, "B4"), (2.5, .5, "D5"), (3, 1, "F5")],
           8: [(0, 1.5, "Eb5"), (1.5, .5, "D5"), (2, 1, "C5")]}
HEAD_A2 = dict(HEAD_A1)
HEAD_A2.update({7: [(0, .5, "Eb5"), (.5, .5, "D5"), (1, .5, "C5"), (1.5, .5, "Bb4"), (2, 1, "A4"), (3, .5, "C5")],
                8: [(0, 2, "Bb4")]})
HEAD_A3 = dict(HEAD_A2)
HEAD_A3[8] = [(0, 1.5, "Bb4")]
BRIDGE = {1: [(0, .5, "A3"), (.5, .5, "C4"), (1, .5, "D4"), (1.5, 1.5, "F#4")],
          2: [(0, .5, "E4"), (.5, .5, "D4"), (1, .5, "C4"), (1.5, .5, "A3"), (2, 1.5, "F#3")],
          3: [(0, .5, "D4"), (.5, .5, "F4"), (1, .5, "G4"), (1.5, 1.5, "B4")],
          4: [(0, .5, "A4"), (.5, .5, "G4"), (1, .5, "F4"), (1.5, .5, "D4"), (2, 1.5, "B3")],
          5: [(0, .5, "G4"), (.5, .5, "Bb4"), (1, .5, "C5"), (1.5, 1.5, "E5")],
          6: [(0, .5, "D5"), (.5, .5, "C5"), (1, .5, "Bb4"), (1.5, .5, "G4"), (2, 1.5, "E4")],
          7: [(0, .5, "C4"), (.5, .5, "Eb4"), (1, .5, "F4"), (1.5, 1.5, "A4")],
          8: [(0, .5, "G4"), (.5, .5, "F4"), (1, .5, "Eb4"), (1.5, .5, "C4"), (2, 1, "A3")]}
# Pottle's answers in the trumpet's gaps (A sections)
CL_A = {1: [(3, .5, "Bb5"), (3.5, .5, "G5")], 2: [(3, .5, "A5"), (3.5, .5, "C6")], 8: [(3, .5, "F5"), (3.5, .5, "A5")]}
CL_A2 = {1: [(3, .5, "D6"), (3.5, .5, "Bb5")], 2: [(3, .5, "C6"), (3.5, .5, "A5")],
         8: [(2, .5, "E5"), (2.5, .5, "G5"), (3, .5, "A5"), (3.5, .5, "C#6")]}
# The bridge's descant (Pottle, head chorus): falling by half steps, two bars each
DESCANT = {1: [(0, 7.5, "F#5")], 3: [(0, 7.5, "F5")], 5: [(0, 7.5, "E5")], 7: [(0, 7.5, "Eb5")]}
# Chair's "wah" answers in the bridge (the even bars' second half)
WAH = {2: [(2.5, 1.5, "C4")], 4: [(2.5, 1.5, "F3")], 6: [(2.5, 1.5, "Bb3")], 8: [(2.5, 1.5, "Eb3")]}
# The tag's riff (x3) and the sax-trumpet trading answers (feature chorus, A3)
TAG_RIFF = {1: [(0, 1.5, "Eb5"), (1.5, .5, "D5"), (2, 1, "C5")], 2: [(0, 1.5, "Eb5"), (1.5, .5, "D5"), (2, 1, "C5")],
            3: [(0, 1.5, "Eb5"), (1.5, .5, "D5"), (2, 1, "C5")]}
TRADE_TPT = {1: [(3, .5, "D6"), (3.5, .5, "Bb5")], 2: [(3, .5, "A5"), (3.5, .5, "F5")], 5: [(3.5, .5, "Bb5")],
             8: [(2, .5, "G5"), (2.5, .5, "A5"), (3, .5, "Bb5"), (3.5, .5, "C6")]}


# ------------------------------------------------------------------ the band
def new_band():
    return {
        "juanita": [Part("Juanita -- trumpet", "juanita", 56, 0, vol=96, pan=72, reverb=40)],
        "telephone": [Part("Telephone -- tenor sax", "telephone", 66, 1, vol=98, pan=50, reverb=40)],
        "chair": [Part("Chair -- trombone", "chair", 57, 2, vol=96, pan=38, reverb=40)],
        "pottle": [Part("Pottle -- clarinet", "pottle", 71, 3, vol=96, pan=88, reverb=44)],
        "camera": [Part("Camera -- vibraphone", "camera", 11, 4, vol=100, pan=100, reverb=48)],
        "eileen": [Part("Eileen -- piano", "eileen", 0, 5, vol=96, pan=58, reverb=36)],
        "gloria": [Part("Gloria -- upright bass", "gloria", 32, 6, vol=112, pan=64, reverb=22, swing=0)],
        "tinky": [Part("Tinky -- drums", "tinky", 32, 9, vol=100, pan=64, reverb=26)],
    }


def add(p, beat, dur, note, vel, **kw):
    p.add(beat, dur, note, vel, bpm=BPM, **kw)


def line(p, bar0, mel, t=0, vel=88, octave=0, swell=True):
    for bar, notes in mel.items():
        for beat, dur, name in notes:
            b = B(bar0, bar) + beat
            accent = 5 if abs(beat - int(beat) - 0.5) < 1e-6 else 0
            add(p, b, dur * 0.94, n(name) + t + 12 * octave, vel + accent + p.rng.randint(-3, 3))
            if swell and dur >= 1.5 and p.channel != 4:
                p.cc += [(b, 11, 96), (b + dur * 0.6, 11, 118), (b + dur * 0.95, 11, 104)]


def harmony(p, bar0, mel, prog, t=0, k=1, vel=78, hi=n("E5"), lo=n("A2"), above=False, cap=n("D6")):
    """A harmony part derived from a lead: the k-th chord tone below it (or one above), kept in range."""
    for bar, notes in mel.items():
        for beat, dur, name in notes:
            lead = n(name) + t
            sym = chord_at(prog, bar, beat)
            if above:
                r, pcs, _, _ = chord(sym, t)
                cand = [m for m in range(lead + 3, lead + 10) if m % 12 in pcs]
                h = cand[0] if cand else lead
                if h > cap:
                    h = lead
            else:
                h = harm_below(lead, sym, t, count=k)[-1]
            while h > hi:
                h -= 12
            while h < lo:
                h += 12
            add(p, B(bar0, bar) + beat, dur * 0.94, h, vel + p.rng.randint(-3, 3))


def pad(p, bar0, prog, t=0, lo=n("Bb2"), hi=n("F4"), vel=60, upper=False):
    """Long guide tones (3rds and 7ths), each chord, moving by the smallest step."""
    prev = (lo + hi) // 2
    for i, b, length, sym in spans(prog):
        r, pcs, _, q = chord(sym, t)
        third = pcs[1]
        seventh = pcs[3] if len(pcs) > 3 else pcs[2]
        cands = [place(third, lo, hi, prev), place(seventh, lo, hi, prev)]
        if upper:
            cands = [c + 12 if c + 12 <= hi + 12 else c for c in cands]
        m = min(cands, key=lambda c: abs(c - prev))
        add(p, B(bar0, i) + b, length * 0.95, m, vel + p.rng.randint(-2, 2), swing=False)
        p.cc += [(B(bar0, i) + b, 11, 92), (B(bar0, i) + b + length * 0.5, 11, 108)]
        prev = m


def comp(p, bar0, prog, t=0, vel=58, skip=()):
    """Eileen's Charleston comping: on the chord, and the 'and' of its second beat."""
    for i, b, length, sym in spans(prog):
        if i in skip:
            continue
        v = voicing(sym, t, lo=n("Bb3"), hi=n("A4"))
        start = B(bar0, i) + b
        hits = [(0, 0.45, vel), (1.5, 0.3, vel - 8)] if length >= 2 else [(0, 0.4, vel)]
        if length >= 4:
            hits.append((3.5, 0.3, vel - 10))
        for off, d, vv in hits:
            for k, m in enumerate(v):
                add(p, start + off + k * 0.006, d, m, vv + p.rng.randint(-3, 3), jitter_ms=3)


def stabs(p, bar0, prog, where, t=0, vel=72, dur=0.35):
    for bar, beat in where:
        sym = chord_at(prog, bar, beat)
        for m in voicing(sym, t, lo=n("C5"), hi=n("C6"))[-3:]:
            add(p, B(bar0, bar) + beat, dur, m, vel + p.rng.randint(-3, 3), jitter_ms=3)


def walk(p, bar0, prog, t=0, vel=84, after=None):
    """Gloria walks: roots on the changes, chord tones between, a half step into each new root."""
    beats = []
    for i in range(1, len(prog) + 1):
        for k in range(BPB):
            beats.append((i, k, chord_at(prog, i, k)))
    prev = n("F2")
    nxt_sym = after
    for j, (i, k, sym) in enumerate(beats):
        r, pcs, bass, _ = chord(sym, t)
        changed = j == 0 or beats[j - 1][2] != sym
        target_sym = beats[j + 1][2] if j + 1 < len(beats) else (nxt_sym or beats[0][2])
        target_changes = j + 1 >= len(beats) or beats[j + 1][2] != sym
        tr = chord(target_sym, t)[2]
        if changed:
            m = place(bass, n("D1") + 2, n("G2"), prev)
        elif target_changes:
            tgt = place(tr, n("D1") + 2, n("G2"), prev)
            m = tgt - 1 if abs(tgt - 1 - prev) <= abs(tgt + 1 - prev) else tgt + 1
        else:
            options = [place(pc, n("D1") + 2, n("A2"), prev) for pc in pcs[1:3]]
            options = [o for o in options if o != prev] or options
            m = min(options, key=lambda o: abs(o - prev - 2))
        add(p, B(bar0, i) + k, 0.92, m, vel + (6 if k in (1, 3) else 0) + p.rng.randint(-4, 3), swing=False, jitter_ms=5)
        prev = m


RIDE, PEDAL, KICK, SNARE, CRASH, TOM_H, TOM_M, TOM_L, STICK = 51, 44, 36, 38, 49, 50, 47, 45, 37


def drums(p, bar0, nbars, vel=1.0, fills=(), crashes=(), kicks=(), soft=False, stop=None):
    """Tinky: ride, hi-hat on 2 and 4, feathered kick, ghost notes; fills; crashes; kicks with the horns."""
    for i in range(1, nbars + 1):
        b0 = B(bar0, i)
        if stop is not None and i in stop:
            continue
        for beat, v in [(0, 60), (1, 70), (1.5, 50), (2, 60), (3, 70), (3.5, 50)]:
            if i in fills and beat >= 2:
                continue
            add(p, b0 + beat, 0.4, RIDE, int(v * vel * (0.85 if soft else 1)) + p.rng.randint(-4, 4))
        for beat in (1, 3):
            add(p, b0 + beat, 0.2, PEDAL, int(52 * vel) + p.rng.randint(-3, 3), swing=False)
        for beat in range(4):
            add(p, b0 + beat, 0.2, KICK, int(20 * vel) + p.rng.randint(-2, 2), swing=False)
        if p.rng.random() < 0.35 and i not in fills:
            add(p, b0 + p.rng.choice([1.5, 2.5, 3.5]), 0.2, SNARE, int(26 * vel) + p.rng.randint(-3, 3))
        if i in fills:
            for k, (beat, inst, v) in enumerate([(2, SNARE, 52), (2.5, SNARE, 58), (3, TOM_M, 66), (3.5, TOM_L, 74)]):
                add(p, b0 + beat, 0.3, inst, int(v * vel) + p.rng.randint(-3, 3))
    for i in crashes:
        add(p, B(bar0, i), 1.5, CRASH, int(84 * vel), swing=False)
        add(p, B(bar0, i), 0.3, KICK, int(70 * vel), swing=False)
    for i, beat in kicks:
        add(p, B(bar0, i) + beat, 0.3, SNARE, int(72 * vel))
        add(p, B(bar0, i) + beat, 0.3, KICK, int(64 * vel))


# ------------------------------------------------------------------ the choruses
def head_chorus(P, bar0, t=0, last=A3, last_mel=HEAD_A3, vel=1.0):
    J, S, C, Pt, V, E, G, T = (P[w][0] for w in ["juanita", "telephone", "chair", "pottle", "camera", "eileen", "gloria", "tinky"])
    for sec, (prog, mel, cl) in enumerate([(A1, HEAD_A1, CL_A), (A2, HEAD_A2, CL_A2), (None, None, None), (last, last_mel, CL_A)]):
        s0 = bar0 + 8 * sec
        if prog is None:                                    # the bridge: Telephone sings it
            line(S, s0, BRIDGE, t, vel=int(88 * vel))
            line(Pt, s0, DESCANT, t, vel=int(62 * vel))
            line(C, s0, WAH, t, vel=int(70 * vel))
            stabs(V, s0, BR, [(i, b) for i in range(1, 9) for b in (1.5, 3.5)], t, vel=int(58 * vel), dur=0.25)
            comp(E, s0, BR, t, vel=int(54 * vel))
            walk(G, s0, BR, t, after="Bb6")
            drums(T, s0, 8, vel=vel, fills=(8,))
            continue
        line(J, s0, mel, t, vel=int(92 * vel))
        harmony(S, s0, mel, prog, t, k=1, vel=int(76 * vel))
        if sec == 3:
            harmony(C, s0, mel, prog, t, k=2, vel=int(70 * vel), hi=n("F4"), lo=n("Bb2"))
        else:
            pad(C, s0, prog, t, vel=int(56 * vel))
        line(Pt, s0, cl, t, vel=int(80 * vel), swell=False)
        stabs(V, s0, prog, [(4, 3.5), (6, 3.5)], t, vel=int(70 * vel))
        comp(E, s0, prog, t, vel=int(58 * vel))
        walk(G, s0, prog, t, after=("D7" if sec == 1 else "Bb6"))
        drums(T, s0, 8, vel=vel, fills=(8,), crashes=(1,) if sec == 0 else ())


def feature_chorus(P, bar0, t=0, shout=True, vel=1.0):
    """The melody round the band: Camera (A1), Pottle (A2), Chair (bridge); then the shout -- or sax/trumpet trading."""
    J, S, C, Pt, V, E, G, T = (P[w][0] for w in ["juanita", "telephone", "chair", "pottle", "camera", "eileen", "gloria", "tinky"])
    # A1: Camera has the tune; Telephone and Chair breathe long notes beneath; Pottle answers
    s0 = bar0
    line(V, s0, HEAD_A1, t, vel=int(84 * vel))
    pad(S, s0, A1, t, lo=n("D4"), hi=n("Bb4"), vel=int(56 * vel))
    pad(C, s0, A1, t, vel=int(54 * vel))
    line(Pt, s0, CL_A, t, vel=int(76 * vel), swell=False)
    comp(E, s0, A1, t, vel=int(52 * vel))
    walk(G, s0, A1, t, after="Bb6")
    drums(T, s0, 8, vel=vel * 0.9, fills=(8,), soft=True)
    # A2: Pottle has the tune; Camera answers (his licks); the pads go on
    s0 = bar0 + 8
    line(Pt, s0, HEAD_A2, t, vel=int(84 * vel))
    line(V, s0, CL_A2, t, vel=int(72 * vel), swell=False)
    pad(S, s0, A2, t, lo=n("D4"), hi=n("Bb4"), vel=int(56 * vel))
    pad(C, s0, A2, t, vel=int(54 * vel))
    comp(E, s0, A2, t, vel=int(52 * vel))
    walk(G, s0, A2, t, after="D7")
    drums(T, s0, 8, vel=vel * 0.9, fills=(8,), soft=True)
    # Bridge: Chair sings it (an octave down); Telephone answers with the "wah"s; Camera clicks
    s0 = bar0 + 16
    line(C, s0, BRIDGE, t, vel=int(90 * vel), octave=-1)
    line(S, s0, {k: [(b, d, nm) for b, d, nm in v] for k, v in WAH.items()}, t + 12, vel=int(70 * vel))
    stabs(V, s0, BR, [(i, b) for i in range(1, 9) for b in (1.5, 3.5)], t, vel=int(58 * vel), dur=0.25)
    comp(E, s0, BR, t, vel=int(54 * vel))
    walk(G, s0, BR, t, after="Bb6")
    drums(T, s0, 8, vel=vel, fills=(8,))
    # A3: the shout (everyone) -- or Telephone with the tune, Juanita trading answers
    s0 = bar0 + 24
    if shout:
        shout_chorus_a(P, s0, t, A3, HEAD_A3, vel)
    else:
        line(S, s0, HEAD_A3, t - 12, vel=int(90 * vel))
        line(J, s0, TRADE_TPT, t, vel=int(86 * vel), swell=False)
        pad(C, s0, A3, t, vel=int(56 * vel))
        stabs(V, s0, A3, [(4, 3.5), (6, 3.5)], t, vel=int(66 * vel))
        comp(E, s0, A3, t, vel=int(58 * vel))
        walk(G, s0, A3, t, after="Bb6")
        drums(T, s0, 8, vel=vel, fills=(8,))


def shout_chorus_a(P, s0, t, prog, mel, vel=1.0, after="Bb6", last_fill=True):
    J, S, C, Pt, V, E, G, T = (P[w][0] for w in ["juanita", "telephone", "chair", "pottle", "camera", "eileen", "gloria", "tinky"])
    line(J, s0, mel, t, vel=int(100 * vel))
    harmony(Pt, s0, mel, prog, t, above=True, vel=int(84 * vel))
    harmony(S, s0, mel, prog, t, k=1, vel=int(86 * vel))
    harmony(C, s0, mel, prog, t, k=2, vel=int(84 * vel), hi=n("F4"), lo=n("Bb2"))
    stabs(V, s0, prog, [(2, 3.5), (4, 3.5), (6, 3.5)], t, vel=int(74 * vel))
    comp(E, s0, prog, t, vel=int(64 * vel))
    walk(G, s0, prog, t, after=after)
    drums(T, s0, 8, vel=vel * 1.1, fills=(8,) if last_fill else (), crashes=(1, 5), kicks=[(1, 1.5), (3, 1.5), (5, 2.0)])


# ------------------------------------------------------------------ the two forms
WHO = ["juanita", "telephone", "chair", "pottle", "camera", "eileen", "gloria", "tinky"]
LOOP_BARS = 64


def build_loop():
    P = new_band()
    head_chorus(P, 1)
    feature_chorus(P, 33, shout=True)
    return P, [(0, BPM)], LOOP_BARS * BPB


def build_performance():
    P = new_band()
    J, S, C, Pt, V, E, G, T = (P[w][0] for w in WHO)
    bar = 1
    # Intro (8): Tinky alone, then Gloria and Eileen, then the horns' hits
    drums(T, bar, 8, vel=0.9, fills=(2, 8))
    walk(G, bar + 2, VAMP[2:], after="Bb6")
    comp(E, bar + 2, VAMP[2:], vel=54)
    for i, beat, d in [(7, 0, .45), (7, 1.5, .45), (8, 0, .45), (8, 1, .45), (8, 2, 1.0)]:
        sym = chord_at(VAMP, i, beat)
        top = n("D4") if sym in ("Bb6", "Gm7") else n("Eb5")
        b = B(bar, i) + beat
        lead = top + 12 if sym in ("Bb6", "Gm7") else top
        add(J, b, d, lead, 96)
        for who, k, hi in [("pottle", 1, n("C6")), ("telephone", 2, n("E5")), ("chair", 3, n("F4"))]:
            h = harm_below(lead, sym, 0, count=k)[-1]
            while h > hi:
                h -= 12
            add(P[who][0], b, d, h, 88)
        add(V, b, d, lead, 70)
        add(T, b, 0.3, SNARE, 78)
        add(T, b, 0.3, KICK, 70)
    bar += 8
    # The head
    head_chorus(P, bar)
    bar += 32
    # The feature chorus: the melody round the band; Telephone and Juanita trade at the end
    feature_chorus(P, bar, shout=False)
    bar += 32
    # The break (8): stop-time -- the band hits, Tinky answers; then up to the new key
    for i in range(1, 7):
        b = B(bar, i)
        for who, m in [("juanita", "D5"), ("pottle", "Ab5"), ("telephone", "F4"), ("chair", "Bb2")]:
            add(P[who][0], b, 0.4, m, 92, swing=False)
        for m in voicing("Bb7", 0, lo=n("C5"), hi=n("C6")):
            add(V, b, 0.4, m, 70, swing=False)
        for m in voicing("Bb7", 0):
            add(E, b, 0.4, m, 72, swing=False)
        add(G, b, 0.6, "Bb1", 92, swing=False)
        add(T, b, 1.2, CRASH, 80, swing=False)
        add(T, b, 0.3, KICK, 72, swing=False)
        pattern = [(1, SNARE, 50), (1.5, SNARE, 44), (2, TOM_H, 58), (2.5, TOM_M, 60), (3, TOM_L, 66), (3.5, SNARE, 70)]
        if i % 2 == 0:
            pattern = [(1, SNARE, 46), (1.5, SNARE, 52), (2, SNARE, 58), (2.5, SNARE, 62), (3, TOM_M, 68), (3.5, TOM_L, 74)]
        for beat, inst, v in pattern:
            add(T, b + beat, 0.25, inst, v + 2 * i)
    lift = [[(0, "Dm7"), (2, "G7")], [(0, "Dm7"), (2, "G7")]]
    for i in (7, 8):
        b = B(bar, i)
        for who, k, hi in [("juanita", 0, n("C6")), ("pottle", 0, n("D6")), ("telephone", 1, n("E5")), ("chair", 2, n("F4"))]:
            for beat in (0, 2):
                sym = chord_at(lift, i - 6, beat)
                lead = place(chord(sym)[1][1] if beat == 0 else chord(sym)[1][3], n("A4"), n("G5"))
                h = lead + (12 if who == "pottle" else 0) if k == 0 else harm_below(lead, sym, 0, count=k)[-1]
                while h > hi:
                    h -= 12
                add(P[who][0], b + beat, 1.9, h, 70 + 8 * (i - 7) + (beat * 4), swing=False)
    walk(G, bar + 6, lift, after="E7")
    comp(E, bar + 6, lift, vel=60)
    for k in range(16):
        add(T, B(bar, 7) + k * 0.5, 0.25, SNARE, 40 + k * 3)
    add(T, B(bar, 8) + 3.5, 0.25, TOM_L, 90)
    bar += 8
    # UP A WHOLE STEP (C): the bridge (trumpet and sax in octaves), then the shout
    t = 2
    line(J, bar, BRIDGE, t, vel=96, octave=1)
    line(S, bar, BRIDGE, t, vel=90)
    pad(C, bar, BR, t, vel=66)
    line(Pt, bar, DESCANT, t, vel=70)
    stabs(V, bar, BR, [(i, b) for i in range(1, 9) for b in (1.5, 3.5)], t, vel=62, dur=0.25)
    comp(E, bar, BR, t, vel=60)
    walk(G, bar, BR, t, after="Bb6")
    drums(T, bar, 8, vel=1.05, fills=(8,), crashes=(1,))
    bar += 8
    shout_chorus_a(P, bar, t, A3_END, HEAD_A3, vel=1.05, after="Cm7")
    bar += 8
    # The tag: the last phrase, three times
    for rep in range(3):
        line(J, bar + rep, {1: TAG_RIFF[1]}, t, vel=96 - 4 * rep)
        harmony(S, bar + rep, {1: TAG_RIFF[1]}, TAG, t, k=1, vel=84 - 4 * rep)
        harmony(C, bar + rep, {1: TAG_RIFF[1]}, TAG, t, k=2, vel=80 - 4 * rep, hi=n("F4"), lo=n("Bb2"))
        line(Pt, bar + rep, {1: [(3, .5, "F5"), (3.5, .5, "A5")]}, t, vel=78, swell=False)
    comp(E, bar, TAG[:3], t, vel=58)
    walk(G, bar, TAG[:3], t, after="Bb6")
    drums(T, bar, 3, vel=1.0, fills=(3,))
    bar += 3
    # The ending: Eileen's "plink ... plink", then everybody: BAM (C6/9)
    b = B(bar, 1)
    add(E, b, 0.3, n("G5"), 70, swing=False, jitter_ms=0)
    add(E, b + 1.5, 0.3, n("G5"), 74, swing=False, jitter_ms=0)
    hit = b + 3
    final = {"juanita": "A5", "pottle": "D6", "telephone": "E5", "chair": "G3", "camera": None}
    for who, m in final.items():
        if m:
            add(P[who][0], hit, 2.6, m, 100, swing=False, jitter_ms=0)
    for m in [n("E5"), n("A5"), n("D6")]:
        add(V, hit, 3.0, m, 80, swing=False, jitter_ms=0)
    for m in [n("C3"), n("E4"), n("A4"), n("D5"), n("G5")]:
        add(E, hit, 3.0, m, 84, swing=False, jitter_ms=0)
    add(G, hit, 2.5, n("C2"), 100, swing=False, jitter_ms=0)
    add(T, hit, 3.0, CRASH, 100, swing=False, jitter_ms=0)
    add(T, hit, 0.3, KICK, 96, swing=False, jitter_ms=0)
    J.cc += [(hit, 11, 110), (hit + 1.2, 11, 120), (hit + 2.4, 11, 70)]
    total_beats = B(bar, 2) + 2
    tempo = [(0, BPM), (hit, 120)]
    return P, tempo, total_beats


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "out2"
    os.makedirs(os.path.join(out, "midi"), exist_ok=True)
    if len(sys.argv) > 2 and sys.argv[2] == "check":
        LP, _, lb = build_loop()
        clash_report(LP, lb, label="LOOP")
        PP, _, pb = build_performance()
        clash_report(PP, pb, label="PERFORMANCE")
        sys.exit(0)
    LP, lt, lb = build_loop()
    L = int(round(seconds_of(lt, lb) * 44100))
    loop = {}
    for w in WHO:
        two = render(midi_for(LP[w], lt, lb, repeats=2, key="Bb"), 2 * L)
        loop[w] = two[L:]
        midi_for(LP[w], lt, lb, name=f"Going Up! (loop) -- {w}", key="Bb").save(os.path.join(out, "midi", f"loop-{w}.mid"))
        print("loop", w, flush=True)
    midi_for([p for w in WHO for p in LP[w]], lt, lb, name="Going Up! (loop) -- the band", key="Bb").save(os.path.join(out, "midi", "loop-all.mid"))
    PP, pt, pb = build_performance()
    T = int(round((seconds_of(pt, pb) + 3.0) * 44100))
    perf = {}
    for w in WHO:
        perf[w] = render(midi_for(PP[w], pt, pb, key="Bb"), T)
        midi_for(PP[w], pt, pb, name=f"Going Up! (performance) -- {w}", key="Bb").save(os.path.join(out, "midi", f"performance-{w}.mid"))
        print("performance", w, flush=True)
    midi_for([p for w in WHO for p in PP[w]], pt, pb, name="Going Up! (performance) -- the band", key="Bb").save(
        os.path.join(out, "midi", "performance-all.mid"))
    np.save(os.path.join(out, "loop.npy"), np.stack([loop[w] for w in WHO]).astype(np.float32))
    np.save(os.path.join(out, "perf.npy"), np.stack([perf[w] for w in WHO]).astype(np.float32))
    json.dump({"who": WHO, "loopSamples": L, "loopSeconds": L / 44100, "perfSamples": T, "perfSeconds": T / 44100,
               "loopBars": LOOP_BARS, "bpm": BPM}, open(os.path.join(out, "info.json"), "w"), indent=1)
    print(json.load(open(os.path.join(out, "info.json"))))
