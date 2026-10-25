"""Render a genre audition: python3 audition.py <module> [check]

  check   only the harmony check (half-step rubs between pitched parts)
  else    render every part with its engine, balance (active loudness), pan, room;
          write the full excerpt, the listening combinations, each part alone, MIDI, and stems (npy) for later.
"""
import sys, os, json, importlib, collections
import numpy as np
sys.path.insert(0, "/home/claude/lab"); sys.path.insert(0, "/home/claude/lab/genres")
import studio as S
from labkit import midi_for, SR

NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]


def clash(P, beats, label, window=1.0, ignore=(), bpb=4):
    global BPB_
    BPB_ = bpb
    notes = {w: [(s, s + d, m) for (s, d, m, v) in p.notes] for w, p in P.items()
             if p.engine[0] != "perc" and p.channel != 9 and w not in ignore}
    issues = collections.Counter()
    t = 0.0
    while t < beats:
        sounding = [(w, m) for w in notes for s, e, m in notes[w] if s <= t < e and t - s < window]
        for i in range(len(sounding)):
            for k in range(i + 1, len(sounding)):
                a, b = sounding[i], sounding[k]
                if a[0] != b[0] and abs(a[1] - b[1]) in (1, 13, 25):
                    issues[(int(t // BPB_) + 1, a[0], NAMES[a[1] % 12] + str(a[1] // 12 - 1), b[0], NAMES[b[1] % 12] + str(b[1] // 12 - 1))] += 1
        t += 0.25
    print(f"--- {label}: {len(issues)} half-step rubs")
    for k, c in sorted(issues.items()):
        print("  bar %3d: %s %s vs %s %s x%d" % (k + (c,)))
    return issues


def main():
    mod = importlib.import_module(sys.argv[1])
    P, tempo, beats = mod.build()
    clash(P, beats, mod.TITLE, ignore=getattr(mod, "CLASH_IGNORE", ()), bpb=getattr(mod, "BPB", 4))
    if len(sys.argv) > 2 and sys.argv[2] == "check":
        return
    out = f"/home/claude/lab/deliver/04-Genre-Auditions/{mod.SLUG}"
    os.makedirs(f"{out}/midi", exist_ok=True)
    os.makedirs(f"{out}/parts", exist_ok=True)
    T = int((S.beats_to_sec(tempo)(beats) + 2.5) * SR)
    raw = {}
    for w in mod.WHO:
        p = P[w]
        raw[w] = S.render_part(p, tempo, beats, T).astype(np.float64)
        print("rendered", w, round(S.active_rms(raw[w]), 1), flush=True)
        midi_for([p], tempo, beats, name=f"{mod.TITLE} -- {p.name}").save(f"{out}/midi/{w}.mid")
    midi_for([P[w] for w in mod.WHO], tempo, beats, name=f"{mod.TITLE} -- all").save(f"{out}/midi/all.mid")
    irs = S.room_ir(rt=getattr(mod, "RT", 1.6))
    stem = {}
    for w in mod.WHO:
        g = 10 ** ((mod.LEVELS[w] - S.active_rms(raw[w])) / 20)
        x = S.place(raw[w] * g, mod.PAN.get(w, 0))
        stem[w] = S.add_room(x, irs, mod.ROOM.get(w, 0.2))
    full = sum(stem.values())
    S.write_m4a(f"{out}/00-{mod.SLUG}-full.m4a", S.finish(full, -17.5))
    for i, (ws, label) in enumerate(mod.COMBOS, 1):
        S.write_m4a(f"{out}/{i:02d}-{label}.m4a", S.finish(sum(stem[w] for w in ws), -18.5))
    for w in mod.WHO:
        S.write_m4a(f"{out}/parts/{w}.m4a", S.finish(stem[w], -20))
    np.save(f"/home/claude/lab/genres/{mod.SLUG}-stems.npy", np.stack([stem[w] for w in mod.WHO]).astype(np.float32))
    json.dump({"who": mod.WHO, "seconds": T / SR, "levels": mod.LEVELS}, open(f"/home/claude/lab/genres/{mod.SLUG}-info.json", "w"))
    print("done", out, round(T / SR, 1), "s")


if __name__ == "__main__":
    main()
