# 10 — The four compositions, developed into whole pieces (Oct 25 2026)

Each composition is now a finished piece with an ending, not a loop. The template has `"loop": false`. The app plays it once, lets it ring out for 2 s, and returns to ready with the band kept.

| Piece | Bars | Length | Sections |
|---|---|---|---|
| Night Porter (blues, G, 100 bpm) | 70 | 2:48 | Intro 4 / Head 12 / Solo (Answers layer) 12 / Breakdown 12 / Trading (Melody and Harmony) 12 / Shout 12 / Head out 4 / Ending 2 |
| Rua das Lâmpadas (bossa, D then E, 140 bpm) | 82 | 2:21 | Intro 4 / A A B A 32 / Solo (Answers) 8 / Solo (Harmony) 8 / B, trading 8 / Bass break 4 / Return, lift to E 4 / Last A in E 8 / Tag 5 / Ending 1 |
| Rock Shuffle (A, 132 bpm, shuffle) | 70 | 2:07 | Intro riff 4 / Verse 12 / Chorus 8 / Verse 12 / Chorus 8 / Break (stop-time solo, then bass alone) 12 / Last chorus 8 / Tag 4 / Ending 2 |
| Minuet and Trio (G and C, 3/4, 120 bpm) | 96 | 2:24 | Minuet 32 (A A B A) / Trio 32 (C C D C) / Link 2 / Minuet da capo 24 (A dressed up, B, A) / Coda 6 |

The layer stacks are unchanged.

## Files

| File | What it is |
|---|---|
| `compose_*_full.py` | The scores. `tplkit.py` is the `Piece` builder. |
| `lab-harness.js`, `scenarios/` | Each piece with a conventional band and an odd one, including joins and leaves mid-piece. |
| `renders/*.m4a` | Offline FluidSynth renders through the app's SoundFonts. Nobody has listened to them yet. |
| `renders/structure.png` | Which layer plays where. |

Night Porter is marked `"sung": false`. Its old Hallenese clips were sung for the 24-bar loop and don't match the new piece, so singers show "can't be sung yet" on it until it's re-sung.
