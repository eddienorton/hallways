# Critter voices (Music Lab › VOICES)

Every recording in this folder named `voice-*.wav` appears in the VOICES lab.
You don't need to change any code to add or replace one.
You can also use `.aif`, `.caf` or `.m4a`, but WAV is preferred.

## Naming

| File name | Meaning |
|---|---|
| `voice-doo-A3.wav` | A "doo" sung on A3. The lab can move it to chord notes. |
| `voice-baby.wav` | No note in the name, so it's treated as spoken. The lab shifts it as if it were an A3. |

- Write note names as `A3`, `C#4` (or `Cs4`), or `Bb2`. Middle C is `C4`.
- The lab shows each recording by its name and note, e.g. "doo · A3".
- These files are copied flat into the app bundle.
  - Every file name must be unique across the whole project.
  - The `voice-` prefix keeps them unique.

## Replacing a placeholder with your own recording

1. Export your WAV under the same name as the placeholder (e.g. `voice-doo-A3.wav`).
2. Drop it into this folder in Finder, replacing the old file.
3. Build and run.

If you sang a different note, rename the file to match (e.g. `voice-doo-C4.wav`).

## Recording in Audacity

1. **Project rate** (bottom left): 44100 Hz. Record in **mono**.
2. **Choose a note** in the song's key, A minor:
   - A, C or E works best (A3 = 220 Hz, C4, E4).
   - Sing a steady pitch with no slide into the note.
   - Check it with a tuner app, or **Analyze › Plot Spectrum**.
3. **Keep it short.**
   - Under about 1 second.
   - The lab cuts anything longer than 1.45 s (one bar), with a fade.
   - Silence before the sound is trimmed automatically, so the sound starts on the beat.
4. **Keep it dry.**
   - No reverb or echo.
   - Use **Effect › Normalize** to −3 dB.
5. **Export** with **File › Export Audio**:
   - WAV (Microsoft)
   - Signed 16-bit PCM
   - Mono
6. **Name** it `voice-<name>-<note>.wav` and save it here.

## Pitch shifting

Pitch shifting works well over a few semitones on a steady sung note.
The lab never shifts by more than 6 semitones down or 5 up.

- **Keep length:** the voice stays the same length at every pitch.
  - A larger shift adds some smear and "phasiness".
- **Tape speed:**
  - higher notes are shorter and brighter (chipmunk)
  - lower notes are longer and darker
- **Spoken recordings:** shifting moves the voice's inflection but can't make it sing in tune.

## The placeholders (synthesised, PP 6)

The four files here were synthesised as stand-ins, so the experiment can run before real recordings exist.
They are original sounds, made by numpy additive formant synthesis, with no recorded samples.
The generator is `Music/CritterVoices/synth_placeholders.py`.

| File | Sound | Pitch |
|---|---|---|
| `voice-doo-A3.wav` | A sung "doo" | Steady A3 (220 Hz), with gentle late vibrato. 0.60 s. |
| `voice-meep-E5.wav` | A small high critter "meep" | Steady E5 after a quick scoop up. 0.32 s. |
| `voice-bum-A2.wav` | A low round "bum", closing to a hum | Steady A2. 0.55 s. |
| `voice-baby.wav` | A speech-like "baby?" | Gliding, rising at the end, no stable pitch. 0.62 s. |
