# The Living Orchestra -- loop version (prototype 1)

Made from Version 1 ("The Living Office", ../LivingOffice-v1, unchanged) by `arrange_loop.py`.

- Loop: bars 1-42 of Version 1 (the final pluck dropped); 116 bpm, 3,832,138 samples at 44.1 kHz (~86.9 s).
  Bars 41-42 (the bass riff over Gm, A7) lead straight back into bar 1.
- Stems (all the same length, each rendered twice end to end with the second pass kept, so tails wrap round the loop):
  - foundation -- double bass, pizzicato chords, light percussion, and a soft core melody
    (pizzicato violins; bowed strings in the B section) carrying every passage
  - clarinet, bassoon, flute -- the original woodwind parts (one critter each)
  - ensemble -- French horn (the original's sustains plus a few added in A' and C), shared by every other critter
- The game's copies: Hallways/LivingOrchestra/orchestra-*.caf (Apple Lossless).
- The stems here are rendered with a small General MIDI soundfont: placeholders, not for shipping.
  To replace them with real orchestral sound: open `orchestra-<stem>.mid` (or `living-orchestra-loop.mid`)
  in Logic / GarageBand, give each part a proper instrument, bounce each stem for exactly 3,832,138
  samples at 44.1 kHz with the loop's tail wrapped (bounce two passes and keep the second), save as
  Apple Lossless .caf under the same names. Every stem must be the same length -- the game checks.
