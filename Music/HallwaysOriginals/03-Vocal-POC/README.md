# Hallenese singing: proof of concept

Stage A of "Genres, Instruments & Singers", Oct 24 2026. Audio for judging only; nothing here is in the app.

## What you're hearing
"Lunamore" is an 8-bar soul-ballad hook in F at 80 bpm, sung in Hallenese, over a small band (electric piano, bass, brushes).

The Hallenese syllables are ru-na-mo-re-ro / so-be-ra-ma-i / … / ma-nu-e. They're open consonant-vowel syllables that suggest Italian or Portuguese without being words.

| File | What |
|---|---|
| 00 | **Sinsy's raw output**, unprocessed, for comparison |
| 01 | **Soul singer**: the voice in its own register, with my expression pass |
| 02 | **Crooner**: an octave down, with the vocal tract lengthened |
| 03 | **Harmony singer** alone (a third below the lead) |
| 04 / 05 | **Two singers**: soul + harmony; crooner + low harmony |
| 06 | Band alone |
| 07 / 08 | Each lead with the band |
| 09 / 10 | Full: lead + harmony + band |

## How it was made
1. **Sinsy**, the Nagoya Institute of Technology's HMM singing-voice synthesizer, renders the voice from a score (MusicXML with Japanese kana as Hallenese syllables).
   - Voice: `nitech_jp_song070_f001`, licensed **CC BY 3.0**. Commercial use is allowed with this credit: *"HTS voice nitech_jp_song070_f001, © Nagoya Institute of Technology, CC BY 3.0"*.
   - Engine: Sinsy (Modified BSD) built from source.
2. Each part is sung **transposed into the voice's comfortable range** (about E4–E5). Above that range it went 2–4 semitones flat, and a low C came out as a whisper.
3. An **expression pass** with the WORLD vocoder (`pyworld`, Modified BSD):
   - **Pitch:** every note is moved to its written pitch. The singer's own glides and vibrato are kept; only the centre of each note moves.
   - **Phrasing:** approaches to high notes are tightened; there are scoops into long notes, vibrato that grows over held notes, and a fall at phrase ends.
   - **Breath and character:** the voice is breathier. For the crooner, it's an octave lower with the spectral envelope scaled down 20%, i.e. a longer vocal tract and lower formants. That's more than simple pitch-shifting.
   - Pitch outside the sung notes is silenced, so a breath can't turn into a squeak.

**Measured:** every note lands within 6 cents of its written pitch (a cent is 1/100 of a semitone). The pitch tracks are in `source/pitch.png`. The harmony part was revoiced where it rubbed a half-step against the band.

## Honest expectations
- This voice model is **from 2015 and statistical (HMM)**, trained on one singer's children's songs. Expect a slightly buzzy, "synthesized" timbre: closer to an early Vocaloid than to a human.
- I can't listen, so I can't tell you whether it crosses into "a character singing". That's the question for you.
- **The crooner is the riskiest.** It's a female voice transformed into a male one, and that's where artifacts show most.
- **Consonants are limited to Japanese phonology.** There's no L, no consonant clusters, and no consonant at the end of a syllable except "n".

## What I investigated (available here, licences)
| Option | Status |
|---|---|
| **Sinsy + nitech f001 voice** | ✅ Built and used. CC BY 3.0, shippable. |
| **MBROLA** diphone voices (Ubuntu) | Installed but **not used**. Their licence forbids use in any product sold without the voice owner's permission. |
| **NNSVS** neural singing (a modern, better generation) | Code reachable, but its pretrained voices are on Dropbox and Hugging Face, **which aren't reachable from this workspace**. The voices' licences also vary, and many forbid commercial use. |
| **DiffSinger / OpenUtau** voicebanks | The best open quality, but voicebanks are hosted off-GitHub, and most forbid commercial use or require per-voice terms. |
| Ordinary text-to-speech | Ruled out by your brief. |

**If this voice isn't good enough, the realistic next steps all involve you:**
1. A **commercially licensed singing voice**, e.g. a Synthesizer V or Vocaloid voicebank with a commercial licence, or a modern neural voice whose licence allows game use. These cost money and run in a desktop app on your Mac, not here.
2. **A human singer** (yourself, a friend, a hired session singer) records Hallenese takes, and I build the parts around them. This is the most convincing option.
3. A **neural voice you download** from Hugging Face onto your Mac, with a licence we check together. I could then help run it on your Mac through the linked folder.

## Files
- `source/sing.py`: score, Sinsy rendering, expression pass
- `source/mix_voice.py`: band and mixes
- `source/check.py`: pitch measurement
- `source/lead.xml`, `harm.xml`: the vocal scores
- `band.mid`: the band
