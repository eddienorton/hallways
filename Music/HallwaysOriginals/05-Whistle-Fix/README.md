# The vocal whistle: cause and fix

Oct 24 2026. The original vocal auditions in `03-Vocal-POC/` are **unchanged**; this folder holds the corrected versions alongside them.

## What it was
Sinsy's HMM voice model (`nitech_jp_song070_f001`) sometimes builds an **extremely narrow, tall resonance between about 3 and 4 kHz**. Whichever overtone of the sung note lands in it becomes as loud as the whole voice. You hear that as a pure, piercing tone: the whistle.

**Evidence** (Lunamore lead, unprocessed Sinsy output):
- During "mo" (1.5 s), the 8th harmonic at 3,754 Hz is the **loudest component in the entire spectrum**, at 0 dB relative to the spectrum's maximum.
- During "re" it's the 7th harmonic at 3,016 Hz, only 1.8 dB below the maximum.
- In normal notes the same region sits 13–30 dB lower.

**It is not one phoneme or one note.** "mo" whistles at 1.5 s but not at 13.5 s, and "ya" does it at 17.2 s. It depends on the pitch and the surrounding sounds. It was worst at the start of the phrase, which is why you heard it near the beginning.

It was in Sinsy's raw output, as you spotted, so it wasn't caused by my processing.

## The fix (narrow by design)
The fix happens in the WORLD analysis stage the voices already go through.
- For each 5 ms frame, the 2.8–6.5 kHz peak is compared with the loudest point of the voice's body below 2.8 kHz.
- If the peak comes within 6 dB of the body, or towers above it, a narrow dip (about ±350 Hz) lowers **only that peak** to 9 dB below the body. The dip is smoothed over 30 ms so nothing pumps.
- Everything else is untouched, including the vowels' own brightness (the "i" and "e" resonances, mostly below 2.8 kHz).

**Measured:**
- In Lunamore, only 3–5 of 23 notes change by more than 1 dB.
- The fix acts on about 17% of voiced frames; the deepest cut is 25 dB, which shows how far the whistle towered over the voice.
- The worst note on every voice (soul, crooner, harmony, low harmony) is now at least about 7 dB below the voice's body. Before, several were at 0 dB.
- `crooner-before-after.png` shows the spectrogram before and after.

## Files
- `1-…` through `4-…`, BEFORE and AFTER: 12.5 s each.
  - 1: soul singer with the band
  - 2: crooner alone
  - 3: two singers
  - 4: Sinsy's raw voice resynthesized with no expression pass, with and without the fix
- `crooner-before-after.png`: spectrograms.
- `source/`
  - `sing.py`: `dewhistle()` and `express(fix_whistle=True)`
  - `whistle_test.py`: the measurements
  - `whistle_ab.py`: these clips

The fix is on by default for every new vocal render, including the "Rua das Lâmpadas" singers.
