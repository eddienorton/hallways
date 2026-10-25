# 09 — Instrument audit and auditions (Oct 25 2026)

**The cause.** Four SoundFonts held no instrument at all, or none in part of their range:

| Instrument | Empty |
|---|---|
| tuba | all of it |
| marimba | all of it |
| trombone | its top two samples |
| glockenspiel | its top three samples |

- The tuba's and marimba's VSCO-2 sample folders were never downloaded.
- The trombone and glockenspiel sources simply stop below the roots asked for.
- The bake renders each note, then normalised every sample to full scale. A silent render, normalised, became a full-scale DC step: a "tap" at note-on and note-off, with no tone.

**The fixes:**
- `bake.py` now drops any root its source can't play (the neighbouring samples cover those keys). It stops if a source plays nothing.
- The tuba and marimba samples were fetched and both were rebuilt.
- Piano, electric piano, guitars, vibraphone, harp and electric bass are now sampled for 3.5–4.5 s instead of 2.4–3 s. Before, their held notes stopped dead when the sample ran out.

**Files here:**
- `audit.py` checks every SoundFont: empty samples, pitch against root, sustain and release of a held note, clicks, loudness. `audit.json` holds the results.
- `phrases.py` holds the 23 audition phrases (note data). They become `band-auditions.json` in the app.
- `auditions/*.m4a` and `all-23-auditions.m4a` are FluidSynth renders of the phrases through the app's SoundFonts. Apple's sampler on the phone may differ.
