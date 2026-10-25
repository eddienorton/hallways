# Hallways Originals #2 — "Going Up!" (working title)

Music Lab Level 2, stage B audition, Oct 24 2026. This is audio for listening only and is **not in the app yet**. Integration (stage C) waits for your verdict.

## The band (eight)

| Musician | Instrument (GM program) | Job |
|---|---|---|
| **Juanita** | trumpet (56) | the tune (head); tops the shout; trades with the sax |
| **Telephone** | tenor sax (66) | harmony under the trumpet; **sings the bridge** |
| **Chair** | trombone (57) | long guide-tone pads, "wah" answers; sings the bridge in chorus 2 |
| **Pottle** | clarinet (71) | answers in the trumpet's gaps; a falling descant in the bridge; tops the shout |
| **Camera** | vibraphone (11) | "click!" stabs; **has the tune** in chorus 2 |
| **Eileen** | piano (0) | Charleston comping; the "plink, plink…" ending |
| **Gloria** | upright bass (32) | walks all the way |
| **Tinky** | drums (GM Jazz kit) | ride + hi-hat on 2 and 4, feathered kick, fills, kicks with the horns |

I kept your provisional lineup because it works as a little swing band: three brass/reeds plus clarinet on top, vibes as the colour.

## The music
- **Style:** medium-up swing. **Tempo:** 168 bpm with swung eighths. **Key:** B♭ major, rising to C for the last part of the performance. 4/4.
- **Form:** 32-bar AABA.
  - A: B♭6 Gm7 | Cm7 F7 | B♭6 Gm7 | Cm7 F7 | Fm7 B♭7 | E♭6 E°7 | B♭6/F G7 | Cm7 F7
  - Bridge: D7 | D7 | G7 | G7 | C7 | C7 | F7 | F7 (round the dominants)
- **The tune:** a rising arpeggio that leaps up (B♭–D–F–G), answered by a falling bluesy run. The second time it reaches higher, to B♭5. The bridge is a sequence: the same shape on each dominant, one step down the cycle.

### How the band breathes (the "space" requirement)
- **Only one lead at a time.** Who has it moves: trumpet (head A), sax (bridge), vibes (chorus 2 A1), clarinet (A2), trombone (bridge), then everyone in the shout.
- **Calls and answers are built into the gaps.** The clarinet answers only in bars where the trumpet holds or rests. The trombone's "wah"s fall in the second half of the bridge's even bars, where the sax rests.
- Pads (sax and trombone guide tones) are quiet, long and stepwise, so they never fight the tune.
- **The rhythm section is self-sufficient.** Bass walks every beat, and the piano comps every chord. So any horn on top of bass + drums (+ piano) is a complete small group.

## Two forms

**Loop (lab, switchable): 64 bars, exactly 91.43 s (4,032,000 frames), seamless.**
| Bars | Section | Lead | Others |
|---|---|---|---|
| 1–16 | head A A | trumpet | sax harmony, trombone pads, clarinet answers, vibes stabs |
| 17–24 | bridge | sax | clarinet descant, trombone wahs, vibes offbeats |
| 25–32 | head A | trumpet | trombone joins the harmony |
| 33–40 | chorus 2 A1 | **vibes** | sax/trombone pads, clarinet answers; drums lighter |
| 41–48 | A2 | **clarinet** | vibes answers |
| 49–56 | bridge | **trombone** | sax wahs |
| 57–64 | shout | trumpet + clarinet + sax + trombone, harmonised | drum kicks with the band; crashes |

**Finished performance: about 2:24.**
| Time | What happens |
|---|---|
| 0:00 | Intro: Tinky alone for two bars, then Gloria and Eileen vamp; bars 7–8 are band hits |
| 0:11 | The head chorus |
| 0:57 | Chorus 2: the tune goes round the band (vibes, clarinet, trombone); in the last A the **sax has the tune and Juanita trades answers with him** |
| 1:43 | **Surprise 1: stop-time.** The band hits beat 1 and Tinky answers with fills, getting louder; a Dm7–G7 lift with a snare roll |
| 1:54 | **Surprise 2: up a whole step to C.** Trumpet and sax play the bridge in octaves |
| 2:06 | The shout chorus (everybody) |
| 2:17 | Tag: the last phrase three times |
| 2:21 | Ending: Eileen's "plink … plink", then the whole band hits a C6/9 and holds |

## Listening files
- `00-finished-performance.m4a`
- `loop/`:
  - the combinations you asked about:
    - 01 bass + drums
    - 02 + piano
    - 03 / 04 rhythm + one horn
    - 05 / 06 rhythm + two or three horns
    - 07 the no-brass group
    - 08 the four horns alone
    - 09 trumpet trio (no piano)
    - 10 rhythm + vibes
  - 11 full band, played twice through so you hear the loop point
  - `solo-1…8`: each musician alone
- `performance-stems/`: one file per musician
- `midi/`: per-musician and combined MIDI for both the loop and the performance
- `source/`:
  - `swing.py`: every note
  - `labkit.py`: shared helpers
  - `mix2.py`: balance and listening files

Each listening file is levelled on its own. Inside a file the ensemble balance is kept: tune on top, pads under.

## Things to listen for (honest notes)
- **Juanita is silent for bars 33–56 of the loop.** That's chorus 2, where the others take the tune. With only trumpet + rhythm on (file 04), you get about 34 s of rhythm section alone. I think that's a natural "piano trio" moment, but if it feels empty I can give her a quiet background riff there.
- **The clarinet alone (solo-4) is mostly short answers, with the tune only in A2.** That's by design, so the clarinet sounds better with others than on its own.
- **One deliberate rub remains:** in the performance's chorus 2, the sax plays the tune an octave down, and one passing A sits over Cm7 (a natural 13th). Nothing else came up in the half-step check.
- **The rendering is the weak link.** General MIDI horns are stiff, especially the trumpet and trombone, and the swing is a fixed offset rather than a human feel. The MIDI files will sound much better through Logic/GarageBand instruments. That's the fair way to judge the composition.

## What I checked (I can't listen)
- All stems share one timeline.
- The loop is exactly 91.43 s, and each loop seam steps less than the stem's normal sample-to-sample movement.
- Peaks are ≤ −1 dBFS. The listening files and the master go through a gentle peak limiter because of the drum crashes; the stems for the app will not.
- An automatic half-step clash check runs between every pair of musicians:
  - It caught the intro's horn hits voiced on the wrong chord, which is now fixed.
  - The loop now has zero rubs; the performance has the one intended rub above.

## Origin, copyright, sources
- **Composition:** written new for Hallways in this session (tune, bridge line, answers, riffs, arrangement).
  - The changes use long-public swing building blocks: the I–vi–ii–V turnaround, and a bridge that cycles through dominants (shared by thousands of standards; chord progressions aren't owned).
  - The melody is new, but no melody-similarity search has been done, so I can't certify it resembles nothing. Treat it as an original draft, not a cleared work.
- **Sounds:** FluidR3_GM SoundFont (Frank Wen, MIT licence).
- **Tools:** FluidSynth (LGPL) via pyfluidsynth; mido.
- No recordings, samples or third-party MIDI used.
