"""HALLWAYS -- THE HOUSE BAND, prototype 1 (hallway rehearsal music).

One composition, one timeline, separate stems that can be brought up and down
like channels on a multitrack:

  juanita   the rhythmic foundation: a kalimba ostinato in a 3+3+2 / 3+3+2
            sixteenth pattern that outlines the harmony, with very soft hand
            percussion (shaker, congas). Complete enough to stand alone.
  tinky     the complement: a double bass that locks to Juanita's low conga
            (downbeat + the "and" of three) and a warm, slow pad.
  flute     one recruited musician: sparse, breathing phrases -- something in
            every 8 bars, rests half the time, so its entry is always heard
            and it never crowds.

84 bpm, 4/4, D dorian colour (Dm9, Bbmaj7#11, Gm9, Fmaj7, A7sus4 / Bbmaj9,
C6/9, Am7, C9sus): warm, a little mysterious, no strong "song" hook in the
foundation. Form A A B B A' A' = 48 bars = 137.1 s, and it loops: bar 48's
A7sus4 leads straight back to bar 1's Dm9. Every stem is rendered twice end
to end and the second pass kept, so each loop's tail already rings over its
start (no gap at the loop point).

Route A: rendered here with the FluidR3 General MIDI sound library -- good
for hearing the idea; the per-stem MIDI files are for re-rendering with better
instruments (GarageBand / Logic) later, same length, from bar 1.
"""
import json
import os
import random
import sys
import wave

import numpy as np
import mido
import fluidsynth

SR = 44100
BPM = 84
BARS = 48
BEATS = BARS * 4
LOOP_SAMPLES = int(round(BEATS * 60 / BPM * SR))
TPB = 480
SF2 = "/usr/share/sounds/sf2/FluidR3_GM.sf2"

rng = random.Random(1966)

NAMES = {"C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5, "F#": 6, "Gb": 6,
         "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11}


def n(name):
    """'A4' -> 69."""
    pitch, octave = name[:-1], int(name[-1])
    return 12 * (octave + 1) + NAMES[pitch]


# ------------------------------------------------------------------ harmony
#            bass   pad voicing (rootless, close)       kalimba tones (low -> high)
CHORDS = {
    "Dm9":     ("D2",  ["A3", "C4", "E4", "F4"],   ["D4", "F4", "A4", "C5", "D5", "E5"]),
    "Bbma7#11": ("Bb1", ["F3", "A3", "D4", "E4"],   ["D4", "F4", "A4", "Bb4", "D5", "E5"]),
    "Gm9":     ("G1",  ["F3", "A3", "Bb3", "D4"],  ["D4", "F4", "G4", "A4", "Bb4", "D5"]),
    "Fma7":    ("F2",  ["E3", "A3", "C4", "E4"],   ["C4", "E4", "F4", "A4", "C5", "E5"]),
    "A7sus":   ("A1",  ["G3", "A3", "D4", "E4"],   ["D4", "E4", "G4", "A4", "D5", "E5"]),
    "Bbma9":   ("Bb1", ["A3", "C4", "D4", "F4"],   ["D4", "F4", "A4", "Bb4", "C5", "F5"]),
    "C69":     ("C2",  ["G3", "A3", "D4", "E4"],   ["C4", "D4", "E4", "G4", "A4", "D5"]),
    "Am7":     ("A1",  ["G3", "C4", "E4", "A4"],   ["C4", "E4", "G4", "A4", "C5", "E5"]),
    "C9sus":   ("C2",  ["G3", "Bb3", "D4", "F4"],  ["C4", "D4", "F4", "G4", "Bb4", "D5"]),
}
P1 = ["Dm9", "Dm9", "Bbma7#11", "Bbma7#11", "Gm9", "Gm9", "Fma7", "A7sus"]
P2 = ["Bbma9", "C69", "Am7", "Dm9", "Gm9", "C9sus", "Fma7", "A7sus"]
FORM = [("A", P1), ("A", P1), ("B", P2), ("B", P2), ("A'", P1), ("A'", P1)]
BARS_CHORDS = [c for _, prog in FORM for c in prog]
BARS_SECTION = [s for s, prog in FORM for _ in prog]
assert len(BARS_CHORDS) == BARS


class Track:
    def __init__(self, name, program, channel, vol=100, pan=64, reverb=50):
        self.name, self.program, self.channel = name, program, channel
        self.vol, self.pan, self.reverb = vol, pan, reverb
        self.notes = []            # (start beat, dur beats, note, vel)
        self.cc = []               # (beat, controller, value)

    def add(self, start, dur, note, vel):
        self.notes.append((max(0.0, start), dur, note, max(1, min(127, int(vel)))))


def jitter(sixteenths=0.0, ms=7):
    return sixteenths + rng.uniform(-ms, ms) / 1000 * BPM / 60


# ------------------------------------------------------------------ JUANITA (rhythm)
kal = Track("Juanita -- kalimba", 108, 0, vol=104, pan=52, reverb=60)
perc = Track("Juanita -- hand percussion", 0, 9, vol=88, pan=76, reverb=40)

PAT_A = [(0, 0, 60), (3, 2, 48), (6, 1, 50), (8, 3, 54), (11, 2, 46), (14, 4, 50)]    # 3+3+2 3+3+2
PAT_A2 = [(0, 0, 60), (3, 2, 48), (6, 4, 50), (8, 3, 54), (11, 1, 46), (14, 5, 48)]   # same rhythm, new shape
PAT_B = [(0, 0, 56), (3, 2, 44), (6, 4, 48), (10, 3, 50), (12, 1, 42)]                 # sparser, more air

for bar, chord in enumerate(BARS_CHORDS):
    sec = BARS_SECTION[bar]
    tones = [n(x) for x in CHORDS[chord][2]]
    t0 = bar * 4
    pat = PAT_B if sec == "B" else (PAT_A2 if (bar % 4 == 3 or sec == "A'" and bar % 2) else PAT_A)
    for step, idx, vel in pat:
        start = t0 + step / 4 + jitter(ms=6)
        kal.add(max(0, start), 0.9, tones[idx], vel + rng.randint(-5, 4))
    # a little answering figure at the end of every 8th bar (the turnaround)
    if bar % 8 == 7:
        for k, idx in enumerate([5, 4, 3]):
            kal.add(t0 + 3 + k / 4 + 0.02, 0.6, tones[idx], 40 - 4 * k)

SHAKER, LOW_CONGA, OPEN_HI_CONGA, MUTE_HI_CONGA = 82, 64, 63, 62
for bar in range(BARS):
    sec = BARS_SECTION[bar]
    t0 = bar * 4
    for step in range(16):
        if sec == "B" and step % 2:            # B: eighths only
            continue
        v = 30 if step % 4 == 0 else (22 if step % 2 == 0 else 13)
        perc.add(t0 + step / 4 + jitter(ms=5), 0.2, SHAKER, v + rng.randint(-3, 3))
    perc.add(t0 + jitter(ms=4), 0.4, LOW_CONGA, 50 + rng.randint(-3, 3))
    perc.add(t0 + 10 / 4 + jitter(ms=4), 0.4, LOW_CONGA, 38 + rng.randint(-3, 3))
    if bar % 2 == 1:
        perc.add(t0 + 6 / 4 + jitter(ms=4), 0.3, OPEN_HI_CONGA, 26)
    if bar % 4 == 3:
        perc.add(t0 + 14 / 4 + jitter(ms=4), 0.3, MUTE_HI_CONGA, 24)

# ------------------------------------------------------------------ TINKY (bass + warm pad)
bass = Track("Tinky -- double bass", 32, 1, vol=108, pan=60, reverb=30)
pad = Track("Tinky -- warm pad", 89, 2, vol=78, pan=68, reverb=70)

for bar, chord in enumerate(BARS_CHORDS):
    root = n(CHORDS[chord][0])
    t0 = bar * 4
    bass.add(t0 + jitter(ms=5), 1.9, root, 74 + rng.randint(-3, 3))
    nxt = BARS_CHORDS[(bar + 1) % BARS]
    if nxt != chord and bar % 2 == 1:                                # step toward the next root
        tgt = n(CHORDS[nxt][0])
        approach = tgt + (2 if tgt - root < 0 else -2) if abs(tgt - root) > 2 else root + 7
        bass.add(t0 + 10 / 4 + jitter(ms=5), 1.2, approach, 60)
    else:
        bass.add(t0 + 10 / 4 + jitter(ms=5), 1.2, root + 7 if bar % 2 == 0 else root + 12, 58)

# pad: one chord per change, held across repeated bars (no re-attack), slight overlap
i = 0
while i < BARS:
    chord = BARS_CHORDS[i]
    j = i + 1
    while j < BARS and BARS_CHORDS[j] == chord:
        j += 1
    for k, x in enumerate(CHORDS[chord][1]):
        pad.add(i * 4 + 0.01 * k, (j - i) * 4 + 0.15, n(x), 46)
    i = j

# ------------------------------------------------------------------ FLUTE (a recruited musician)
flute = Track("Flute (recruited)", 73, 3, vol=96, pan=44, reverb=62)

UNITS = {   # beat (0..32 within an 8-bar unit), duration, note
    0: [(1, 1, "A4"), (2, .5, "C5"), (2.5, .5, "D5"), (3, 3, "E5"), (6.5, .5, "C5"), (7, 4, "D5"),
        (17, 1, "D5"), (18, .5, "C5"), (18.5, .5, "Bb4"), (19, 2, "A4"), (21, 1, "G4"), (22, 2, "A4"),
        (28.5, .5, "D5"), (29, 2.5, "E5")],
    1: [(2, .5, "F5"), (2.5, .5, "E5"), (3, 2, "D5"), (5, 1, "C5"), (6, 2, "A4"),
        (10, 1, "E5"), (11, .5, "D5"), (11.5, .5, "E5"), (12, 3, "F5"),
        (18, 1.5, "D5"), (19.5, .5, "F5"), (20, 2, "G5"), (22, 1, "F5"), (23, 1, "D5"),
        (24, 3, "C5"), (28, 3.5, "A4")],
    2: [(0, 2, "F5"), (2, 1, "E5"), (3, 1, "D5"), (4, 3, "E5"),
        (8.5, .5, "D5"), (9, 1.5, "C5"), (10.5, .5, "B4"), (11, 1, "A4"), (12, 4, "A4"),
        (17, 1, "Bb4"), (18, 1, "D5"), (19, 1, "F5"), (20, 3, "G5"), (23, 1, "F5"),
        (24, 3, "E5"), (27, 1, "C5"), (28, 3.5, "D5")],
    3: [(1, 1, "D5"), (2, 1, "C5"), (3, 1, "A4"), (4, 4, "G4"),
        (9, 1, "E5"), (10, .5, "D5"), (10.5, .5, "C5"), (11, 1, "A4"), (12, 4, "D5"),
        (18, 2, "F5"), (20, 2, "D5"), (22, 1, "C5"), (23, 1, "Bb4"), (24, 4, "A4")],
    4: [(1, 1, "A4"), (2, .5, "C5"), (2.5, .5, "D5"), (3, 1.5, "E5"), (4.5, .5, "F5"), (5, 1, "E5"), (6, 2, "D5"),
        (17, 1, "D5"), (18, .5, "C5"), (18.5, .5, "Bb4"), (19, 3, "A4"),
        (24, 2, "C5"), (26, 2, "A4"), (28, .5, "G4"), (28.5, .5, "A4"), (29, 2.5, "E5")],
    5: [(2, 2, "D5"), (4, 4, "A4"), (12, 2, "E5"), (14, 2, "D5"), (20, 4, "A4")],
}
for unit, notes in UNITS.items():
    base = unit * 32
    for b, d, name in notes:
        start = base + b + jitter(ms=8)
        vel = 70 + (8 if d >= 2 else 0) + rng.randint(-4, 4)
        flute.add(start, d * 0.96, n(name), vel)
        # breath: an expression swell on the longer notes (rise, then ease off)
        if d >= 2:
            flute.cc += [(start, 11, 88), (start + d * 0.35, 11, 112), (start + d * 0.9, 11, 92)]
            flute.cc += [(start + 0.6, 1, 18), (start + d * 0.95, 1, 0)]                  # a touch of vibrato
        else:
            flute.cc += [(start, 11, 104)]

STEMS = {"juanita": [kal, perc], "tinky": [bass, pad], "flute": [flute]}


# ------------------------------------------------------------------ MIDI + rendering
def midi_for(tracks, repeats=1, name="Hallways -- House Band (hallway loop)"):
    mid = mido.MidiFile(type=1, ticks_per_beat=TPB)
    meta = mido.MidiTrack()
    meta.append(mido.MetaMessage("track_name", name=name, time=0))
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
        for cc, val in [(7, tr.vol), (10, tr.pan), (91, tr.reverb), (11, 110 if tr.channel != 3 else 100)]:
            ev.append((0, 0, mido.Message("control_change", control=cc, value=val, channel=tr.channel)))
        for k in range(repeats):
            off = k * BEATS
            for b, c, v in tr.cc:
                t = int(round((max(0.0, min(b, BEATS - 0.01)) + off) * TPB))
                ev.append((t, 0, mido.Message("control_change", control=c, value=v, channel=tr.channel)))
            for s, d, note, vel in tr.notes:
                on = int(round((s + off) * TPB))
                end = min(s + d, BEATS) + off                              # nothing held over the loop point
                offt = max(on + 10, int(round(end * TPB)))
                ev.append((on, 1, mido.Message("note_on", note=note, velocity=vel, channel=tr.channel)))
                ev.append((offt, 0, mido.Message("note_off", note=note, velocity=0, channel=tr.channel)))
        ev.sort(key=lambda x: (x[0], x[1]))
        last = 0
        for t, _, m in ev:
            mt.append(m.copy(time=t - last))
            last = t
        mid.tracks.append(mt)
    return mid


def render(mid, total):
    fs = fluidsynth.Synth(samplerate=float(SR), gain=0.4)
    sfid = fs.sfload(SF2)
    for ch in range(16):
        fs.program_select(ch, sfid, 128 if ch == 9 else 0, 0)
    fs.set_reverb(roomsize=0.72, damping=0.45, width=0.9, level=0.7)
    fs.set_chorus(nr=3, level=0.6, speed=0.25, depth=6.0, type=0)
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


def write_wav(path, x):
    pcm = np.clip(x * 32767, -32768, 32767).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def db(x):
    return round(float(20 * np.log10(np.sqrt(np.mean(x.astype(np.float64) ** 2)) + 1e-12)), 1)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "out"
    os.makedirs(out, exist_ok=True)
    midi_for([t for ts in STEMS.values() for t in ts]).save(os.path.join(out, "house-band-loop.mid"))
    stems = {}
    for name, tracks in STEMS.items():
        midi_for(tracks, name=f"House Band -- {name}").save(os.path.join(out, f"houseband-{name}.mid"))
        two = render(midi_for(tracks, repeats=2), 2 * LOOP_SAMPLES)
        stems[name] = two[LOOP_SAMPLES:]                     # second pass: its tail already wraps round
        print(name, "rendered", db(stems[name]), "dB rms")
    np.save(os.path.join(out, "stems.npy"), np.stack([stems[k] for k in STEMS]))
    print(json.dumps({"loopSamples": LOOP_SAMPLES, "seconds": LOOP_SAMPLES / SR}))
