# 11 — New Compositions (Oct 25 2026)

Four new Music Lab pieces, written for Hallways by Claudette (Claude) on Eddie's brief. They are not
arrangements of existing songs: themes were written by hand in the scripts here; bass lines, comping and
solos are generated from each piece's chord chart by `music.py` with fixed seeds (so they rebuild identically).
No third-party melodies, recordings or samples are in these files. Whether that makes them free of every
claim isn't something I can check or promise; it's what I know about how they were made.

| Piece | Style | Key, tempo, meter | Bars | Length | Layers |
|---|---|---|---|---|---|
| Midnight Express | Swing | B♭, 168 bpm, 4/4 swung | 104 | 2:29 | Walking bass, Drums, Piano, Melody, Answers, Harmony, Long notes |
| The Velvet Hour | Bossa nova | F, 128 bpm, 4/4 | 90 | 2:49 | Bass, Bossa guitar, Percussion, Melody, Countermelody, Strings |
| Clockwork | Funk | E (E7♯9), 104 bpm, 4/4 sixteenths | 62 | 2:23 | Bass riff, Drums, Clav, Tick-tock, Melody, Answers, Brass hits, Long notes |
| After Hours | Waltz | D minor → D major, 132 bpm, 3/4 | 104 | 2:22 | Melody, Bass, Waltz chords, Music box, Countermelody, Strings, Brushes |

Each script's docstring gives its form. To rebuild: `python3 compose_<name>.py` (needs labkit's `chord()`
from the Lab tools; writes `comp-<id>.json`).

`renders/` are offline FluidSynth previews of a full conventional band through the arranger — not the
iPhone's AVAudioUnitSampler output, so balance and tone on the device will differ.
