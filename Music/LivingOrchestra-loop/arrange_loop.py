"""THE LIVING ORCHESTRA -- the game's looping arrangement of "The Living Office".

Version 1 (compose.py -> hallways-living-office.mid, and its preview) is NOT
changed: this script imports its notes and re-arranges them.

The loop: bars 1-42 of the original (the coda's last bar, the final pluck, is
dropped). Bars 41-42 are the bass riff over Gm and A7, which leads straight
back into bar 1's Dm riff, so the loop never cadences. Every stem is exactly
LOOP_SAMPLES long and rendered TWICE end to end, keeping the second pass, so
the tail of each loop's end is already sounding at its start (no gap, and no
reverb build-up when it repeats).

Stems (all on one timeline):
  foundation   permanent, never varies with distance: double bass, pizzicato
               chords, light percussion, AND a soft CORE MELODY (pizzicato
               violins; bowed strings in the B section) that carries every
               passage the woodwinds carry, so nothing goes missing when the
               critters are far away.
  clarinet     optional -- its critter: the original clarinet part
  bassoon      optional -- the original bassoon part
  flute        optional -- the original flute part
  ensemble     optional, shared by every other critter on the floor: the
               French horn (the original's sustains, plus a few added in A'
               and C so it's heard more often)
"""
import json
import os
import sys
import wave

import numpy as np
import mido
import fluidsynth

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "LivingOffice-v1"))   # (in the project: Music/)
import compose as V1                                     # (Version 1's notes, exactly as composed)

SR = 44100
BPM = V1.BPM
LOOP_BARS = 42
LOOP_BEATS = LOOP_BARS * 4
LOOP_SAMPLES = int(round(LOOP_BEATS * 60 / BPM * SR))
SF2 = "/usr/share/sounds/sf2/TimGM6mb.sf2"


def in_loop(notes):
    return [(s, d, n, v) for s, d, n, v in notes if s < LOOP_BEATS]


def notes_in(track, b0, b1):
    """The track's notes from beat b0 to b1."""
    return [x for x in track.notes if b0 <= x[0] < b1]


# ------------------------------------------------------------------ the core melody (foundation)
core = V1.Track("Core melody (pizzicato violins)", 45, 6, vol=104, pan=60)
core_b = V1.Track("Core melody B (strings)", 49, 7, vol=96, pan=60)
_saved = V1.Track.boost
V1.theme(core, 5, vel=70, staccato=0.5)                  # A: the theme
V1.theme(core, 13, vel=62, staccato=0.5)                 # A': the theme again, softer (the bassoon has it)
for s, d, n, v in notes_in(V1.flute, 80, 112):           # B: the flute's song, on bowed strings an octave down
    core_b.add(s, d, n - 12, int(v * 0.8))
for s, d, n, v in notes_in(V1.bsn, 112, 136):            # C: the bassoon's creep, an octave up
    core.add(s, d, n + 12, int(v * 0.85))
for i in range(6):                                       # A'': the first six bars of the theme
    t = (35 + i - 1) * 4
    for name, d in V1.THEME[i]:
        n = V1.p(name)
        if n is not None:
            core.add(t, d * (0.5 if d <= V1.e else 0.85), n, 66)
        t += d
for s, d, n, v in notes_in(V1.bsn, 160, 168):            # the turnaround's little run
    core.add(s, d, n + 12, int(v * 0.85))

# ------------------------------------------------------------------ the ensemble (shared) -- more horn
ens = V1.Track("Ensemble (French horn)", 60, 5, vol=96, pan=70)
ens.notes = in_loop(V1.horn.notes)
for bar, n in zip(range(13, 21), ["F3", "F3", "Bb3", "C#4", "D4", "C4", "Bb3", "A3"]):
    ens.add((bar - 1) * 4, 3.6, V1.p(n), 48)
for bar, n in zip(range(29, 35), ["Bb3", "C#4", "Bb3", "C#4", "D4", "C#4"]):
    ens.add((bar - 1) * 4, 1.8, V1.p(n), 44)

STEMS = {
    "foundation": [V1.bass, V1.pizz, V1.perc, core, core_b],
    "clarinet": [V1.clar],
    "bassoon": [V1.bsn],
    "flute": [V1.flute],
    "ensemble": [ens],
}


# ------------------------------------------------------------------ MIDI
def midi_for(tracks, repeats=1, name="Hallways -- The Living Orchestra (loop)"):
    TPB = V1.TPB
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
        for cc, val in [(7, tr.vol), (10, tr.pan), (91, 46)]:
            ev.append((0, 0, mido.Message("control_change", control=cc, value=val, channel=tr.channel)))
        for k in range(repeats):
            off = k * LOOP_BEATS
            for s, d, n, v in in_loop(tr.notes):
                on = int(round((s + off) * TPB))
                end = min(s + d, LOOP_BEATS) + off                  # (nothing held over the loop point)
                offt = max(on + 10, int(round(end * TPB)))
                ev.append((on, 1, mido.Message("note_on", note=n, velocity=max(1, min(127, int(v))), channel=tr.channel)))
                ev.append((offt, 0, mido.Message("note_off", note=n, velocity=0, channel=tr.channel)))
        ev.sort(key=lambda x: (x[0], x[1]))
        last = 0
        for t, _, m in ev:
            mt.append(m.copy(time=t - last))
            last = t
        mid.tracks.append(mt)
    return mid


# ------------------------------------------------------------------ rendering
def render(mid, total_samples):
    fs = fluidsynth.Synth(samplerate=float(SR), gain=0.5)
    sfid = fs.sfload(SF2)
    for ch in range(16):
        fs.program_select(ch, sfid, 128 if ch == 9 else 0, 0)
    fs.set_reverb(roomsize=0.45, damping=0.4, width=0.8, level=0.55)
    out = np.zeros((total_samples, 2), dtype=np.float32)
    pos = 0
    t_abs = 0.0
    for msg in mid:
        t_abs += msg.time
        target = min(total_samples, int(round(t_abs * SR)))
        if target > pos:
            out[pos:target] = np.array(fs.get_samples(target - pos), dtype=np.float32).reshape(-1, 2)
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
    if pos < total_samples:
        out[pos:] = np.array(fs.get_samples(total_samples - pos), dtype=np.float32).reshape(-1, 2)
    fs.delete()
    return out


def write_wav(path, x):
    pcm = np.clip(x * 32767, -32768, 32767).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "loop"
    os.makedirs(out, exist_ok=True)
    # The whole loop as one MIDI (all parts), and one MIDI per stem -- for re-rendering
    # with proper orchestral instruments (Logic / GarageBand), same names, same length.
    midi_for([t for ts in STEMS.values() for t in ts]).save(os.path.join(out, "living-orchestra-loop.mid"))
    stems = {}
    for name, tracks in STEMS.items():
        midi_for(tracks, name=f"Living Orchestra -- {name}").save(os.path.join(out, f"orchestra-{name}.mid"))
        two = render(midi_for(tracks, repeats=2), 2 * LOOP_SAMPLES)
        stems[name] = two[LOOP_SAMPLES:]                         # the second pass: tails already wrapped round
        print(name, "rendered")
    # One scale for every stem (their balance is the arrangement's): everything at full
    # gain together peaks at -3 dBFS.
    total = sum(stems.values())
    scale = (10 ** (-3 / 20)) / max(1e-9, float(np.abs(total).max()))
    for name, x in stems.items():
        write_wav(os.path.join(out, f"orchestra-{name}.wav"), x * scale)
    write_wav(os.path.join(out, "orchestra-all-at-full.wav"), total * scale)
    write_wav(os.path.join(out, "orchestra-foundation-only.wav"), stems["foundation"] * scale)
    def rms_db(x):
        return round(float(20 * np.log10(np.sqrt(np.mean(x.astype(np.float64) ** 2)) + 1e-12)), 1)
    info = {"sampleRate": SR, "loopSamples": LOOP_SAMPLES, "bpm": BPM, "bars": LOOP_BARS, "scale": float(scale),
            "stems": {n: {"rms_dB": rms_db(x * scale), "peak_dB": round(float(20 * np.log10(np.abs(x * scale).max() + 1e-12)), 1)}
                      for n, x in stems.items()},
            "allAtFull": {"rms_dB": rms_db(total * scale)}}
    json.dump(info, open(os.path.join(out, "info.json"), "w"), indent=1)
    print(json.dumps(info, indent=1))
