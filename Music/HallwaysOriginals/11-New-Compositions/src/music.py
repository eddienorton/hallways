"""Shared writing tools for the Music Lab's newer pieces (Oct 25 2026, Claudette).

The themes of each piece are written out by hand in its own script; these tools write what a band's
players would make up around them -- walking bass, comping, grooves, and solo lines -- deterministically
(a fixed seed: the same piece every time), from the chord chart, always to the chord sounding.
"""
import random
import sys
sys.path.insert(0, "/home/claude/band/templates")
from tplkit import n, sw
sys.path.insert(0, "/home/claude/lab")
from labkit import chord

# scales per chord quality (semitones from the root): what a line may use between chord tones
SCALES = {
    "": [0, 2, 4, 7, 9], "6": [0, 2, 4, 7, 9], "maj7": [0, 2, 4, 7, 9, 11], "maj9": [0, 2, 4, 7, 9, 11], "69": [0, 2, 4, 7, 9],
    "m": [0, 2, 3, 5, 7, 10], "m7": [0, 2, 3, 5, 7, 10], "m9": [0, 2, 3, 5, 7, 10], "m6": [0, 2, 3, 5, 7, 9],
    "7": [0, 2, 4, 7, 9, 10], "9": [0, 2, 4, 7, 9, 10], "13": [0, 2, 4, 7, 9, 10], "7sus4": [0, 2, 5, 7, 9, 10],
    "7b9": [0, 1, 4, 7, 10], "dim7": [0, 3, 6, 9], "m7b5": [0, 3, 5, 6, 10], "aug": [0, 4, 8],
}


def info(sym):
    r, pcs, bass, q = chord(sym)
    scale = SCALES.get(q, [i for i in range(12) if (r + i) % 12 in pcs or i in (2, 9)])
    return r, [p % 12 for p in pcs], bass, [(r + i) % 12 for i in scale]


def at(P, beat):
    """The chord sounding at absolute beat `beat` of piece P."""
    bar = int(beat // P.bpb)
    return P.chord(min(bar, P.bars - 1), beat - bar * P.bpb)


def nearest(target, pcs, lo, hi):
    best = None
    for p in range(lo, hi + 1):
        if p % 12 in pcs and (best is None or abs(p - target) < abs(best - target)):
            best = p
    return best if best is not None else max(lo, min(hi, target))


# ------------------------------------------------------------------------------------------------ bass
def walking_bass(P, pid, bar0, nbars, lo=n("E1") + 12, hi=n("D3") + 2, vel=86, seed=1, swing_feel=True):
    """Quarter notes: the root on one, chord / scale tones stepping toward the next chord, a chromatic
    approach on four. (lo..hi: reading pitch, E2..E3 by default.)"""
    rng = random.Random(seed)
    bpb = P.bpb
    prev = None
    for b in range(bar0, bar0 + nbars):
        for k in range(bpb):
            beat = b * bpb + k
            sym = at(P, beat)
            r, pcs, bass, scale = info(sym)
            nxt = at(P, beat + 1)
            nr = info(nxt)[0]
            if k == 0 or sym != at(P, beat - 1):
                target = prev if prev is not None else (lo + hi) // 2
                p = nearest(target, [bass % 12], lo, hi)
            elif nxt != sym or k == bpb - 1:
                goal = nearest(prev, [nr], lo, hi)
                p = goal + (1 if rng.random() < .5 else -1)
                if p < lo or p > hi: p = goal - 1 if goal - 1 >= lo else goal + 1
            else:
                step = rng.choice([-2, -1, 1, 2, 3, -3])
                p = nearest(prev + step, pcs if rng.random() < .6 else scale, lo, hi)
                if p == prev: p = nearest(prev + (2 if prev < hi - 3 else -2), scale, lo, hi)
            P.put(pid, b, [(k, .9, p, vel + (6 if k == 0 else 0) + rng.randint(-5, 4))])
            prev = p


def root_bass(P, pid, bar0, nbars, pattern, lo=n("E2"), hi=n("E3") + 2, vel=88, seed=2):
    """A riff pattern [(beat, dur, interval-from-root, vel+-)] per bar, on each bar's chord (beat 0's)."""
    for b in range(bar0, bar0 + nbars):
        for beat, d, iv, dv in pattern:
            sym = P.chord(b, beat)
            bs = info(sym)[2]
            root = nearest((lo + hi) // 2 - 3, [bs % 12], lo, hi - 7)
            P.put(pid, b, [(beat, d, root + iv, vel + dv)])


# ------------------------------------------------------------------------------------------------ comping
def voicing(sym, lo, hi, count=4):
    r, pcs, bass, _ = info(sym)
    # shell first: 3rd and 7th (or 6th), then the rest
    third = [p for p in pcs if (p - r) % 12 in (3, 4)]
    seventh = [p for p in pcs if (p - r) % 12 in (9, 10, 11)]
    rest = [p for p in pcs if p not in third + seventh and (p - r) % 12 != 0]
    order = third + seventh + rest + [r]
    out = []
    for pc in order[:count]:
        p = lo + ((pc - lo) % 12)
        while p > hi: p -= 12
        out.append(p)
    return sorted(set(out))


def comp(P, pid, bar0, nbars, hits, lo=n("A3"), hi=n("G4") + 2, vel=66, count=4, swing_feel=False, seed=3, skip=()):
    """Chords on a rhythm [(beat, dur)] per bar (each voiced on the chord at its beat)."""
    rng = random.Random(seed)
    for b in range(bar0, bar0 + nbars):
        if (b - bar0) in skip: continue
        for beat, d in hits(b - bar0, rng) if callable(hits) else hits:
            sym = P.chord(b, beat if beat < P.bpb else P.bpb - .01)
            t = sw(beat) if swing_feel else beat
            P.put(pid, b, [(t, d, voicing(sym, lo, hi, count), vel + rng.randint(-5, 4))])


# ------------------------------------------------------------------------------------------------ solo lines
RHYTHMS_SWING = [  # one beat's worth of cells: [(offset, dur)]
    [(0, .5), (.5, .5)], [(0, .5), (.5, .5)], [(0, .5), (.5, .5)], [(0, 1)], [(0, 1 / 3), (1 / 3, 1 / 3), (2 / 3, 1 / 3)],
    [(.5, .5)], [(0, 1.5)], [(0, 2)]]
RHYTHMS_STRAIGHT = [[(0, .5), (.5, .5)], [(0, .25), (.25, .25), (.5, .5)], [(0, 1)], [(.5, .5)], [(0, .5), (.5, .25), (.75, .25)],
                    [(0, 1.5)], [(0, 2)]]
RHYTHMS_WALTZ = [[(0, 1)], [(0, 1)], [(0, .5), (.5, .5)], [(0, 2)], [(0, 1.5), (1.5, .5)], [(0, 3)]]


def improv(P, pid, bar0, nbars, seed, lo, hi, vel=84, swing_feel=False, cells=None, phrase=(6, 12), rest=(1.5, 4),
           start_rest=0.0, last_long=True):
    """A soloist: phrases of `phrase` beats with rests of `rest` beats between; each phrase an arch
    (up then down, or the reverse), chord tones on the beats, scale tones (and now and then a chromatic
    approach) between; each phrase ending on a chord tone, held. Deterministic for a seed."""
    rng = random.Random(seed)
    bpb = P.bpb
    cells = cells or (RHYTHMS_SWING if swing_feel else RHYTHMS_STRAIGHT)
    b = bar0 * bpb + int(start_rest)
    end = (bar0 + nbars) * bpb
    p = (lo + hi) // 2
    while b < end - 1:
        length = int(rng.uniform(*phrase))
        stop = min(end - 1, b + length)
        direction = rng.choice([1, -1])
        turn = b + length * rng.uniform(.35, .65)
        turned = False
        while b < stop:
            cell = rng.choice(cells)
            span = max(1, int(-(-max(o + d for o, d in cell) // 1)))
            if b + span > stop: cell, span = [(0, 1)], 1
            for off, d in cell:
                tt = b + off
                sym = at(P, tt)
                r, pcs, bass, scale = info(sym)
                on_beat = abs(off - round(off)) < 1e-6
                if tt > turn and not turned: direction, turned = -direction, True
                want = p + direction * rng.choice([1, 2, 2, 3, 4])
                if want > hi - 2: direction = -1
                if want < lo + 2: direction = 1
                q = nearest(want, pcs if on_beat else scale, lo, hi)
                if not on_beat and rng.random() < .15:              # a chromatic approach into what follows
                    tgt = nearest(q, info(at(P, tt + d))[1], lo, hi)
                    q = tgt + (1 if q > tgt else -1)
                q = max(lo, min(hi, q))
                tw = sw(tt) if swing_feel else tt
                bar = int(tw // bpb)
                P.put(pid, bar, [(tw - bar * bpb, d * .95, q, vel + (6 if on_beat else 0) + rng.randint(-6, 4))])
                p = q
            b += span
        if last_long and b < end:                                     # the phrase's last note: a chord tone, held
            q = nearest(p, info(at(P, b))[1], lo, hi)
            hold = min(rng.choice([1, 2, 2, 3]), end - b)
            bar = int(b // bpb)
            P.put(pid, bar, [(b - bar * bpb, hold * .95, q, vel + 2)])
            p = q
            b += hold
        b += int(rng.uniform(*rest))


def drop_overlaps(P, pid):
    """One line: a note ends before the next begins (a monophonic part stays monophonic)."""
    ns = sorted(P.notes.get(pid, []), key=lambda x: (x[0], -x[2]))
    out = []
    for x in ns:
        if out and abs(out[-1][0] - x[0]) < 1e-3:
            continue                                            # (same onset: keep the higher)
        if out and out[-1][0] + out[-1][1] > x[0] - .02:
            last = out[-1]
            out[-1] = (last[0], max(.05, x[0] - last[0] - .03)) + tuple(last[2:])
        out.append(x)
    P.notes[pid] = out
