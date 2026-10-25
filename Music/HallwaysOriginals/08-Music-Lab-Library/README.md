# 08 — Music Lab library, Stage A (Oct 25 2026)

Stage A has one composition per genre. Each one is an instrument-independent template with its own layer stack. The layer order and the format are described in `07-Music-Lab-Layers/README.md`.

| Genre | Composition | Source | Bars, meter, tempo | Layers (in the order musicians receive them) |
|---|---|---|---|---|
| Blues | Night Porter | converted from Hallways Originals #3 (`soul.py`) | 24 bars of 4/4, 100 bpm | Bass line, Groove, Chords, Held chords, Melody, Answers, Harmony, Low harmony |
| Jazz | Rua das Lâmpadas | converted from Hallways Originals (`bossa.py`, `bossa_vocal.py`) | 32 bars of 4/4, 140 bpm | Bass, Bossa chords, Percussion, Melody, Answers, Harmony, Held chords |
| Rock | Rock Shuffle | new (`compose_rock_shuffle.py`) | 24 bars of 4/4 shuffle, 132 bpm | Boogie bass, Drums, Chord stabs, Hook, Answers, Long notes |
| Classical | Minuet | new (`compose_minuet.py`) | 32 bars of 3/4, 120 bpm | Bass, Pah-pah chords, Melody, Countermelody, Sparkles |

## Tools

- `tplkit.py` checks and writes templates.
- `lab-harness.js` and `render_lab.py` produce offline listening renders through the app's SoundFonts.
- `scenarios/` holds conventional and unusual build-ups for each piece (one musician joins every 4 bars). The renders are in `test-renders/`.
