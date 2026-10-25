"""Render a MIDI file offline through FluidSynth (General MIDI soundfont) to WAV."""
import sys
import wave
import numpy as np
import mido
import fluidsynth

SR = 44100
mid_path, sf2, out = sys.argv[1], sys.argv[2], sys.argv[3]

fs = fluidsynth.Synth(samplerate=float(SR), gain=0.5)
sfid = fs.sfload(sf2)
for ch in range(16):
    fs.program_select(ch, sfid, 128 if ch == 9 else 0, 0)
fs.set_reverb(roomsize=0.45, damping=0.4, width=0.8, level=0.55)

mid = mido.MidiFile(mid_path)
chunks = []
pending = 0.0
for msg in mid:                       # merged, times in seconds
    pending += msg.time
    n = int(round(pending * SR))
    if n > 0:
        chunks.append(np.array(fs.get_samples(n), dtype=np.int16))
        pending -= n / SR
    if msg.is_meta:
        continue
    t = msg.type
    if t == "note_on":
        fs.noteon(msg.channel, msg.note, msg.velocity)
    elif t == "note_off":
        fs.noteoff(msg.channel, msg.note)
    elif t == "program_change":
        fs.program_select(msg.channel, sfid, 128 if msg.channel == 9 else 0, msg.program)
    elif t == "control_change":
        fs.cc(msg.channel, msg.control, msg.value)
chunks.append(np.array(fs.get_samples(int(SR * 2.5)), dtype=np.int16))   # let the room ring out
audio = np.concatenate(chunks).astype(np.float32)
peak = np.abs(audio).max()
import os
if os.environ.get("RAW"):
    rms = np.sqrt((audio[audio != 0] ** 2).mean()) if (audio != 0).any() else 0
    print("RMS_DB", round(20 * np.log10(rms / 32767 + 1e-12), 1)); sys.exit(0)
audio = (audio / peak * 0.89 * 32767).astype(np.int16)                 # normalise to about -1 dBFS
with wave.open(out, "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(audio.tobytes())
print(out, f"{len(audio) / 2 / SR:.1f} s, peak was {peak:.0f}")
fs.delete()
