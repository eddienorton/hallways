"""Hallways Music Lab -- shared composing/rendering toolkit (Oct 24).

Notes and chords, a swing/humanise-aware Part, a few arranging helpers
(chord voicings, harmony below a lead, walking bass), MIDI export with a tempo
map, and FluidSynth rendering (FluidR3_GM, MIT licence). Each composition
script holds only its music.
"""
import random
import numpy as np
import mido
import fluidsynth

SR = 44100
TPB = 480
SF2 = "/usr/share/sounds/sf2/FluidR3_GM.sf2"

PC = {"C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5, "F#": 6, "Gb": 6,
      "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11, "Cb": 11}


def n(name):
    """'Bb4' -> 70 (ints pass through)."""
    if not isinstance(name, str):
        return name
    return 12 * (int(name[-1]) + 1) + PC[name[:-1]]


QUAL = {"": [0, 4, 7], "6": [0, 4, 7, 9], "69": [0, 4, 7, 9, 14], "maj7": [0, 4, 7, 11], "maj9": [0, 4, 7, 11, 14],
        "7": [0, 4, 7, 10], "9": [0, 4, 7, 10, 14], "13": [0, 4, 7, 10, 14, 21], "7b9": [0, 4, 7, 10, 13],
        "7#9": [0, 4, 7, 10, 15], "7sus4": [0, 5, 7, 10], "m": [0, 3, 7], "m6": [0, 3, 7, 9], "m7": [0, 3, 7, 10],
        "m9": [0, 3, 7, 10, 14], "m11": [0, 3, 7, 10, 14, 17], "m7b5": [0, 3, 6, 10], "dim7": [0, 3, 6, 9],
        "sus4": [0, 5, 7], "add9": [0, 4, 7, 14]}


def chord(sym, t=0):
    """'Bb6/F' -> (root pc, [pcs], bass pc), transposed by t semitones."""
    bass = None
    if "/" in sym:
        sym, b = sym.split("/")
        bass = (PC[b] + t) % 12
    root = sym[:2] if len(sym) > 1 and sym[1] in "b#" else sym[:1]
    q = sym[len(root):]
    r = (PC[root] + t) % 12
    pcs = [(r + i) % 12 for i in QUAL[q]]
    return r, pcs, (bass if bass is not None else r), q


def place(pc, lo, hi, near=None):
    """The pitch of class pc within [lo, hi], nearest `near` if given (else the lowest)."""
    cands = [m for m in range(lo, hi + 1) if m % 12 == pc]
    if not cands:
        return lo + ((pc - lo) % 12)
    return min(cands, key=lambda m: abs(m - near)) if near is not None else cands[0]


def voicing(sym, t=0, lo=n("C4"), hi=n("C5") + 4, rootless=True):
    """A close jazz voicing (3, 5/6/13, 7, 9...), ascending, within lo..hi."""
    r, pcs, _, q = chord(sym, t)
    tones = [p for p in pcs if not (rootless and p == r)] or pcs
    out = []
    lowest = lo
    for p in sorted(tones, key=lambda p: (p - r) % 12 if (p - r) % 12 else 12):
        m = place(p, lowest, hi + 12)
        out.append(m)
    out.sort()
    while out and out[-1] > hi + 7:
        out[-1] -= 12
        out.sort()
    return out


def harm_below(lead, sym, t=0, count=1, min_gap=3):
    """Chord tones below a lead note (close harmony): the nearest tone at least min_gap below, etc."""
    r, pcs, _, q = chord(sym, t)
    out = []
    cur = lead
    for _ in range(count):
        cand = [m for m in range(cur - min_gap, cur - 10, -1) if m % 12 in pcs]
        nxt = cand[0] if cand else cur - 4
        out.append(nxt)
        cur = nxt
    return out


class Part:
    def __init__(self, name, who, program, channel, vol=100, pan=64, reverb=40, swing=0.1, expr=110):
        self.name, self.who, self.program, self.channel = name, who, program, channel
        self.vol, self.pan, self.reverb, self.swing, self.expr = vol, pan, reverb, swing, expr
        self.notes = []
        self.cc = []
        self.rng = random.Random(hash(name) & 0xffff)

    def add(self, beat, dur, note, vel, swing=True, jitter_ms=6, bpm=120):
        b = beat
        frac = b - int(b)
        if swing and self.swing and abs(frac - 0.5) < 1e-6:
            b += self.swing
            dur = max(0.05, dur - self.swing * (1 if dur <= 0.5 else 0))
        b += self.rng.uniform(-jitter_ms, jitter_ms) / 1000 * bpm / 60
        self.notes.append((max(0.0, b), dur, n(note), max(1, min(127, int(vel)))))


def midi_for(parts, tempo, total_beats, repeats=1, name="Hallways Music Lab", numerator=4, key="C"):
    mid = mido.MidiFile(type=1, ticks_per_beat=TPB)
    meta = mido.MidiTrack()
    meta.append(mido.MetaMessage("track_name", name=name, time=0))
    meta.append(mido.MetaMessage("time_signature", numerator=numerator, denominator=4, time=0))
    meta.append(mido.MetaMessage("key_signature", key=key, time=0))
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
        e = [(0, 0, mido.Message("program_change", program=p.program, channel=p.channel))]
        for cc, val in [(7, p.vol), (10, p.pan), (91, p.reverb), (93, 0), (11, p.expr)]:
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
    s = 0.0
    marks = sorted(tempo) + [(float("inf"), None)]
    for (b0, bpm), (b1, _) in zip(marks, marks[1:]):
        if beats <= b0:
            break
        s += (min(beats, b1) - b0) * 60 / bpm
    return s


def render(mid, total, reverb=(0.55, 0.45, 0.85, 0.55)):
    fs = fluidsynth.Synth(samplerate=float(SR), gain=0.4)
    sfid = fs.sfload(SF2)
    for ch in range(16):
        fs.program_select(ch, sfid, 128 if ch == 9 else 0, 0)
    room, damp, width, level = reverb
    fs.set_reverb(roomsize=room, damping=damp, width=width, level=level)
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


def clash_report(parts_by_who, beats, bpb=4, window=1.0, label=""):
    """Half-step rubs (m2 / m9) between different musicians' fresh notes (percussion excluded)."""
    import collections
    names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    nm = lambda m: names[m % 12] + str(m // 12 - 1)
    notes = {w: [(s, s + d, m) for p in ps if p.channel != 9 for (s, d, m, v) in p.notes] for w, ps in parts_by_who.items()}
    issues = collections.Counter()
    t = 0.0
    while t < beats:
        sounding = [(w, m) for w in notes for s, e, m in notes[w] if s <= t < e and t - s < window]
        for i in range(len(sounding)):
            for k in range(i + 1, len(sounding)):
                a, b = sounding[i], sounding[k]
                if a[0] != b[0] and abs(a[1] - b[1]) in (1, 13):
                    issues[(int(t // bpb) + 1, a[0], nm(a[1]), b[0], nm(b[1]))] += 1
        t += 0.25
    print(f"--- {label}: {len(issues)} half-step rubs")
    for k, c in sorted(issues.items()):
        print("  bar %3d: %s %s vs %s %s x%d" % (k + (c,)))
    return issues
