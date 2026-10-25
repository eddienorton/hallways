"""Shared helpers for the genre auditions: bar/beat placement, melody lines, chord lookups."""
import sys
sys.path.insert(0, "/home/claude/lab")
from labkit import n


def B(bar0, i, bpb=4):
    """The beat at which bar i (1-based) of a section starting at bar0 (1-based) begins."""
    return (bar0 + i - 2) * bpb


def add(p, beat, dur, note, vel, swing=False, bpm=120, jitter_ms=4):
    p.add(beat, dur, note, vel, swing=swing, jitter_ms=jitter_ms, bpm=bpm)


def line(p, bar0, mel, t=0, vel=80, octave=0, swell=True, bpb=4, bpm=120, legato=0.95, swing=False):
    """A melody: {bar: [(beat, dur, note)]}; long notes get an expression swell (CC11) where the engine honours it."""
    for bar, notes in mel.items():
        for beat, dur, name in notes:
            b = B(bar0, bar, bpb) + beat
            accent = 4 if abs(beat - int(beat) - 0.5) < 1e-6 else 0
            add(p, b, dur * legato, n(name) + t + 12 * octave, vel + accent + p.rng.randint(-3, 3), swing=swing, bpm=bpm)
            if swell and dur >= 1.5:
                p.cc += [(b, 11, 100), (b + dur * 0.6, 11, 124), (b + dur * 0.95, 11, 110)]


def chord_at(prog, i, beat):
    sym = prog[i - 1][0][1]
    for b, s in prog[i - 1]:
        if b <= beat + 1e-6:
            sym = s
    return sym


def spans(prog, bpb=4):
    out = []
    for i, bar in enumerate(prog, start=1):
        for k, (b, s) in enumerate(bar):
            end = bar[k + 1][0] if k + 1 < len(bar) else bpb
            out.append((i, b, end - b, s))
    return out
