"""Side-by-side piano rolls of two arranger runs (the same composition, two bands): python3 roll2.py a.json a-sc.json b.json b-sc.json out.png [bars]"""
import json, sys, matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
bars = int(sys.argv[6]) if len(sys.argv) > 6 else 12
NAMES = {"hw.feddy": "Benny", "chair.1": "Chair", "jeff": "Tinky", "cast.telephone": "Telephone", "hw.stilts": "Eileen", "cast.camera": "Camera",
         "hw.bigfellow": "Big Fellow", "hw.clunk": "Clunk", "juanita": "Juanita", "butterfly": "Butterfly", "hw.sister": "Cecilia",
         "cast.stove": "Stove", "hw.oldgent": "Old Gent", "cast.mailbox": "Mailbox", "hw.pear": "Pear"}
COL = {"melody": "#c0392b", "bass line": "#5b4b8a", "chords": "#2e8b6e", "answers": "#d49a2a", "held chords": "#888", "harmony": "#b0517e"}
fig, axes = plt.subplots(2, 1, figsize=(16, 9), sharex=True)
for ax, (evp, scp) in zip(axes, [(sys.argv[1], sys.argv[2]), (sys.argv[3], sys.argv[4])]):
    ev = json.load(open(evp)); sc = json.load(open(scp)); roster = sc["roster"]
    seen = {}
    for b in ev["bars"][:bars]:
        for e in b["events"]:
            if e["type"] != "note" or roster[e["who"]] in ("drums", "percussion"): continue
            role = b["roles"][e["who"]]; c = COL.get(role.split(" (")[0], "#333")
            t = b["bar"] * 4 + e["t"]
            ax.plot([t, t + e["dur"]], [e["pitch"], e["pitch"]], color=c, lw=3.2, solid_capstyle="butt")
            seen[e["who"]] = (c, f"{NAMES.get(e['who'], e['who'])} ({roster[e['who']].replace('_', ' ')}): {role}")
    for k in range(0, bars * 4 + 1, 4): ax.axvline(k, color="#ddd", lw=.6)
    ax.legend([plt.Line2D([0], [0], color=c, lw=4) for c, _ in seen.values()], [l for _, l in seen.values()], loc="upper right", fontsize=10)
    ax.set_ylim(28, 100); ax.set_ylabel("MIDI pitch")
axes[0].set_title("Night Porter, bars 1-%d: the same template, two different bands (octave moves are the arranger's)" % bars)
axes[1].set_xlabel("beats")
plt.tight_layout(); plt.savefig(sys.argv[5], dpi=70)
