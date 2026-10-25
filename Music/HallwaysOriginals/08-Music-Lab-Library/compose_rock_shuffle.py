"""ROCK SHUFFLE -- a new Hallways composition (Claudette, Oct 25 2026). Rock / shuffle, A, 132 bpm, 4/4,
swung eighths (written straight here, played on the triplet: x.5 -> x.667).

The hook: "da-da-da-da DAAH, da" climbing the A blues scale to E, then a leap to the top A and a tumble
home -- twice over A7, the same over D7 (a blues does that); a turnaround line over E7-D7; a pickup home.
In the hook's rests the answers punch back in thirds ("bap-bap BAAH"). Underneath, the boogie bass walks
1-3-5-6-b7-6-5-3 the whole way, the stabs chop the backbeat, and in the second chorus a slow long-note
line rises over the top.

24 bars (two choruses; the second's last bar turns back to the first). Layers, foundation up:
  1 Boogie bass   2 Drums   3 Chord stabs   4 Hook   5 Answers   6 Long notes (second chorus only)
"""
import sys
sys.path.insert(0, "/home/claude/band/templates")
from tplkit import part, groove, write, n, sw

BPM = 132
FORM = ["A7", "A7", "A7", "A7", "D7", "D7", "A7", "A7", "E7", "D7", "A7", "E7"]
ROOT = {"A7": "A1", "D7": "D2", "E7": "E2"}
TONES = {"A7": ["C#4", "E4", "G4"], "D7": ["C4", "D4", "F#4"], "E7": ["D4", "E4", "G#4"]}
GUIDE = {"A7": "G4", "D7": "F#4", "E7": "G#4"}

HOOK = [(0, .5, "A4"), (.5, .5, "C5"), (1, .5, "D5"), (1.5, .5, "Eb5"), (2, 1.5, "E5"), (3.5, .5, "G5")]
HOOK2 = [(0, 1, "A5"), (1, .5, "G5"), (1.5, .5, "E5"), (2, 1.5, "A4")]
TURN9 = [(0, .5, "B4"), (.5, .5, "D5"), (1, 1, "E5"), (2, .5, "D5"), (2.5, .5, "B4"), (3, 1, "G#4")]
TURN10 = [(0, .5, "A4"), (.5, .5, "C5"), (1, 1, "D5"), (2, .5, "C5"), (2.5, .5, "A4"), (3, 1, "F#4")]
HOME11 = [(0, 2, "A4"), (2.5, .5, "C5"), (3, .5, "C#5"), (3.5, .5, "E5")]
HOME12 = [(0, 1.5, "E5"), (2, .5, "D5"), (2.5, .5, "B4"), (3, 1, "G#4")]
# chorus 2: the same hook, then a higher turnaround (more urgency), home the same way
TURN9B = [(0, .5, "E5"), (.5, .5, "G#5"), (1, 1, "B5"), (2, .5, "G#5"), (2.5, .5, "E5"), (3, 1, "D5")]
TURN10B = [(0, .5, "D5"), (.5, .5, "F#5"), (1, 1, "A5"), (2, .5, "F#5"), (2.5, .5, "D5"), (3, 1, "C5")]
MEL = {1: HOOK, 2: HOOK2, 5: HOOK, 6: HOOK2, 9: TURN9, 10: TURN10, 11: HOME11, 12: HOME12}
MEL2 = {1: HOOK, 2: HOOK2, 5: HOOK, 6: HOOK2, 9: TURN9B, 10: TURN10B, 11: HOME11, 12: HOME12}
# answers, in thirds: in the hook's rests (bars 3-4, 7-8) and a kick at the end of the chorus
ANS = {3: [(1, .25, "E5", "C#5"), (1.5, .25, "E5", "C#5"), (2, 1.5, "G5", "E5")],
       4: [(1, .5, "E5", "C#5"), (1.5, .5, "D5", "B4"), (2, 1, "C#5", "A4")],
       7: [(1, .25, "E5", "C#5"), (1.5, .25, "E5", "C#5"), (2, 1.5, "G5", "E5")],
       8: [(1, .5, "G5", "E5"), (1.5, .5, "F#5", "D5"), (2, 1.5, "E5", "C#5")],
       12: [(3.5, .5, "G#5", "E5")]}
ANS2 = dict(ANS)
ANS2[4] = [(0, .5, "A5", "E5"), (.5, .5, "G5", "E5"), (1, .5, "E5", "C#5"), (2, 1, "C#5", "A4")]
ANS2[8] = [(0, .5, "A5", "E5"), (.5, .5, "G5", "E5"), (1, 1, "A5", "E5")]
# long notes in chorus 2: guide tones held across bars, rising at the turnaround
LONG = [(12, 4, "G4"), (13, 4, "G4"), (14, 2, "A4"), (16, 4, "F#4"), (17, 4, "A4"), (18, 8, "G4"),
        (20, 4, "G#4"), (21, 4, "A4"), (22, 3, "C#5"), (23, 4, "B4")]


def main():
    bass, stabs, mel, ans, long_, hits = [], [], [], [], [], []
    for c in range(2):
        for i, sym in enumerate(FORM):
            bar = c * 12 + i
            b0 = bar * 4
            # boogie bass: 1 3 5 6 b7 6 5 3, swung, the last bar of the chorus walking up to the root
            r = n(ROOT[sym])
            ivs = [0, 4, 7, 9, 10, 9, 7, 4] if i != 11 else [0, 4, 7, 9, 10, 9, 7, 6]
            for k, iv in enumerate(ivs):
                bass.append((b0 + sw(k * .5), .55 if k % 2 == 0 else .3, r + iv, 92 if k % 2 == 0 else 78))
            # stabs: the backbeat (2 and 4), short; a push on the last eighth of bars 4, 8, 12
            for beat, d, v in [(1, .3, 70), (3, .3, 74)] + ([(sw(3.5), .3, 66)] if i in (3, 7, 11) else []):
                s = sym if beat < 3.5 else FORM[(i + 1) % 12]
                for m in TONES[s]:
                    stabs.append((b0 + beat, d, n(m), v))
            # drums: shuffle hats, kick 1 & 3 (and the a of 2), snare 2 & 4; crash at each chorus' top;
            # a fill (triplets down the toms) in each chorus' last bar
            fill = i == 11
            for k in range(8):
                if fill and k >= 4: continue
                hits.append((b0 + sw(k * .5), "hat", 72 if k % 2 == 0 else 50))
            for beat in (0, 2):
                hits.append((b0 + beat, "kick", 96))
            hits.append((b0 + sw(1.5), "kick", 70))
            hits.append((b0 + 1, "snare", 100))
            if not fill: hits.append((b0 + 3, "snare", 104))
            if i == 0: hits.append((b0, "crash", 104))
            if fill:
                for k, (t, pc) in enumerate([(2, "snare"), (2 + 1/3, "snare"), (2 + 2/3, "tomhi"), (3, "tomhi"), (3 + 1/3, "tomlo"), (3 + 2/3, "tomlo")]):
                    hits.append((b0 + t, pc, 70 + 6 * k))
        for bar, notes in (MEL if c == 0 else MEL2).items():
            for beat, d, name in notes:
                mel.append((c * 48 + (bar - 1) * 4 + sw(beat), d * .92, n(name), 96 if beat in (0, 2) else 88))
        for bar, notes in (ANS if c == 0 else ANS2).items():
            for beat, d, hi, lo in notes:
                for m, v in ((hi, 88), (lo, 82)):
                    ans.append((c * 48 + (bar - 1) * 4 + sw(beat), d * .9, n(m), v))
    for bar, d, name in LONG:
        long_.append((bar * 4, d - .1, n(name), 66))
    tpl = {
        "format": "hallways-composition/1", "id": "rock-shuffle", "title": "Rock Shuffle", "genre": "rock",
        "style": "Rock shuffle (boogie)", "source": "New for the Music Lab (Claudette), Oct 25 2026",
        "bpm": BPM, "meter": [4, 4], "key": "A", "feel": "shuffle (swung eighths, written on the triplet)",
        "bars": 24, "loop": True,
        "sections": [{"name": "Chorus 1", "start": 0, "bars": 12}, {"name": "Chorus 2", "start": 12, "bars": 12}],
        "chords": [[[0, s]] for s in FORM + FORM],
        "parts": [
            part("bass", "Boogie bass", "bass", bass, desc="1-3-5-6-b7-6-5-3 on every chord, swung, never stopping."),
            groove("drums", "Drums", hits, desc="Shuffle hats, kick 1 and 3, snare 2 and 4; a fill at the end of each chorus."),
            part("stabs", "Chord stabs", "comp", stabs, poly=3, art="staccato", desc="Short chords on 2 and 4; a push into bars 5, 9 and the top."),
            part("hook", "Hook", "melody", mel, art="legato", desc="The tune: up the blues scale to E, leap, tumble home; a turnaround."),
            part("answers", "Answers", "answer", ans, poly=2, art=lambda d: "accent" if d < .5 else None, desc="Punches in thirds in the hook's rests."),
            part("long", "Long notes", "pad", long_, desc="Second chorus: slow held notes rising over the top."),
        ],
        "layers": [{"part": "bass", "name": "Boogie bass"}, {"part": "drums", "name": "Drums"}, {"part": "stabs", "name": "Chord stabs"},
                   {"part": "hook", "name": "Hook"}, {"part": "answers", "name": "Answers"}, {"part": "long", "name": "Long notes"}],
    }
    write(tpl)


if __name__ == "__main__":
    main()
