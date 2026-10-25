"""PP 7: each floor song's chord map (hallways-song-harmony/1), read from the compositions' own sources,
cross-checked against their bass MIDI (the bass's note at every chord change = the chord's bass)."""
import re, json, sys, mido
U = "/mnt/user-data/uploads/Hallways"
HO = U + "/Music/HallwaysOriginals"
lk = open(HO + "/06-Music-Lab-Level-3/source/labkit.py").read()
ns = {}
exec(re.search(r"(?s)^PC = .*?\n\n", lk, re.M).group(0), ns)
exec(re.search(r"(?s)^QUAL = .*?\n\n", lk, re.M).group(0), ns)
PC, QUAL = ns["PC"], ns["QUAL"]

def chord(sym):
    bass = None
    s = sym
    if "/" in s:
        s, b = s.split("/"); bass = PC[b]
    root = s[:2] if len(s) > 1 and s[1] in "b#" else s[:1]
    r = PC[root]
    tones = []
    for i in QUAL[s[len(root):]]:
        if (r + i) % 12 not in tones: tones.append((r + i) % 12)
    return tones, (bass if bass is not None else r)

def grab(path, names):
    src = open(path).read(); g = {}
    for nm in names:
        m = re.search(rf"(?ms)^{nm} = .*?\n(?=\S)", src); exec(m.group(0), g)
    return g

def bars_from(prog):       # [[(beat, sym)]] -> [[{beat, chord, tones}]]
    return [[{"beat": b, "chord": s, "tones": chord(s)[0]} for b, s in bar] for bar in prog]

def check(bars, mid, bpb, tol=0.25):
    m = mido.MidiFile(mid); tpb = m.ticks_per_beat; t = 0; notes = []
    for msg in mido.merge_tracks(m.tracks):
        t += msg.time
        if msg.type == "note_on" and msg.velocity > 0: notes.append((t / tpb, msg.note))
    bad = []
    global soft
    soft = []
    for i, bar in enumerate(bars):
        for c in bar:
            at = i * bpb + c["beat"]
            near = sorted((abs(b - at), n) for b, n in notes if abs(b - at) <= tol)
            if not near or near[0][1] % 12 not in c["tones"]: bad.append((i + 1, c["beat"] + 1, c["chord"], near[:1]))
            elif near[0][1] % 12 != c["tones"][0] and (c["chord"].count("/") == 0): soft.append((i + 1, c["chord"], near[0][1]))
    return bad

out = {}
# Going Up! (swing.py): loop = head chorus (A1 A2 BR A3) + feature chorus (A1 A2 BR A3 shout), t = 0
g = grab(HO + "/02-Going-Up/source/swing.py", ["A1", "A2", "BR", "A3"])
gp = (g["A1"] + g["A2"] + g["BR"] + g["A3"]) * 2
out["going-up"] = ("goingup", 4, bars_from(gp), HO + "/02-Going-Up/midi/loop-gloria.mid",
    "Music/HallwaysOriginals/02-Going-Up/source/swing.py -- build_loop(): head_chorus (A1 A2 BR A3) + feature_chorus (A1 A2 BR A3, the shout); t = 0 (B-flat). Chord tones: labkit.py QUAL.")
# The Lantern Room (lantern.py): loop = CH (16) + CH[:8] + CH[8:]
g = grab(HO + "/06-Music-Lab-Level-3/source/lantern.py", ["CH"])
lp = [[(0, s)] for s in g["CH"] + g["CH"][:8] + g["CH"][8:]]
out["lantern-room"] = ("lanternroom", 3, bars_from(lp), HO + "/06-Music-Lab-Level-3/midi/lantern-room/loop-basses.mid",
    "Music/HallwaysOriginals/06-Music-Lab-Level-3/source/lantern.py -- build_loop(): CH (bars 1-16), CH[:8] (17-24), CH[8:] (25-32). Chord tones: labkit.py QUAL.")
# Rua das Lampadas (bossa.py + bossa_vocal.py build_loop): A A BR A
g = grab(HO + "/06-Music-Lab-Level-3/source/bossa.py", ["A", "BR"])
rp = g["A"] + g["A"] + g["BR"] + g["A"]
out["rua-das-lampadas"] = ("ruadaslampadas", 4, bars_from(rp), HO + "/06-Music-Lab-Level-3/midi/rua-das-lampadas/loop-bass.mid",
    "Music/HallwaysOriginals/06-Music-Lab-Level-3/source/bossa.py (A, BR) in bossa_vocal.py build_loop(): verse A, verse A, bridge BR, verse A. Chord tones: labkit.py QUAL.")
# The Night Shift Waltz: PP 6's map (voices-nightshift.json), one chord a bar
v1 = json.load(open(U + "/Hallways/MusicLab/voices-nightshift.json"))
out["night-shift-waltz"] = ("nightshift", 3, [[{"beat": 0, "chord": b["chord"], "tones": b["tones"]}] for b in v1["bars"]],
    U + "/Music/HallwaysOriginals/01-The-Night-Shift-Waltz/midi/loop-gloria.mid", v1["source"])

for cid, (slug, bpb, bars, mid, src) in out.items():
    bad = check(bars, mid, bpb) if cid != "night-shift-waltz" else check(bars, mid, bpb)
    print(cid, "bars", len(bars), "changes", sum(len(b) for b in bars), "bass NOT a chord tone:", bad[:6], len(bad),
          "| bass on another chord tone (a held chord's 2nd bar):", len(soft), soft[:4])
    json.dump({"format": "hallways-song-harmony/1", "composition": cid, "beatsPerBar": bpb, "source": src, "bars": bars},
              open(f"song-harmony-{slug}.json", "w"), indent=1)
