# Genre auditions: soul, cinematic, bossa

Stage B of "Genres, Instruments & Singers", Oct 24 2026. These are listen-ready excerpts, not integrated into the app. Each folder has:
- `00-…-full.m4a`: the finished excerpt
- numbered combinations: who's playing
- `parts/`: each musician alone
- `midi/`: per part, plus all parts together

## The three compositions

### A. "Night Porter": soul-jazz / boogaloo blues (G, 100 bpm, about 1:21)
**The hook:** a five-note organ figure, *da-da DAAH, da-dah, da-DAAH*. It returns over the changes the way blues riffs do:
- as written over G7,
- moved up a fourth over C7,
- stretched to the chord's top over D7.

The horns answer it, and a boogaloo bass riff walks underneath (G G B♭ C C♯ D F).

**Form:**
1. Intro: drums, then bass, guitar chops and an organ swell
2. 12-bar head
3. Solos: guitar 4 bars, organ 4 bars, then a 4-bar horn shout built on the hook
4. Head out
5. Band hit on G7♯9, then a held organ chord

**Players:**
- Hammond organ (**synthesized here**): drawbars, key click, percussion, Leslie, drive
- Electric guitar, electric bass, drums, tenor sax: MuseScore General soundfont
- Trumpet and trombone: VSCO-2 samples

### B. "The Lantern Room": cinematic waltz (D minor → D major, 3/4, 76 bpm, about 1:41)
**The hook:**
- a rising fourth into a long note (A–D), then a turn above it (E–F–E) and a stepwise fall;
- when it returns, the leap widens to a sixth (A–F);
- bar 7 puts E over B♭, the "slightly magical" lydian colour;
- the second half lifts into F major, then lands deceptively on B♭.

**Form:**
1. A glockenspiel "music box" plays the motif
2. Flute theme over harp; the cellos answer in the long notes
3. Solo violin takes the theme
4. Climax: violins and cellos in octaves, horn and violas underneath
5. The music box returns, in **D major**, with a held flute A

**Players:** all VSCO-2 samples (glock, harp, flute, solo violin, violin/viola/cello sections, contrabass, French horn).
- The harp's 12-second ring is shortened (`HarpDamped.sfz`), as a harpist would damp between chords.

### C. "Rua das Lâmpadas": bossa nova (D, 140 bpm, about 1:11)
**The hook:** a rising four-note phrase that lands on a long note and sighs down. The same shape follows a step lower, then leaps to the 13th. The B section is the bittersweet middle, turning on the minor iv (Gm6).

**Form:**
1. Intro: guitar, then percussion
2. A: flute
3. A: flute, with the piano answering
4. B
5. A: the piano starts the tune and the flute finishes it
6. Tag twice, then a final D chord

**Players:**
- Flute and contrabass pizz: VSCO-2
- Piano: Salamander Grand
- Nylon guitar: MuseScore General soundfont
- Congas and claves: VSCO-2
- Bongos and shaker: VCSL

## Instruments: what improved, and what didn't
**`instrument-AB/`** has the **same notes rendered twice**: through our old FluidR3 General MIDI set (A) and through the new instruments (B). Compare them to judge the improvement for yourself.

| Source | Licence | Quality (my expectation; I can't listen) |
|---|---|---|
| **VSCO-2 Community Edition** (strings, winds, horn, harp, glock, trumpet, trombone, congas, claves) | CC0 | Real recorded instruments, multiple dynamic layers. A clear step up from General MIDI. But sustained samples have **no legato** between notes, and sections are small. |
| **Salamander Grand Piano V3** | CC BY 3.0 (credit Alexander Holm) | A good sampled Yamaha C5. The biggest single improvement. |
| **VCSL** (bongos, shakers, harmonica, etc.) | CC0 | Real recordings. Good one-shot percussion. |
| **MuseScore General** soundfont (guitars, electric bass, drum kit, sax) | MIT | Better than FluidR3, but still General MIDI-class. **The guitars and sax are the weakest instruments here.** |
| **Hammond organ** (my synthesis) | ours | A tonewheel organ is itself electronic, so synthesis can be authentic. The Leslie and overdrive are approximations. |

**Not available here at shippable quality:** acoustic or electric guitar samples, electric piano samples, accordion, and real saxophone. I didn't find good free CC0 or MIT libraries for these that are reachable from this workspace.

**Tools:**
- **sfizz** (BSD-2) renders the sampled instruments. Built from source here.
- FluidSynth renders the soundfonts.
- Room reverb is a synthesized convolution.

**Credits required if shipped:**
- Salamander Grand Piano (Alexander Holm, CC BY 3.0)
- Sinsy voice (Nagoya Institute of Technology, CC BY 3.0), if the vocals go in
- MIT notice for MuseScore General

## What I checked (I can't listen)
- **Half-step clash check** between every pair of pitched parts:
  - After revoicing, the bossa went from 17 rubs to 1 and the waltz from 24 to 3. The soul tune has 7, all from the blues bass riff and solo passing notes.
  - The rubs that remain are intended: the ♭9 on B7♭9, passing notes in the waltz melody over C/E, and the blues bass riff's chromatic passing notes and blue third.
- **Loudness over time** per part, plotted, to confirm every part enters and drops out as written and that no sample runs out under a held note.
- **No clipping:** peaks are ≤ −1 dBFS.

## App size: compressed loops can be gapless (test result)
I tested 4 "Going Up!" loop stems:
1. Wrap 4,096 samples of each loop's own end before its start, and of its start after its end.
2. Encode as AAC, decode, and cut the exact loop back out.

**Results:**
- The decoder offset was 0, so the stems stay sample-locked.
- The loop seam is far below the size of an ordinary sample-to-sample step: no click.
- **160 kbps AAC is 2.1–5.1× smaller than our lossless loops (about 3.4× on average).** "Going Up!" would drop from about 45 MB to about 15 MB.

**Why it's robust:** if iOS decodes with a different fixed offset than ffmpeg, every stem shifts by the same amount. They stay in sync, and the padding keeps the seam seamless.

**What it needs:**
- a small code change: the manifest gains a `loopStartFrame`, and the deck plays from it;
- **one test on the phone** (loop point and sync) before converting the Waltz and "Going Up!".

Lossless stays the fallback.

## Origin and copyright
- **Compositions:** written new for Hallways in this session (melodies, riffs, harmony choices, arrangements).
  - They use long-public idioms: the 12-bar blues, the boogaloo bass shape, a waltz with harp arpeggios, bossa guitar rhythm and ii–V harmony.
  - No melody-similarity search has been done, so treat them as original drafts, not cleared works.
- **Samples and sounds:** as in the table above. No recordings or MIDI from anywhere else were used.
