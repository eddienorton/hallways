# Hallways Originals #1 — "The Night Shift Waltz" (working title)

First Music Lab audition, Oct 24 2026. Audio for listening; no game code involved.

## The band

| Musician | Role | Instrument (as rendered) |
|---|---|---|
| **Juanita** | lead melody | clarinet (General MIDI 71) |
| **Tinky** | rhythm | kalimba (GM 108) + "tin" percussion: mute triangle, shaker, open triangle |
| **Gloria** | bass | acoustic upright bass (GM 32) |
| **Eileen** | harmony and countermelody | nylon-string guitar (GM 24) |

I chose the instruments for how they blend, not from the characters' names. The result is a small café/chamber-jazz group: warm clarinet, nylon guitar, upright bass, and Tinky's tinkling kalimba on top.

## The music

- **Style:** jazz waltz, 3/4.
- **Tempo:** 120 bpm (one bar = 1.5 s); the ending slows to about 84.
- **Key:** A minor, with a bridge in the relative major (C and F).
- **A section:** Am | Am/G | Fmaj7 | E7 | Am | Am/G | D9 | Fmaj7 | Dm7 | G7 | Cmaj7 | Fmaj7#11 | Bm7b5 | E7 | Am | E7
  - It opens on a descending bass, A–G–F–E, so the bass line itself carries the mood.
  - The bright D9 in bar 7 and the lydian #11 in bar 12 are the "Hallways" colours.
- **B section (bridge):** Fmaj7 | G6 | Em7 | Am7 | Dm7 | G7 | Cmaj7 | C7 | Fmaj7 | Fm6 | Em7 | A7 | Dm7 | G7 | Esus4 | E7
  - The Fm6 in bar 10 is the bittersweet turn.

### The conversation built in
- Juanita's phrases leave gaps, and Eileen answers in them (bars 4, 8, 11–12 and 16 of each A).
- In the finished performance's bridge they **swap roles**: Eileen sings the bridge melody on guitar, while Juanita plays a slow line underneath, falling by half-steps (E, D, C, B, B♭, A, A♭, G…).
- The interlude is a conversation: two bars each, back and forth.
- Gloria plays an oom-pah waltz in the A sections and walks in the bridge and the final return.
- Tinky's kalimba figure lands between the beats (3+3 against the waltz). He thins out to a sparser pattern in the bridge.

## The two forms (same material, same timeline)

**Loop: the lab's switchable version.** 48 bars, exactly 72.0 s, loops seamlessly.
- A (16), B (16), A′ (16). A′ has melodic variations and different answers.
- Every musician plays all the way through, so any part can be switched in or out without restarting the others.

**Finished performance: about 2:13.** 85 bars, with a beginning, development, variation and ending:

| Section | Bars | Time | What happens |
|---|---|---|---|
| Intro | 8 | 0:00 | Tinky alone, then Gloria joins |
| A1 | 16 | 0:12 | Juanita's theme over bass and kalimba (Eileen saves herself) |
| A2 | 16 | 0:36 | Eileen arrives, comping and answering Juanita; shaker added |
| B | 16 | 1:00 | Bridge: Eileen leads, Juanita's descending line beneath, Gloria walks |
| Interlude | 8 | 1:24 | Juanita and Eileen trade two-bar phrases; band almost silent |
| A3 | 12 | 1:36 | The return: walking bass, Tinky's fills, the theme's strongest statement |
| Coda | 9 | 1:54 | The cadence tag twice: a deceptive turn to F the first time, then home, slowing, ending on a held A minor (add 9) |

It's about 2:13 because the material supports that length. I didn't pad it to three minutes.

## Files

- `00-finished-performance.m4a`
- `loop/`
  - each musician alone (01–04)
  - six combinations (05–10), including the band without the melody
  - all four (11), played twice through so you can hear the loop point
- `performance-stems/`: the finished performance, one musician per file
- `midi/`
  - `loop-<musician>.mid` and `performance-<musician>.mid`: separate MIDI for each musician
  - `loop-all.mid` and `performance-all.mid`: the combined arrangements
- `source/`
  - `original1.py`: the composition. Every note is written there.
  - `mix1.py`: the mix and the listening files
  - `analyze.py`: the harmony check described below

### Levels
Each listening file is set to a comfortable loudness on its own. Within a file the musicians keep the ensemble's balance: melody on top, Tinky tucked in. So a solo file plays louder than that musician sounds in the full band.

## Composition vs. rendering: how to judge each

**The rendering is the weak link I'm sure of.** These are General MIDI samples, so expect:
- a clarinet with a synthetic, slightly static sustain;
- a guitar that strums mechanically;
- a thin, plasticky kalimba attack;
- reverb that is generic.

None of that is the composition.

**To judge the composition by itself,** open the MIDI files in GarageBand or Logic and let better instruments play the same notes.
- If the tunes, harmony and conversation hold up there, the composition is sound.
- If it's dull with good instruments too, the composition needs work.

**What I checked (I can't listen):**
- All parts share one timeline; the loop is exactly 72.0 s.
- The loop point steps less than ordinary sample-to-sample movement, so there's no click.
- Peaks stay under −1 dBFS.
- An automatic check found every place two musicians rub a half-step apart. It caught a one-bar placement bug, two harsh clashes at the theme's cadence, and voicings where the kalimba or guitar fought the melody. All are fixed.
- What remains is intended: a seventh resolving to the next chord's third, and one chromatic passing note in the walking bass.

**What I can't check:** whether it's beautiful. That's for your ears.

## Origin, copyright, and sources

- **Composition:** written new for Hallways in this session (melody, countermelody, bass lines, kalimba figures, arrangement).
  - It is built from common, long-public idioms: the descending "lament" bass, ii–V cadences, jazz-waltz comping, a deceptive cadence at the end.
  - I didn't copy any existing piece. But I can't certify it accidentally resembles nothing, since a melody-similarity search hasn't been done.
  - Being generated is not a copyright clearance. Treat it as an original draft.
- **Sound library:** FluidR3_GM General MIDI SoundFont by Frank Wen, distributed under the MIT licence (Debian package `fluid-soundfont-gm`).
- **Synthesizer:** FluidSynth (LGPL), driven by `pyfluidsynth`.
- **Effects:** reverb is FluidSynth's built-in reverb. No other samples, recordings or third-party MIDI were used.
