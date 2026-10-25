# The Black Box (Oct 12, first prototype)

Game code: `Hallways/BlackBox.swift` (placement, face, life, taps) and
`Hallways/BlackBoxMusic.swift` (composer + synth). Model: `Hallways/BlackBox.usdz`.

## Model
`CharacterModels/Hallwaysians/scripts/blackbox.py` (uses `hallwaysian_kit`):
a 0.28 m black magnesium cube with an inset shadow-gap foot, a low casting
seam, a recessed dark-glass face panel, a ringed speaker grille on top and
three vent slots on the back. No marks or labels. The face is light drawn
by the game behind the glass (sprites in `BlackBoxFace.sprite`; Python twin
in `bb_face.py`). Previews: `bb_preview.py` (expression sheet),
`bb_office.py` (portrait-iPhone office views).

## Music
`music/compose.py` + `music/synth.py` are the Python reference for
`BlackBoxMusic.swift`: same tables, same integer-only random draws (the
game's SplitMix64), so a seed gives the same notes in both. `music/run.py
<seeds>` prints the melodies and renders WAVs. `samples/` holds four renders:
seed 105 (the box's first tune, always), and one spy / bossa / waltz.

Form: 1 count-in bar (the box taps it) + 8 bars (motif, answer, sequence,
half cadence, repeat, climax, cadence home) + an ending (a hit, or an
arpeggio flourish). Parts: lead (whistle / square / marimba / bell / vibes),
bass, comping keys, light percussion; small room reverb; 80 Hz high-pass
for phone speakers.

Turn it off without deleting anything: launch argument `-HallwaysNoBlackBox YES`.
