import re, json, sys, mido
src = open(sys.argv[1]).read()
block = src[src.index("NAMES ="):src.index("PROG_LAMENT")]
block = re.sub(r"(?s)def n\(name\):.*?\n\n\n", "", block)
ns = {}
exec(block, ns)
NAMES=ns["NAMES"]
def n(name): return 12*(int(name[-1])+1)+NAMES[name[:-1]]
CH, A, B = ns["CH"], ns["PROG_A"], ns["PROG_B"]
prog = A + B + A
bars = []
for name in prog:
    root, fifth, third, gtr, kal = CH[name]
    tones = [n(root)%12, n(third)%12, n(fifth)%12]
    for x in gtr:
        if n(x)%12 not in tones: tones.append(n(x)%12)
    bars.append({"chord": name, "tones": tones})
# MIDI cross-check: the bass's first note in each bar (Gloria) = the chord root?
mid = mido.MidiFile(sys.argv[2]); tpb = mid.ticks_per_beat
t=0; first={}
for msg in mido.merge_tracks(mid.tracks):
    t += msg.time
    if msg.type=="note_on" and msg.velocity>0:
        bar = int(t // (3*tpb))
        first.setdefault(bar, msg.note)
bad=[(i+1, prog[i], first.get(i)) for i in range(48) if first.get(i) is None or first[i]%12 != bars[i]["tones"][0]]
print("bars", len(bars), "bass-downbeat mismatches:", bad)
# Eileen (guitar) pitch classes per bar vs chord tones (outside-tone count)
mid = mido.MidiFile(sys.argv[3]); t=0; out={}
for msg in mido.merge_tracks(mid.tracks):
    t += msg.time
    if msg.type=="note_on" and msg.velocity>0:
        bar=int(t//(3*tpb)); 
        if msg.note%12 not in bars[bar]["tones"]: out.setdefault(bar+1,[]).append(msg.note)
print("guitar notes outside chord tones (bar: notes):", out)
print("tempo msgs:", [m.tempo for tr in mid.tracks for m in tr if m.type=="set_tempo"], "tpb", tpb,
      "timesig:", [ (m.numerator,m.denominator) for tr in mid.tracks for m in tr if m.type=="time_signature"])
json.dump({"format":"hallways-voice-harmony/1","composition":"night-shift-waltz",
 "source":"Music/HallwaysOriginals/01-The-Night-Shift-Waltz/source/original1.py -- build_loop(): PROG_A (bars 1-16), PROG_B (17-32), PROG_A (33-48); chord tones from its CH voicing table (bass root, chord third, bass fifth, then the guitar voicing's other notes). Checked against midi/loop-gloria.mid (the bass's first note of every bar is the root).",
 "beatsPerBar":3,"bars":bars}, open("voices-nightshift.json","w"), indent=1)
