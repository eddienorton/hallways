"""Black Box composer -- Python reference for BlackBoxMusic.swift.

Deterministic: the same seed gives the same notes here and in Swift
(integer-only random choices, the game's SplitMix64 `Rand`).
"""
MASK = (1 << 64) - 1


class Rand:
    def __init__(self, seed):
        self.state = (seed + 0x2545F4914F6CDD1D) & MASK

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
        return z ^ (z >> 31)

    def int(self, n):
        return self.next() % n

    def chance(self, pct):
        return self.int(100) < pct

    def pick(self, arr):
        return arr[self.int(len(arr))]

    def weighted(self, pairs):
        total = sum(w for _, w in pairs)
        r = self.int(total)
        for v, w in pairs:
            if r < w:
                return v
            r -= w
        return pairs[-1][0]


MAJOR = [0, 2, 4, 5, 7, 9, 11]
MINOR = [0, 2, 3, 5, 7, 8, 10]

# Chords: (bass pc, chord pcs) relative to the tonic.
CH = {
    'I': (0, [0, 4, 7]), 'ii': (2, [2, 5, 9]), 'iii': (4, [4, 7, 11]), 'IV': (5, [5, 9, 0]),
    'V': (7, [7, 11, 2]), 'vi': (9, [9, 0, 4]), 'V7': (7, [7, 11, 2, 5]), 'III7': (4, [4, 8, 11, 2]),
    'VI7': (9, [9, 1, 4, 7]), 'Imaj7': (0, [0, 4, 7, 11]), 'ii7': (2, [2, 5, 9, 0]), 'iii7': (4, [4, 7, 11, 2]),
    'IVmaj7': (5, [5, 9, 0, 4]), 'iv6': (5, [5, 8, 0, 2]), 'I6': (0, [0, 4, 7, 9]),
    'i': (0, [0, 3, 7]), 'iM7': (11, [0, 3, 7, 11]), 'i7': (10, [0, 3, 7, 10]), 'i6': (9, [0, 3, 7, 9]),
    'iv': (5, [5, 8, 0]), 'VI': (8, [8, 0, 3]), 'iv7': (5, [5, 8, 0, 3]), 'VImaj7': (8, [8, 0, 3, 7]),
}

PROGS = {
    'bounce': [
        [['I'], ['vi'], ['IV'], ['V'], ['I'], ['vi'], ['ii', 'V'], ['I']],
        [['I'], ['IV'], ['I'], ['V'], ['I'], ['IV'], ['V'], ['I']],
        [['I'], ['III7'], ['vi'], ['V'], ['IV'], ['I'], ['ii', 'V'], ['I']],
        [['I'], ['iii'], ['IV'], ['V'], ['vi'], ['IV'], ['ii', 'V'], ['I']],
    ],
    'waltz': [
        [['I'], ['IV'], ['I'], ['V7'], ['I'], ['IV'], ['V7'], ['I']],
        [['I'], ['vi'], ['ii'], ['V7'], ['I'], ['III7'], ['ii'], ['V7'], ],
        [['I'], ['I'], ['V7'], ['V7'], ['V7'], ['V7'], ['I'], ['I']],
    ],
    'bossa': [
        [['Imaj7'], ['VI7'], ['ii7'], ['V7'], ['Imaj7'], ['VI7'], ['ii7', 'V7'], ['Imaj7']],
        [['Imaj7'], ['IVmaj7'], ['iii7'], ['VI7'], ['ii7'], ['iv6'], ['ii7', 'V7'], ['Imaj7']],
        [['Imaj7'], ['ii7'], ['iii7'], ['V7'], ['IVmaj7'], ['iv6'], ['iii7', 'VI7'], ['ii7', 'V7']],
    ],
    'spy': [
        [['i'], ['iM7'], ['i7'], ['i6'], ['iv'], ['VI'], ['V7'], ['i']],
        [['i'], ['iv'], ['i'], ['V7'], ['VI'], ['iv'], ['V7'], ['i']],
        [['i'], ['VI'], ['iv7'], ['V7'], ['i'], ['VI'], ['iv', 'V7'], ['i']],
    ],
}
# Progressions whose last bar is not the tonic get a tonic tag bar.
STYLE = {
    'bounce': dict(meter=4, bpm=(112, 128), swing=0, minor=False, leads=['square', 'marimba', 'whistle'],
                   cells='acbfgi', comp=['offbeat', 'push'], bass='pluck', bassPat='pop', drums='pop'),
    'waltz': dict(meter=3, bpm=(132, 150), swing=0, minor=False, leads=['bell', 'whistle', 'vibes'],
                  cells='abcdef', comp=['waltz'], bass='upright', bassPat='waltz', drums='none'),
    'bossa': dict(meter=4, bpm=(96, 108), swing=0, minor=False, leads=['whistle', 'vibes', 'marimba'],
                  cells='beidh', comp=['bossa'], bass='upright', bassPat='bossa', drums='bossa'),
    'spy': dict(meter=4, bpm=(118, 134), swing=64, minor=True, leads=['vibes', 'square'],
                cells='cfghb', comp=['spy'], bass='upright', bassPat='walk', drums='brush'),
}
STYLE_ORDER = ['bounce', 'waltz', 'bossa', 'spy']
MAJOR_KEYS = [0, 2, 3, 5, 7, 9, 10]
MINOR_KEYS = [9, 2, 4, 7, 0]

CELLS4 = {
    'a': [(0, 4), (4, 4), (8, 4), (12, 4)],
    'b': [(0, 6), (6, 2), (8, 4), (12, 4)],
    'c': [(0, 2), (2, 2), (4, 4), (8, 2), (10, 2), (12, 4)],
    'd': [(0, 4), (4, 4), (8, 8)],
    'e': [(0, 6), (6, 6), (12, 4)],
    'f': [(0, 2), (2, 4), (6, 2), (8, 4), (12, 4)],
    'g': [(0, 4), (4, 2), (6, 2), (8, 4), (12, 2), (14, 2)],
    'h': [(2, 2), (4, 2), (6, 2), (8, 4), (12, 4)],
    'i': [(0, 6), (6, 2), (8, 6), (14, 2)],
}
CELLS3 = {
    'a': [(0, 4), (4, 4), (8, 4)],
    'b': [(0, 6), (6, 2), (8, 4)],
    'c': [(0, 8), (8, 4)],
    'd': [(0, 4), (4, 2), (6, 2), (8, 4)],
    'e': [(0, 2), (2, 2), (4, 4), (8, 4)],
    'f': [(0, 4), (4, 8)],
}


class Note:
    __slots__ = ('tick', 'dur', 'kind', 'inst', 'midi', 'vel')

    def __init__(self, tick, dur, kind, inst, midi, vel):
        self.tick, self.dur, self.kind, self.inst, self.midi, self.vel = tick, dur, kind, inst, midi, vel


class Piece:
    pass


def scale_pc(scale, deg):
    """Pitch (semitones from tonic) of scale degree index `deg` (0 = tonic)."""
    octave, i = divmod(deg, 7)
    return octave * 12 + scale[i]


def deg_pc(scale, deg):
    return scale_pc(scale, deg) % 12


def compose(seed, style=None, previous_style=None):
    rng = Rand(seed)
    if style is None:
        choices = [s for s in STYLE_ORDER if s != previous_style]
        style = rng.pick(choices)
    st = STYLE[style]
    p = Piece()
    p.seed, p.style, p.meter = seed, style, st['meter']
    lo, hi = st['bpm']
    p.bpm = lo + rng.int(hi - lo + 1)
    p.swing = st['swing']                       # percent of a beat for the off-beat eighth (0 = straight)
    minor = st['minor']
    keypc = rng.pick(MINOR_KEYS if minor else MAJOR_KEYS)
    tonic = 60 + keypc
    p.tonic = tonic
    bass_tonic = keypc + 36
    if bass_tonic < 40:
        bass_tonic += 12
    p.lead = rng.pick(st['leads'])
    comp = rng.pick(st['comp'])
    prog = rng.pick(PROGS[style])
    scale = MINOR if minor else MAJOR
    T = 4 * p.meter
    p.ticks_per_bar = T
    notes = []

    # Bars: 0 = count-in, 1..8 = tune, 9 = ending.
    def bar_tick(bar, tick):
        return bar * T + tick

    def chord_at(bar, tick):
        names = prog[bar - 1]
        if len(names) == 1 or tick < T // 2:
            return names[0]
        return names[1]

    def chord_degs(name):
        return CH[name][1]

    def melody_scale_pc(deg, chord):
        pc = deg_pc(scale, deg)
        # Harmonic minor over the dominant: the raised leading tone.
        if minor and pc == 10 and chord in ('V7', 'V'):
            return 11
        return pc

    def deg_to_midi(deg, chord):
        octave = deg // 7
        return tonic + octave * 12 + melody_scale_pc(deg, chord)

    def is_chord_tone(deg, chord):
        return melody_scale_pc(deg, chord) in chord_degs(chord)

    def snap(deg, chord, prev=None, direction=0):
        """Nearest chord tone; ties and near-ties follow the melody's
        direction and avoid repeating the previous note."""
        if direction >= 9:            # climb: the nearest chord tone at or above
            order = (0, 1, 2, 3, -1, -2)
        elif direction >= 0:
            order = (0, 1, -1, 2, -2, 3, -3)
        else:
            order = (0, -1, 1, -2, 2, -3, 3)
        for d in order:
            g = deg + d
            if not is_chord_tone(g, chord):
                continue
            if prev is not None and direction != 0 and g == prev:
                continue
            return g
        return deg

    LO, HI, CAP = -3, 9, 7

    # ---- Melody ----------------------------------------------------------
    cells = CELLS4 if p.meter == 4 else CELLS3
    keys = list(st['cells'])
    r1 = rng.pick(keys)
    r2 = r1
    for _ in range(6):
        r2 = rng.pick(keys)
        if r2 != r1:
            break
    r3 = r1 if rng.chance(50) else rng.pick(keys)

    def contour(n):
        steps = []
        prev = 0
        for _ in range(max(0, n - 1)):
            if abs(prev) >= 2:
                s = -1 if prev > 0 else 1                 # after a leap, step back
            else:
                s = rng.weighted([(-1, 30), (1, 30), (-2, 10), (2, 13), (0, 4), (3, 5), (-3, 4)])
            steps.append(s)
            prev = s
        return steps

    def realize(bar, rhythm, start, steps, snap_weak=True):
        top = HI if bar == 7 else CAP
        degs = [start]
        for s in steps:
            degs.append(degs[-1] + s)
        while max(degs) > top:
            degs = [d - 1 for d in degs]
        while min(degs) < LO:
            degs = [d + 1 for d in degs]
        out = []
        prev = None
        for i, ((tick, dur), d) in enumerate(zip(rhythm, degs)):
            ch = chord_at(bar, tick)
            strong = tick % (T // 2 if p.meter == 4 else T) == 0
            on_beat = tick % 4 == 0
            step = 0 if i == 0 else steps[i - 1]
            if strong or dur >= 6 or (on_beat and snap_weak and rng.chance(55)):
                d = snap(d, ch, prev, step)
            out.append((tick, dur, d))
            prev = d
        return out

    s1 = rng.weighted([(4, 4), (2, 4), (0, 2), (7, 1)])
    m1 = contour(len(cells[r1]))
    m2 = contour(len(cells[r2]))
    melody = {}
    melody[1] = realize(1, cells[r1], s1, m1)
    last = melody[1][-1][2]
    s2 = last + rng.pick([-1, 1, 2, -2])
    melody[2] = realize(2, cells[r2], s2, m2)
    shift = rng.pick([2, 1, -1, 3, 2])
    melody[3] = realize(3, cells[r1], s1 + shift, m1, snap_weak=False)

    # Bar 4: half cadence -- approach a dominant chord tone by step, hold it.
    ch4 = chord_at(4, 0)
    prev = melody[3][-1][2]
    target = snap(prev + rng.pick([-1, 1, -2, 0]), ch4)
    if p.meter == 4:
        cad = rng.pick([[(0, 4), (4, 4), (8, 8)], [(0, 12)], [(0, 8), (12, 2), (14, 2)]])
    else:
        cad = rng.pick([[(0, 8), (8, 4)], [(0, 12)]])
    m4 = []
    if len(cad) == 3 and cad[2][0] == 8:          # step down (or up) into the held note
        direction = 1 if rng.chance(60) else -1
        m4 = [(0, 4, target + 2 * direction), (4, 4, target + direction), (8, 8, target)]
    elif len(cad) == 3:                            # held note, then two pickups into bar 5
        m4 = [(0, 8, target), (12, 2, melody[1][0][2] - 2), (14, 2, melody[1][0][2] - 1)]
    elif len(cad) == 2:
        m4 = [(0, 8, target), (8, 4, snap(target - 1, ch4))]
    else:
        m4 = [(0, 12 if p.meter == 4 else 12, target)]
    melody[4] = m4
    # Bars 5-6: the antecedent again (re-fitted to the chords).
    melody[5] = [(t, d, snap(g, chord_at(5, t)) if (t % (T // 2 if p.meter == 4 else T) == 0) else g) for t, d, g in melody[1]]
    melody[6] = [(t, d, snap(g, chord_at(6, t)) if (t % (T // 2 if p.meter == 4 else T) == 0 or d >= 6) else g)
                 for t, d, g in melody[2]]
    # Bar 7: the climax -- the motif, higher.
    peak_so_far = max(g for b in range(1, 7) for _, _, g in melody[b])
    m7 = realize(7, cells[r3], s1 + rng.pick([2, 3, 4]), m1 if r3 == r1 else contour(len(cells[r3])))
    top = max(g for _, _, g in m7)
    want = min(HI, peak_so_far + 1)
    if top < want:
        m7 = [(t, d, snap(g + (want - top), chord_at(7, t), None, 9) if (d >= 6 or t % (T // 2 if p.meter == 4 else T) == 0) else g + (want - top)) for t, d, g in m7]
    melody[7] = m7
    # Bar 8: home. Approach the tonic by step from the last note.
    lastg = melody[7][-1][2]
    home = 7 if lastg >= 4 else 0
    final_chord = prog[7][0]
    if final_chord in ('I', 'Imaj7', 'i'):
        melody[8] = [(0, T, home)]
    else:  # ends on a dominant: a held chord tone, and the tag resolves
        melody[8] = [(0, T, snap(lastg, chord_at(8, 0)))]

    pickup = rng.chance(40)
    if pickup:
        first = melody[1][0]
        if first[0] == 0:
            melody[0] = [(T - 2, 2, first[2] - 1)] if rng.chance(50) else [(T - 4, 2, first[2] - 2), (T - 2, 2, first[2] - 1)]
        else:
            pickup = False

    lead_vel = 0.9
    for bar in sorted(melody):
        for i, (tick, dur, g) in enumerate(melody[bar]):
            ch = chord_at(bar, tick) if bar >= 1 else prog[0][0]
            accent = 1.0 if tick == 0 else (0.92 if tick % 4 == 0 else 0.84)
            vel = lead_vel * accent * (92 + rng.int(9)) / 100
            notes.append(Note(bar_tick(bar, tick), dur, 'lead', p.lead, deg_to_midi(g, ch), vel))
    p.melody = melody

    # ---- Ending ------------------------------------------------------------
    ends_on_tonic = prog[7][0] in ('I', 'Imaj7', 'i')
    flourish = style in ('waltz', 'bossa')
    # Bar 9: tag. A dominant-ending progression resolves here.
    if flourish:
        arp = [0, 2, 4, 7] if not ends_on_tonic else [2, 4, 7, 9]
        for k, g in enumerate(arp):
            notes.append(Note(bar_tick(9, 2 * k), 2 if k < 3 else 10, 'lead', p.lead, deg_to_midi(g, 'I' if not minor else 'i'), 0.62 + 0.05 * k))
    else:
        notes.append(Note(bar_tick(9, 0), 3, 'lead', p.lead, deg_to_midi(7, 'i' if minor else 'I'), 0.95))

    # ---- Bass ------------------------------------------------------------
    def bass_note(pc):
        m = bass_tonic + pc
        while m > bass_tonic + 7:
            m -= 12
        return m

    bp = st['bassPat']
    for bar in range(1, 9):
        for half in range(2 if len(prog[bar - 1]) == 2 else 1):
            name = prog[bar - 1][half]
            root = bass_note(CH[name][0])
            fifth = bass_note((CH[name][1][0] + 7) % 12) if name not in ('iM7', 'i7', 'i6') else bass_note(7)
            if fifth > root:
                fifth -= 12
            nxt = prog[bar][0] if bar < 8 else prog[0][0]
            nroot = bass_note(CH[nxt][0])
            span = T if len(prog[bar - 1]) == 1 else T // 2
            base = half * (T // 2)
            if bar == 8:
                notes.append(Note(bar_tick(bar, base), span, 'bass', st['bass'], root, 0.95))
                continue
            if bp == 'pop':
                pat = [(0, 4, root, 1.0), (6, 2, root, 0.7), (8, 4, fifth + 12 if fifth + 12 - root < 9 else fifth, 0.85),
                       (12, 2, root, 0.75), (14, 2, nroot + (1 if nroot < root else -1), 0.7)]
            elif bp == 'waltz':
                pat = [(0, 4, root if bar % 2 == 1 else fifth, 1.0)]
            elif bp == 'bossa':
                pat = [(0, 6, root, 1.0), (6, 2, fifth, 0.7), (8, 6, fifth, 0.85), (14, 2, root, 0.6)]
            else:  # walking (spy)
                third = bass_note(CH[name][1][1])
                if third < root:
                    third += 12
                approach = nroot + (1 if rng.chance(50) else -1)
                pat = [(0, 3, root, 1.0), (4, 3, third if rng.chance(50) else fifth + 12, 0.8),
                       (8, 3, fifth + 12, 0.85), (12, 3, approach, 0.8)]
            for tick, dur, m, v in pat:
                if tick >= span and span < T:
                    continue
                if span < T and tick + base >= base + span:
                    continue
                notes.append(Note(bar_tick(bar, base + tick), dur, 'bass', st['bass'], m, v))
    notes.append(Note(bar_tick(9, 0), 4 if not flourish else 12, 'bass', st['bass'],
                      bass_note(0), 1.0))

    # ---- Keys ------------------------------------------------------------
    center = [tonic - 10]

    def voicing(name):
        pcs = CH[name][1]
        out = []
        for pc in pcs:
            base = tonic - 12 + (pc % 12) - (tonic % 12)
            best = None
            for k in range(-2, 3):
                m = base + 12 * k
                if best is None or abs(m - center[0]) < abs(best - center[0]):
                    best = m
            out.append(best)
        out = sorted(set(out))
        center[0] = (sum(out) / len(out)) * 0.5 + (tonic - 10) * 0.5
        return out

    comp_pats = {
        'offbeat': [(2, 2), (6, 2), (10, 2), (14, 2)],
        'push': [(0, 6), (6, 6), (12, 4)],
        'waltz': [(4, 3), (8, 3)],
        'bossaA': [(0, 3), (6, 3), (12, 2)],
        'bossaB': [(2, 3), (8, 3), (12, 3)],
        'spy': [(4, 2), (12, 2)],
    }
    keys_inst = 'epiano' if style != 'waltz' else 'bell'
    for bar in range(1, 9):
        if bar == 8:
            names = prog[7]
            for half, name in enumerate(names):
                span = T // len(names)
                for m in voicing(name):
                    notes.append(Note(bar_tick(bar, half * span), span, 'keys', keys_inst, m, 0.75))
            continue
        pat = comp_pats['bossaA' if bar % 2 == 1 else 'bossaB'] if comp == 'bossa' else comp_pats[comp]
        voiced = {}
        for tick, dur in pat:
            name = chord_at(bar, tick)
            if name not in voiced:
                voiced[name] = voicing(name)
            accent = 0.8 if tick % 4 == 0 else 0.7
            for m in voiced[name]:
                notes.append(Note(bar_tick(bar, tick), dur, 'keys', keys_inst, m, accent))
    final_name = 'i' if minor else ('Imaj7' if style == 'bossa' else 'I')
    for m in voicing(final_name):
        notes.append(Note(bar_tick(9, 0), 4 if not flourish else 12, 'keys', keys_inst, m, 0.8))

    # ---- Drums -------------------------------------------------------------
    d = st['drums']
    # Count-in: the box taps the beats (wood clicks); pickups replace the last.
    for beat in range(p.meter):
        if pickup and beat == p.meter - 1:
            continue
        notes.append(Note(bar_tick(0, beat * 4), 1, 'drum', 'click', 0, 0.9 if beat == 0 else 0.7))
    for bar in range(1, 9):
        if d == 'pop':
            for tick in (0, 8):
                notes.append(Note(bar_tick(bar, tick), 1, 'drum', 'kick', 0, 1.0))
            if bar % 2 == 0:
                notes.append(Note(bar_tick(bar, 10), 1, 'drum', 'kick', 0, 0.7))
            for tick in (4, 12):
                notes.append(Note(bar_tick(bar, tick), 1, 'drum', 'snare', 0, 0.9))
            for tick in range(0, 16, 2):
                notes.append(Note(bar_tick(bar, tick), 1, 'drum', 'hat', 0, 0.8 if tick % 4 == 2 else 0.5))
        elif d == 'bossa':
            for tick in (0, 6, 8, 14):
                notes.append(Note(bar_tick(bar, tick), 1, 'drum', 'kick', 0, 0.55 if tick % 8 else 0.7))
            clave = [0, 6, 12] if bar % 2 == 1 else [4, 10]
            for tick in clave:
                notes.append(Note(bar_tick(bar, tick), 1, 'drum', 'rim', 0, 0.8))
            for tick in range(0, 16, 2):
                notes.append(Note(bar_tick(bar, tick), 1, 'drum', 'hat', 0, 0.45))
        elif d == 'brush':
            notes.append(Note(bar_tick(bar, 0), 1, 'drum', 'kick', 0, 0.6))
            for tick in (4, 12):
                notes.append(Note(bar_tick(bar, tick), 1, 'drum', 'brush', 0, 0.9))
            for tick in (0, 4, 6, 8, 12, 14):
                notes.append(Note(bar_tick(bar, tick), 1, 'drum', 'hat', 0, 0.55 if tick % 4 else 0.4))
        if bar == 8:
            break
    if not flourish:
        notes.append(Note(bar_tick(9, 0), 1, 'drum', 'kick', 0, 1.0))
        notes.append(Note(bar_tick(9, 0), 1, 'drum', 'snare', 0, 1.0))
    p.notes = notes
    p.prog = prog
    p.flourish = flourish
    p.bars = 10
    return p


def tick_time(p, tick):
    """Seconds from the start of the piece to grid `tick` (sixteenths)."""
    beat, sub = divmod(tick, 4)
    frac = sub / 4.0
    if p.swing and sub == 2:
        frac = p.swing / 100.0
    return (beat + frac) * 60.0 / p.bpm


NAMES = ['C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B']


def name(m):
    return f"{NAMES[m % 12]}{m // 12 - 1}"
