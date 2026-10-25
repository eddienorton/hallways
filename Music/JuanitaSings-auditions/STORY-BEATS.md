# Juanita & Tinky — house-band story beats (Eddie, Oct 24, 14:32)

Status: SPEC ONLY. Waiting on approval of Juanita's voice asset. Do NOT use the
old ID-card-triggered orchestra, and do NOT ship an unapproved synthetic voice
to fill the gap.

Every trigger is a real story event. None is an elapsed time or a guess based
on distance.

## Juanita
1. Fresh game: no music outside, in the lobby, or on the first elevator ride.
2. **Trigger: the Floor 2 Administration doors open for the player.** Juanita's
   wordless hum/whistle becomes audible, placed at her position (spatial).
3. **Trigger: Juanita's greeting begins** (as the player approaches). She stops
   singing naturally, at the end of the note or breath she's on.
4. **Trigger: the interaction ends and the player heads for the ID kiosk.** She
   resumes at the start of the next phrase. Her timeline keeps running silently
   while she's stopped.
5. Taking the ID card, by hand or automatically, triggers NO music.

## Tinky
6. Juanita keeps singing during the kiosk visit and the walk to Tinky's office.
7. **Trigger: Tinky finishes his introduction and becomes available for FOLLOW.**
   His complementary part joins Juanita's, on a bar line, fading in.
8. At that same moment, Juanita's localized singing moves smoothly into the
   building-wide house-band mix (no jump; same timeline).
9. From then on the foundation continues through FOLLOW, elevator travel and
   all later gameplay. It must NOT fade during Tinky's escort, so the house band
   is exempt from the story-quiet rule. Mute and audio-off still apply.
10. Persists across app restarts. Start Over clears it, so the introduction can
    be heard again.

## Implementation notes (from inspection)
- One sample-locked timeline for every stem (the LivingOrchestra deck). Juanita's
  spatial and building-wide sound is one player with its position, level and
  filtering moved, never a second copy.
- Persistence: derived from saved story records (Juanita/Tinky encounters),
  which Start Over already clears. No separate music key is needed unless
  beat 7's FOLLOW-available moment needs its own once-only record.
- Concept: the music starts with the characters, then becomes the building's
  musical identity.
