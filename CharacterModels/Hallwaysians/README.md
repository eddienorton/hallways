# Hallwaysians

The building's own objects, alive. Each character is GENERATED in Blender
(run as the `bpy` Python module) from a script here, and exported as USDZ
for SceneKit.

    pip install bpy==4.2.0 usd-core pillow
    cd scripts
    python3 juanita.py --out ../out          # -> Juanita.usdz (+ .usda, .blend)
    python3 tinky.py   --out ../out          # -> MrTinky.usdz
    python3 others.py  --out ../out          # -> Elwood, Hum, Dottie, Nan
    python3 preview.py -- ../out/Juanita.blend ../out/prev 1.85      # 3-view sheet
    python3 usd_lineup.py --src ../out --out ../out --samples 32 --res 0.6   # all six, from the exported USDZ

`hallwaysian_kit.py` holds the shared shapes and the exporter. Export contract:
SceneKit frame baked in (Y up, metres), every joint an unrotated/unscaled node at
its pivot (game code sets absolute angles), part rotations baked into meshes,
constant materials only (stripes/labels are geometry).

In the game (Hallways/HallwaysianModels.swift):
- `Juanita.usdz` and `MrTinky.usdz` are bundled and used.
- Elwood, Hum, Dottie and Nan live in `assets/` -- NOT in the app bundle and not
  placed anywhere yet.
- Classic bodies: launch with `-HallwaysClassicCharacters YES`, or per
  character `-HallwaysClassicJuanita YES` / `-HallwaysClassicTinky YES`.

Joints:
- Juanita (faces +Z): adminBody > juanitaNeck1 > juanitaNeck2 > adminHead >
  adminEyes > adminPupils; adminArmPoint/Rest > adminElbow* > adminHand*
  (> adminFinger = the stamp's rubber pad).
- Mr. Tinky (faces -Z, shown at 2x): tinCanRatBody > tinCanRatLeg0..3 (FL FR BL BR),
  tinCanRatEar0/1 (bottle caps, disc axis up; the game tilts them), tinCanRatTail.
- Elwood: elwoodBody (hips) > elwoodLegL/R, elwoodArmL/R, elwoodHead > elwoodEyes > elwoodPupils.
- Hum: humBody > humHead (tilt + oscillate about the yoke) > humBlades (spin), humEyes > humPupils.
- Dottie: dottieBody > dottieDial (spins), dottieHandset (hinged at her right prong; lifts),
  dottieEyes > dottiePupils.
- Nan: nanBody > nanEyes > nanPupils (spectacles ride on the eyes).

Oct 11 -- CAST AUDITION (Floor 3 conference room, Hallways/ConferenceAudition.swift):

    python3 audition.py --out ../out                 # -> AuditionCommodore/Crane/Proscenium/Cloche/Aspic.usdz
    python3 audition_lineup.py --src ../out --out ../out            # lineup with Juanita + Tinky
    python3 audition_lineup.py --src ../out --out ../out --cam -1.15 # a close-up (x of the character)

Face rig (prefix p; S = L/R by the character's own side): pHead > pEyeS > pPupilS (rotate to look),
pHead > pLidS (upper-lid cap, +x closes), pHead > pBrowS (raise / tilt), pMouth (hinge or scale).
Extras: craneWingL/R, craneNeck, procCurtainL/R (slide to close). The .usdz files are bundled in Hallways/.

Oct 11 -- AUDITION, ROUND TWO (current; round one stays bundled, `-HallwaysAuditionRound 1`):

    python3 audition2.py --out ../out        # -> AuditionSafe/Stove/Mailbox/Accordion/Vacuum.usdz
    python3 audition2_lineup.py --src ../out --out ../out2 [--cam X]
    python3 audition_roomsim.py --src ../out --out ../out2 --view seat|<yaw> --fov 55   # the seated portrait-iPhone view

Extra joints: safeDial (turns in clicks), safeHandle (the moustache), stovePipe / stovePipeTop (smoke),
vacTrunk1..3 (the trunk), vacEarL/R, accBellows (scaled to breathe; accHead rides on it), accArmL/R, mailFlag.
