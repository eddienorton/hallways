"""Audition phrases: a 3-5 second signature for each instrument, in its natural register, with sustained
notes where the instrument sustains (Oct 25 2026, Claudette). Compact note data -> band-auditions.json:
  {instrument: {"bpm": n, "notes": [[beat, beats, midi, velocity], ...], "seconds": s}}
Written to be reusable later as the residents' own signatures in the hallways (not wired there yet)."""
import json, sys
sys.path.insert(0, "/home/claude/lab")
from labkit import n

def ph(bpm, *notes):
    out = []
    for t, d, p, v in notes:
        ps = p if isinstance(p, (list, tuple)) else [p]
        for k, q in enumerate(ps):
            out.append([t, d, n(q) if isinstance(q, str) else q, v])
    end = max(t + d for t, d, _, _ in out)
    return {"bpm": bpm, "notes": out, "seconds": round(end * 60 / bpm + 1.2, 2)}

P = {
    # low strings, low brass
    "upright_bass": ph(112, (0, .9, "G2", 92), (1, .9, "B2", 84), (2, .9, "D3", 86), (3, .9, "E3", 84),
                       (4, .9, "F3", 90), (5, .9, "E3", 82), (6, .9, "D3", 84), (7, .9, "B2", 82), (8, 2, "G2", 96)),
    "electric_bass": ph(100, (0, .7, "E2", 100), (1, .3, "E2", 80), (1.5, .4, "G2", 92), (2, .7, "A2", 96), (3, .4, "B2", 90),
                        (3.5, .4, "A2", 84), (4, .4, "G2", 88), (4.5, .4, "E2", 86), (5, 2, "E2", 102)),
    "tuba": ph(72, (0, 1.4, "Bb1", 96), (1.5, .45, "F2", 88), (2, .9, "D2", 92), (3, 2.2, "Bb1", 100)),
    # keys
    "piano": ph(104, (0, .5, "C5", 84), (.5, .5, "E5", 80), (1, .5, "G5", 86), (1.5, .5, "A5", 82), (2, 1, "G5", 88),
                (3, .5, "E5", 78), (3.5, .5, "D5", 76), (4, 3, ["C4", "E4", "G4", "C5"], 82)),
    "electric_piano": ph(84, (0, 1.9, ["F3", "A3", "C4", "E4"], 78), (2, .9, ["E3", "G3", "B3", "D4"], 72),
                         (3, 3, ["D3", "F3", "A3", "C4", "E4"], 80)),
    "organ": ph(92, (0, 1.9, ["C4", "E4", "G4"], 96), (2, 1.9, ["C4", "F4", "A4"], 96), (4, .9, ["B3", "D4", "G4"], 96),
                (5, 2.5, ["C4", "E4", "G4", "C5"], 100)),
    # guitars, harp
    "nylon_guitar": ph(96, (0, 3, "C3", 84), (.5, 2.5, "G3", 74), (1, 2, "C4", 76), (1.5, 1.5, "E4", 80), (2, 1, "G4", 82),
                       (2.5, .5, "E4", 76), (3, 3, ["C3", "G3", "C4", "E4", "G4"], 86)),
    "electric_guitar": ph(104, (0, .5, "A3", 88), (.5, .5, "C4", 86), (1, .5, "D4", 90), (1.5, .5, "E4", 92), (2, .5, "G4", 90),
                          (2.5, .5, "A4", 96), (3, .5, "G4", 86), (3.5, .5, "E4", 84), (4, 2.5, "A3", 94)),
    "harp": ph(112, *[(i * .25, 4 - i * .25, p, 74 + i * 2) for i, p in enumerate(["C3", "E3", "G3", "C4", "E4", "G4", "C5", "E5", "G5"])],
               (4, 3, ["F3", "A3", "C4", "F4", "A4"], 80)),
    # mallets
    "marimba": ph(100, (0, 1, "G4", 92), (1, 1, "B4", 88), (2, 1, "D5", 90), (3, 1.5, "G5", 96), (5, .5, "E5", 84),
                  (5.5, .5, "C5", 82), (6, 2, "G4", 90)),
    "vibraphone": ph(88, (0, 1, "E4", 80), (1, 1, "G4", 78), (2, 1, "B4", 82), (3, 1, "D5", 84),
                     (4, 3.5, ["C4", "E4", "G4", "B4"], 82)),
    "glockenspiel": ph(116, (0, .5, "C6", 90), (.5, .5, "E6", 86), (1, .5, "G6", 88), (1.5, 1, "C7", 94), (3, .5, "G6", 84),
                       (3.5, .5, "E6", 82), (4, 2, "C6", 90)),
    # bowed
    "violin": ph(80, (0, .5, "G4", 78), (.5, .5, "B4", 80), (1, .5, "D5", 84), (1.5, 1.5, "G5", 90), (3, .5, "F#5", 82),
                 (3.5, .5, "E5", 80), (4, 2, "D5", 86)),
    "cello": ph(72, (0, 1, "G2", 84), (1, 1, "D3", 86), (2, 1.5, "B3", 92), (3.5, .5, "A3", 84), (4, 2, "G3", 88)),
    # winds
    "flute": ph(96, (0, .5, "C5", 76), (.5, .5, "D5", 78), (1, .5, "E5", 80), (1.5, .5, "G5", 82), (2, 1.5, "C6", 88),
                (3.5, .5, "A5", 80), (4, .5, "G5", 78), (4.5, 2, "E5", 82)),
    "clarinet": ph(84, (0, .5, "D4", 80), (.5, .5, "F4", 82), (1, .5, "A4", 84), (1.5, 1.5, "C5", 88), (3, .5, "Bb4", 82),
                   (3.5, .5, "A4", 80), (4, 2, "G4", 84)),
    "harmonica": ph(100, (0, .5, "C5", 90), (.5, .5, "E5", 92), (1, 1, "G5", 96), (2, .5, "E5", 88), (2.5, .5, "D5", 86),
                    (3, 2.5, ["C5", "E5"], 94)),
    "tenor_sax": ph(92, (0, .5, "A3", 88), (.5, .5, "C4", 90), (1, .5, "D4", 92), (1.5, .5, "E4", 94), (2, 1.5, "G4", 98),
                    (3.5, .5, "E4", 88), (4, .5, "D4", 86), (4.5, 2, "A3", 92)),
    # brass
    "french_horn": ph(76, (0, .9, "C4", 84), (1, .9, "G4", 88), (2, 1.5, "C5", 94), (3.5, .5, "Bb4", 86), (4, 2, "G4", 90)),
    "trumpet": ph(112, (0, .4, "G4", 96), (.5, .4, "C5", 98), (1, .4, "E5", 100), (1.5, 1.2, "G5", 104), (3, .4, "E5", 96),
                  (3.5, .4, "G5", 100), (4, 2.5, "C6", 108)),
    "trombone": ph(80, (0, .9, "F3", 88), (1, .9, "A3", 90), (2, 1.5, "C4", 96), (3.5, .5, "Bb3", 88), (4, .9, "A3", 88),
                   (5, 2, "F3", 94)),
}
# rhythm: GM drum keys (band-drums.sf2), the congas & percussion keys (band-percussion.sf2)
groove = []
for k in range(8):
    groove.append([k * .5, .2, 42, 74 if k % 2 == 0 else 52])
groove += [[0, .2, 36, 100], [1, .2, 38, 104], [1.5, .2, 36, 84], [2, .2, 36, 98], [3, .2, 38, 106]]
groove += [[4 + i * .25, .2, m, 80 + 4 * i] for i, m in enumerate([38, 38, 50, 50, 47, 47, 45, 45])]
groove += [[6, 2, 49, 110], [6, .2, 36, 110]]
P["drums"] = {"bpm": 104, "notes": groove, "seconds": round(8 * 60 / 104 + 1.2, 2)}
tumbao = []
for bar in range(2):
    b = bar * 4
    tumbao += [[b + 0, .3, 60, 50], [b + 1, .3, 60, 46], [b + 1.5, .3, 63, 84], [b + 2, .3, 60, 48], [b + 3, .3, 64, 92], [b + 3.5, .3, 64, 86]]
    tumbao += [[b + k * .5, .2, 70 if k % 2 == 0 else 71, 52 if k % 2 == 0 else 40] for k in range(8)]
    tumbao += [[b + t, .2, 75, 70] for t in ((0, 1.5, 3) if bar == 0 else (1, 2.5))]
tumbao += [[8, .3, 62, 96], [8, .3, 64, 96]]
P["percussion"] = {"bpm": 112, "notes": tumbao, "seconds": round(8 * 60 / 112 + 1.4, 2)}

if __name__ == "__main__":
    json.dump(P, open("/home/claude/band/out/band-auditions.json", "w"), separators=(",", ":"))
    print(len(P), "phrases", {k: v["seconds"] for k, v in P.items()})
