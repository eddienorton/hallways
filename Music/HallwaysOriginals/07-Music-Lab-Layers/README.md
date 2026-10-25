# 07 — Music Lab: ordered musical layers (Oct 24 2026)

The idea: Claudette composes the music ahead of time; Hallways arranges and performs it with whichever musicians the player switches on.

## What's in the app (Hallways/MusicLab/)

| File | What it is |
|---|---|
| `comp-night-porter.json` | The first composition template (`hallways-composition/1`). It names no instruments. |
| `lab-arranger.js` | The performer. It decides how an instrument plays the layer it was given (octave, chord notes, articulation); it runs on the device in JavaScriptCore. Which musician holds which layer is set by activation order in MusicLab.swift. |
| `band-<instrument>.sf2` (23) | One SoundFont per instrument, played by AVAudioUnitSampler. |
| `band-instruments.json` | Each instrument's playable range, measured loudness and sample source. |
| `band-voice-<voice>-night-porter-<part>.caf` (16) | The sung Hallenese parts, prerendered: one loop each, ALAC. |
| `band-voices.json` | The octave each voice sings each part in, plus the voices' levels. |

## Sources (this folder)

| File | What it does |
|---|---|
| `export_night_porter.py` | Converts Night Porter (`06-Music-Lab-Level-3/sources/soul.py`) into the template. It runs the song's own note-writing functions into collectors named for musical parts. |
| `lab-arranger.js`, `lab-harness.js`, `render_lab.py`, `roll2.py` | The arranger, plus the offline tools for listening and plotting. |
| `build_np_voices.py` | Prerenders the singers' parts with Sinsy and WORLD, de-whistled. |
| `bake.py`, `sf2write.py` | Build the instrument SoundFonts. |
| `test-renders/` | Offline renders of the essential test and their piano rolls. These are made from the same template, arranger and SoundFonts the app uses. |

## Template format (hallways-composition/1)

- **Top level:** `bpm`, `meter`, `key`, `bars` (the loop length), `sections`, and `chords` per bar.
- **Pitched parts:** `parts[]` entries with `{id, name, role (melody|bass|comp|answer|harmony|pad), priority, polyphony, notes: [[beat, beats, midi, velocity, articulation?]]}`.
- **Layers:** `layers[]` entries with `{part, name}`. This is the order in which musicians are given parts; it has nothing to do with when a part plays.
- **Groove:** `{kind: "percussion", hits: [[beat, piece, velocity]]}`. The pieces are kick, snare, ghost, hat, openhat, crash, tomhi and tomlo.

## Sample credits

| Source | Licence | Instruments |
|---|---|---|
| VSCO-2 Community Edition | CC0 | upright bass, tuba, marimba, glockenspiel, harp, violin, cello, flute, clarinet, french horn, trumpet, trombone; part of the percussion |
| Versilian Community Sample Library | CC0 | the rest of the percussion |
| FluidR3 GM SoundFont, Frank Wen | MIT | electric bass, electric piano, nylon and electric guitars, vibraphone, tenor sax, harmonica, drum kit |
| Salamander Grand Piano V3, Alexander Holm | CC BY 3.0 | piano (attribution required) |
| Synthesized for Hallways | — | organ |
| Sinsy voice `nitech_jp_song070_f001` | CC BY 3.0 | singing (attribution required) |

These are the licences stated by the sources. They have not been legally reviewed.
