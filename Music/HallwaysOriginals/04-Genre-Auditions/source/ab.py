"""A/B: the same notes through FluidR3 GM (our old sound) and through the new instruments."""
import sys, numpy as np
sys.path.insert(0, "/home/claude/lab"); sys.path.insert(0, "/home/claude/lab/genres")
import studio as S, importlib
from labkit import SR
FR3 = "/usr/share/sounds/sf2/FluidR3_GM.sf2"
OUT = "/home/claude/lab/deliver/04-Genre-Auditions/instrument-AB"
import os; os.makedirs(OUT, exist_ok=True)
def run(modname, gm, seconds, tag):
    mod = importlib.import_module(modname)
    P, tempo, beats = mod.build()
    T = int(seconds * SR)
    irs = S.room_ir(rt=getattr(mod, "RT", 1.6))
    for label, swap in [("A-old-GM-FluidR3", True), ("B-new-sampled", False)]:
        mix = 0
        for w in mod.WHO:
            p = P[w]
            if swap and w in gm:
                p.engine = ("sf", FR3, gm[w])
            x = S.render_part(p, tempo, beats, T).astype(np.float64)
            if S.active_rms(x) < -100: continue
            g = 10 ** ((mod.LEVELS[w] - S.active_rms(x)) / 20)
            mix = mix + S.add_room(S.place(x * g, mod.PAN.get(w, 0)), irs, mod.ROOM.get(w, .2))
        S.write_m4a(f"{OUT}/{tag}-{label}.m4a", S.finish(mix, -18.5, fout=1.5)); print(tag, label)
run("lantern", {"glock": 9, "harp": 46, "flute": 73, "violin": 40, "violins": 48, "violas": 48, "cellos": 48, "basses": 43, "horn": 60}, 40, "Lantern-Room-opening")
run("bossa", {"flute": 73, "piano": 0, "bass": 32}, 36, "Bossa-opening")
