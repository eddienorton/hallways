"""Hallways -- "The Living Office" (original theme, ~90 s).

Form (116 bpm, 4/4, D minor / F major, 43 bars):
  Intro   1-4    double bass alone, then pizzicato strings tiptoe in
  A       5-12   the theme on clarinet; bass walks, pizz on the off-beats
  A'      13-20  bassoon answers the theme, flute ornaments, woodblock ticks
  B       21-28  F major: flute sings, horn holds warm notes underneath
  C       29-34  the sneaky bridge: staccato bassoon creeps chromatically
  A''     35-40  theme in flute + clarinet octaves, horns, everyone (lightly)
  Coda    41-43  the bass riff alone; one pluck, one tick
"""
import random
import mido

random.seed(7)
TPB = 480
BPM = 116

NOTE = {"C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5, "F#": 6, "Gb": 6,
        "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11}


def p(name):
    """'A4' -> MIDI number; 'r' -> None."""
    if name == "r":
        return None
    i = 2 if len(name) > 2 and name[1] in "#b" else 1
    return 12 * (int(name[i:]) + 1) + NOTE[name[:i]]


class Track:
    def __init__(self, name, program, channel, vol=100, pan=64):
        self.name, self.program, self.channel, self.vol, self.pan = name, program, channel, vol, pan
        self.notes = []  # (start beats, dur beats, pitch, velocity)

    boost = 0                                    # (balance: added to every velocity)

    def add(self, start, dur, pitch, vel):
        if pitch is not None:
            self.notes.append((start, dur, pitch, vel + self.boost))

    def line(self, bar, items, vel=80, legato=0.9, octave=0):
        """items: [(note, beats), ...] starting at `bar` (1-based)."""
        t = (bar - 1) * 4
        for name, d in items:
            n = p(name)
            self.add(t, d * legato, None if n is None else n + 12 * octave, vel)
            t += d
        return t


e, q, h, dq, w = 0.5, 1, 2, 1.5, 4

bass = Track("Double Bass (pizz)", 32, 0, vol=100, pan=58)
pizz = Track("Pizzicato Strings", 45, 1, vol=127, pan=80)
clar = Track("Clarinet", 71, 2, vol=112, pan=50)
bsn = Track("Bassoon", 70, 3, vol=112, pan=74)
flute = Track("Flute", 73, 4, vol=110, pan=44)
horn = Track("French Horn", 60, 5, vol=96, pan=70)
perc = Track("Percussion", 0, 9, vol=127, pan=64)
pizz.boost = 8
perc.boost = 22

# ---------------------------------------------------------------- harmony
# chord: (root pc, quality) -- the bass walks it, the pizz plucks it
CH = {"Dm": (2, [0, 3, 7]), "Gm": (7, [0, 3, 7]), "A7": (9, [0, 4, 7, 10]), "Bb": (10, [0, 4, 7]),
      "F": (5, [0, 4, 7]), "C": (0, [0, 4, 7]), "C7": (0, [0, 4, 7, 10]), "Am": (9, [0, 3, 7]),
      "Gm7": (7, [0, 3, 7, 10]), "E7": (4, [0, 4, 7, 10]), "Bbmaj7": (10, [0, 4, 7, 11]), "Dm7": (2, [0, 3, 7, 10])}


def bass_pitch(pc, low=36):          # nearest from C2 up
    n = low + ((pc - low) % 12)
    return n if n <= 45 else n - 12


def walk_bar(bar, chord, nxt, style="riff", vel=96):
    """The double bass: a buoyant, catchy riff (root, low fifth, root-third, approach)."""
    root, ints = CH[chord]
    r = bass_pitch(root)
    five = r + 7 if r + 7 <= 47 else r - 5
    third = r + ints[1]
    nroot = bass_pitch(CH[nxt][0])
    appr = nroot + (1 if nroot < r else -1)              # chromatic approach to the next root
    t = (bar - 1) * 4
    if style == "riff":                                  # | R . 5v R | 3 . appr . |  (the signature)
        pat = [(0, r, 0.4, 0), (1, five - 12 if five > r else five, 0.35, -8), (1.5, r, 0.35, -4),
               (2, third, 0.6, 0), (3, appr, 0.45, -6), (3.5, appr + (1 if appr < nroot else -1), 0.3, -14)]
    elif style == "half":                                # B section: warmer, fewer notes
        pat = [(0, r, 1.6, -6), (2, five, 0.9, -10), (3, appr, 0.7, -12)]
    else:                                                # "walk": four on the floor quarters
        pat = [(0, r, 0.7, 0), (1, five, 0.6, -8), (2, third + 12 if third < r else third, 0.6, -6), (3, appr, 0.6, -6)]
    for off, n, d, dv in pat:
        bass.add(t + off, d, n, vel + dv)


def pizz_bar(bar, chord, vel=62, pattern="offbeat"):
    root, ints = CH[chord]
    base = 60 + ((root - 60) % 12)
    if base > 66:
        base -= 12
    tones = [base + i for i in ints[:3]]
    t = (bar - 1) * 4
    hits = {"offbeat": [1.5, 3.5], "tiptoe": [0.5, 2.5], "arp": [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5],
            "sparse": [1.5]}[pattern]
    for i, off in enumerate(hits):
        if pattern == "arp":
            n = tones[i % 3] + (12 if i % 6 >= 3 else 0)
            pizz.add(t + off, 0.3, n, vel - 6 + (i % 2) * 4)
        else:
            for n in tones:
                pizz.add(t + off, 0.3, n, vel)


# ---------------------------------------------------------------- the theme
THEME = [  # 8 bars, D minor -- mischievous: a leap, a wink, a chromatic tiptoe
    [("A4", e), ("D5", e), ("F5", q), ("E5", e), ("D5", e), ("C#5", q)],
    [("D5", e), ("E5", e), ("F5", e), ("G5", e), ("A5", dq), ("r", e)],
    [("Bb5", e), ("A5", e), ("G5", e), ("F5", e), ("E5", e), ("F5", e), ("G5", q)],
    [("A5", e), ("r", e), ("E5", e), ("r", e), ("C#5", h)],
    [("A4", e), ("D5", e), ("F5", q), ("E5", e), ("D5", e), ("C#5", q)],
    [("D5", e), ("E5", e), ("F5", e), ("G5", e), ("A5", e), ("Bb5", e), ("C6", q)],
    [("Bb5", e), ("A5", e), ("G5", e), ("E5", e), ("F5", e), ("D5", e), ("E5", e), ("C#5", e)],
    [("D5", q), ("A4", q), ("D5", q), ("r", q)],
]
THEME_CHORDS = ["Dm", "Dm", "Gm", "A7", "Dm", "F", "Gm", "Dm"]


def theme(track, first_bar, octave=0, vel=82, staccato=0.62):
    for i, bar in enumerate(THEME):
        # staccato on eighths, held on longer notes: playful articulation
        t = (first_bar + i - 1) * 4
        for name, d in bar:
            n = p(name)
            if n is not None:
                track.add(t, d * (staccato if d <= e else 0.88), n + 12 * octave,
                          vel + (8 if d >= q else 0) + random.randint(-4, 4))
            t += d


# ---------------------------------------------------------------- Intro 1-4
intro = ["Dm", "Dm", "Gm", "A7"]
for i, c in enumerate(intro):
    walk_bar(1 + i, c, intro[(i + 1) % 4] if i < 3 else "Dm", vel=100)
pizz_bar(3, "Gm", 52, "tiptoe")
pizz_bar(4, "A7", 56, "tiptoe")
perc.add(15.5, 0.2, 77, 52)                                  # one low woodblock: "ahem"

# ---------------------------------------------------------------- A 5-12
prog = THEME_CHORDS
for i, c in enumerate(prog):
    walk_bar(5 + i, c, prog[(i + 1) % 8], vel=96)
    pizz_bar(5 + i, c, 60, "offbeat")
theme(clar, 5, vel=84)

# ---------------------------------------------------------------- A' 13-20
for i, c in enumerate(prog):
    walk_bar(13 + i, c, prog[(i + 1) % 8] if i < 7 else "F", vel=94)
    pizz_bar(13 + i, c, 56, "offbeat" if i % 2 == 0 else "tiptoe")
theme(bsn, 13, octave=-2, vel=86, staccato=0.55)            # bassoon takes the tune, two octaves down
# flute: little answers in the gaps (bars 14, 16, 18, 20)
flute.line(14, [("r", 2.5), ("A5", e), ("C6", e), ("D6", e)], vel=66, legato=0.5)
flute.line(16, [("r", 2), ("E6", e), ("D6", e), ("C#6", e), ("A5", e)], vel=64, legato=0.5)
flute.line(18, [("r", 2.5), ("Bb5", e), ("D6", e), ("F6", e)], vel=66, legato=0.5)
flute.line(20, [("r", 1), ("F6", e), ("E6", e), ("D6", e), ("C6", e), ("A5", q)], vel=64, legato=0.6)
for b in range(13, 21):                                       # woodblock: the office clock
    t = (b - 1) * 4
    perc.add(t + 1, 0.1, 76, 44 + random.randint(-4, 4))
    perc.add(t + 3, 0.1, 77, 40 + random.randint(-4, 4))
perc.add(19 * 4 + 3.5, 0.2, 81, 50)                           # triangle at the turn

# ---------------------------------------------------------------- B 21-28 (F major)
progB = ["F", "Dm7", "Bbmaj7", "C7", "F", "Am", "Gm7", "C7"]
for i, c in enumerate(progB):
    walk_bar(21 + i, c, progB[(i + 1) % 8] if i < 7 else "Gm", style="half", vel=90)
    pizz_bar(21 + i, c, 50, "arp")
flute.line(21, [("C6", dq), ("A5", e), ("F5", q), ("G5", q)], vel=74, legato=0.95)
flute.line(22, [("A5", dq), ("F5", e), ("D5", h)], vel=72, legato=0.95)
flute.line(23, [("D6", dq), ("C6", e), ("Bb5", q), ("A5", q)], vel=74, legato=0.95)
flute.line(24, [("G5", e), ("A5", e), ("Bb5", e), ("G5", e), ("E5", h)], vel=72, legato=0.9)
flute.line(25, [("C6", dq), ("A5", e), ("F5", q), ("A5", q)], vel=74, legato=0.95)
flute.line(26, [("E6", dq), ("C6", e), ("A5", h)], vel=74, legato=0.95)
flute.line(27, [("Bb5", e), ("C6", e), ("D6", e), ("Bb5", e), ("G5", q), ("A5", e), ("Bb5", e)], vel=72, legato=0.9)
flute.line(28, [("A5", q), ("G5", q), ("E5", q), ("C5", q)], vel=70, legato=0.85)
for bar, notes in [(21, ["F3", "A3"]), (23, ["F3", "D3"]), (25, ["A3", "C4"]), (27, ["G3", "Bb3"])]:
    horn.line(bar, [(notes[0], w), (notes[1], w)], vel=56, legato=0.97)
for b in range(21, 29):                                       # a soft shaker in eighths
    for k in range(8):
        perc.add((b - 1) * 4 + k * 0.5, 0.1, 70, 26 + (8 if k % 2 == 0 else 0))
clar.line(26, [("r", 2), ("C5", q), ("E5", q)], vel=58, legato=0.8)   # clarinet peeks in
clar.line(28, [("r", 1), ("Bb4", q), ("A4", q), ("G4", q)], vel=58, legato=0.8)

# ---------------------------------------------------------------- C 29-34 (the sneaky bridge)
progC = ["Gm", "A7", "Gm", "A7", "Bb", "A7"]
for i, c in enumerate(progC):
    walk_bar(29 + i, c, progC[(i + 1) % 6] if i < 5 else "Dm", style="walk", vel=84)
    pizz_bar(29 + i, c, 48, "sparse")
sneak = [
    [("G3", e), ("r", e), ("A3", e), ("Bb3", e), ("B3", e), ("r", e), ("C4", e), ("C#4", e)],
    [("D4", e), ("r", e), ("C#4", e), ("r", e), ("E4", q), ("r", q)],
    [("Bb3", e), ("r", e), ("A3", e), ("G3", e), ("F#3", e), ("r", e), ("G3", e), ("A3", e)],
    [("Bb3", e), ("C#4", e), ("E4", e), ("G4", e), ("A4", q), ("r", q)],
    [("D4", e), ("F4", e), ("Bb4", e), ("F4", e), ("D4", e), ("Bb3", e), ("F3", e), ("D3", e)],
    [("C#3", e), ("E3", e), ("A3", e), ("C#4", e), ("E4", q), ("r", q)],
]
for i, bar in enumerate(sneak):
    bsn.line(29 + i, bar, vel=80, legato=0.45)
for b in range(29, 35):                                       # tick... tock (sparser)
    perc.add((b - 1) * 4 + 0, 0.1, 76, 40)
    perc.add((b - 1) * 4 + 2.5, 0.1, 77, 36)
clar.line(30, [("r", 2), ("E5", e), ("r", e), ("C#5", e), ("r", e)], vel=60, legato=0.5)
flute.line(32, [("r", 2), ("A6", e), ("r", e), ("E6", e), ("r", e)], vel=56, legato=0.4)
clar.line(34, [("r", 2), ("E5", e), ("G5", e), ("Bb5", e), ("C#6", e)], vel=64, legato=0.5)

# ---------------------------------------------------------------- A'' 35-40 (lightly, all together)
progA2 = ["Dm", "Dm", "Gm", "A7", "Dm", "F"]
for i, c in enumerate(progA2):
    walk_bar(35 + i, c, progA2[(i + 1) % 6] if i < 5 else "Gm", vel=98)
    pizz_bar(35 + i, c, 60, "offbeat")
for i in range(6):                                            # first six bars of the theme, in octaves
    bar = THEME[i]
    t = (35 + i - 1) * 4
    for name, d in bar:
        n = p(name)
        if n is not None:
            dur = d * (0.6 if d <= e else 0.88)
            flute.add(t, dur, n + 12, 72 + random.randint(-3, 3))
            clar.add(t, dur, n, 74 + random.randint(-3, 3))
        t += d
for bar, n in [(35, "D4"), (36, "F4"), (37, "D4"), (38, "C#4"), (39, "D4"), (40, "C4")]:
    horn.line(bar, [(n, w)], vel=54, legato=0.95)
for b in range(35, 41):
    perc.add((b - 1) * 4 + 1, 0.1, 76, 42)
    perc.add((b - 1) * 4 + 3, 0.1, 77, 38)

# ---------------------------------------------------------------- Coda 41-43
walk_bar(41, "Gm", "A7", vel=94)
walk_bar(42, "A7", "Dm", vel=90)
bsn.line(41, [("r", 2), ("Bb3", e), ("A3", e), ("G3", e), ("E3", e)], vel=70, legato=0.5)
clar.line(42, [("r", 2), ("E5", e), ("C#5", e), ("r", q)], vel=62, legato=0.5)
bass.add(42 * 4, 0.6, p("D2"), 104)                           # bar 43: one pluck...
for n in ["D4", "F4", "A4", "D5"]:
    pizz.add(42 * 4 + 0.02, 0.4, p(n), 64)
perc.add(42 * 4 + 1, 0.2, 76, 50)                             # ...and one tick.

TOTAL_BEATS = 43 * 4

# ---------------------------------------------------------------- humanise + write MIDI
tracks = [bass, pizz, clar, bsn, flute, horn, perc]


def write_midi(path):
    mid = mido.MidiFile(type=1, ticks_per_beat=TPB)
    meta = mido.MidiTrack()
    meta.append(mido.MetaMessage("track_name", name="Hallways -- The Living Office", time=0))
    meta.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(BPM), time=0))
    meta.append(mido.MetaMessage("time_signature", numerator=4, denominator=4, time=0))
    meta.append(mido.MetaMessage("key_signature", key="Dm", time=0))
    mid.tracks.append(meta)
    for tr in tracks:
        mt = mido.MidiTrack()
        mt.append(mido.MetaMessage("track_name", name=tr.name, time=0))
        ev = []
        if tr.channel != 9:
            ev.append((0, 0, mido.Message("program_change", program=tr.program, channel=tr.channel)))
        ev.append((0, 0, mido.Message("control_change", control=7, value=tr.vol, channel=tr.channel)))
        ev.append((0, 0, mido.Message("control_change", control=10, value=tr.pan, channel=tr.channel)))
        ev.append((0, 0, mido.Message("control_change", control=91, value=46, channel=tr.channel)))  # a little room
        for s, d, n, v in tr.notes:
            jitter = random.uniform(-0.012, 0.012) if s > 0 else 0
            on = max(0, int(round((s + jitter) * TPB)))
            off = max(on + 10, int(round((s + d) * TPB)))
            v = max(1, min(127, int(v)))
            ev.append((on, 1, mido.Message("note_on", note=n, velocity=v, channel=tr.channel)))
            ev.append((off, 0, mido.Message("note_off", note=n, velocity=0, channel=tr.channel)))
        ev.sort(key=lambda x: (x[0], x[1]))
        last = 0
        for t, _, m in ev:
            mt.append(m.copy(time=t - last))
            last = t
        mid.tracks.append(mt)
    mid.save(path)
    return mid


if __name__ == "__main__":
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else "theme.mid"
    m = write_midi(out)
    print(out, f"{m.length:.1f} s", sum(len(t.notes) for t in tracks), "notes")
