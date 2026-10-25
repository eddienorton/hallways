# Music Lab, Level 3: three new pieces, and the first song with singers

Oct 24 2026. The **Music Lab** in Building Life → Directory now has five pieces.

| # | Piece | Genre | Musicians | Loop | Finished performance |
|---|---|---|---|---|---|
| 1 | The Night Shift Waltz | Jazz waltz | 4 | 72.0 s (unchanged) | about 2:13 (unchanged) |
| 2 | Going Up! | Swing | 8 | 91.4 s (unchanged) | about 2:27 (unchanged) |
| 3 | **Rua das Lâmpadas** | Bossa nova, **with singers** | 10 (2 singers + 8 players) | 54.9 s | about 1:28 |
| 4 | **Night Porter** | Soul-jazz blues | 7 | 57.6 s | about 1:21 |
| 5 | **The Lantern Room** | Cinematic waltz (mood piece) | 9 | 75.8 s | about 1:41 |

The Waltz and Going Up! are untouched: same files, same manifests, same playback path.

## Rua das Lâmpadas with singers
**Singer A and Singer B are temporary identities, clearly labelled.** Which Hallwaysians, if any, become these singers is yours to decide; I haven't touched the resident cast.
- **Singer A** is the lead: the crooner voice, singing the tune an octave below the flute's register.
- **Singer B** sings harmony: the soul voice, on a chord tone below the written tune, which lands a sixth above the crooner. It never picks a note a half-step from the guitar's chord.

**The lyrics** are written for this song, one Hallenese syllable per note. Every verse opens on the same hook syllables, "ra-mi-do-re-na":
- Verse 1: ra-mi-do-re-na / so-ra-ri / ma-ni-to-re-na / so-ra-mi / pa-ri-ne-ra-mo / ka-ri-so-ne / ru-ma-so-ra / ri-de-ra-mi
- Verse 2: the same opening, with new syllables after it (no-ma…, sa-ra-i, to-ni-no-re-na…)
- Tag: "ra-mi-do-re-na, so-ra-mi" twice, ending on a held "a"

**The flute changed role.** It no longer doubles the verses: it answers in the singers' long notes and sings the bridge.

**The lab loop (32 bars):**
1. Verse 1: Singer A, with the flute answering
2. Verse 2: Singer A + Singer B, with the piano answering
3. Bridge: the flute sings; the piano pads; the singers rest
4. Verse 3: both singers; flute and piano answer

**The finished performance:**
1. Intro
2. The flute states the tune
3. Verse 1
4. Verse 2 with harmony
5. Bridge
6. Verse 3, coming home
7. The sung tag, twice
8. The last chord

## What I checked here (no compiler or iPhone in this workspace)
- **Seamless loops:** every part was rendered twice through, and the second pass kept. For every stem, the step across the loop point is smaller than its ordinary sample-to-sample movement.
- **Singers in sync:** I read each sung note's pitch from the audio at the note's score time.
  - Loop: lead 99/99, harmony 66/66. Performance: lead 113/113, harmony 80/80.
  - I also tried shifting the singers to a common feel. It made this check worse, so the voices stay exactly as Sinsy placed them.
  - Their vowels land about 50–110 ms after each written note. That's the consonant coming first, and it reads as a natural, slightly relaxed feel.
- **No whistle:** on all 165 sung notes of the loop, the 2.8–6.5 kHz peak is at least 7.4 dB below the voice. The whistle used to reach 0 dB.
- **Harmony check** (half-step rubs between pitched parts):
  - Bossa: only a one-beat passing ninth in the crooner's line against the guitar remains.
  - Night Porter: the blues riff's chromatic passing notes remain, as before.
  - The Lantern Room: passing notes over C/E remain, as before.
- **Levels:** each piece has one shared scale for all its stems; nothing exceeds −1 dBFS in the loop or the performance.
- **Swift:** `MusicLab.swift` passes a syntax check only. It has not been compiled or run.

## The compression experiment: The Lantern Room only
The Lantern Room's **loop** stems are AAC (160 kbps). Each is padded with 4,096 frames of the loop's own end before it and of its start after it. Its manifest says `"loopStartFrame": 4096`, so each pass plays exactly `loopFrames` from that point.
- In this workspace, decoding with ffmpeg gives a seamless, sample-aligned loop.
- **What iOS does still has to be heard on the phone.** If iOS decodes with a different fixed offset than ffmpeg, every stem shifts by the same amount, so the stems stay in sync and the padding keeps the seam clean.
- The only code change is that optional manifest field. Without it (every other piece) playback is exactly as before.
- If it fails on the phone, I swap in lossless loop files and delete the one manifest line.

## Files in this folder
- `listen/<piece>/`: the finished performance, the loop played twice (to hear the loop point), and a few combinations
- `source/`
  - `bossa_vocal.py`: the vocal arrangement
  - `soul.py`, `lantern.py`, `bossa.py`: the compositions, now with lab loops
  - `labexport.py`: rendering, balance, seams, sync checks, manifests
  - `studio.py`: the instrument and singer engines
  - `sing.py`: Sinsy, the expression pass and the whistle fix
  - `common.py`, `labkit.py`
- The app's assets are in `Hallways/MusicLab/`: `lab-ruadaslampadas*`, `lab-nightporter*`, `lab-lanternroom*`.

## Credits needed if shipped
- Singing voice: "HTS voice nitech_jp_song070_f001", © Nagoya Institute of Technology, CC BY 3.0. Synthesizer: Sinsy (BSD-style licence).
- Piano: Salamander Grand Piano, Alexander Holm, CC BY 3.0.
- Orchestral, wind and percussion samples: VSCO-2 Community Edition and VCSL (CC0; credit not required).
- MuseScore General SoundFont: MIT licence notice.
