# Cartoon Juanita (CharacterModels/Juanita)

The in-game model `Hallways/JuanitaCartoon.usdz` is GENERATED from `build.py`
with Blender 4.2 (run as the `bpy` Python module) -- edit the script, rebuild.

    pip install bpy==4.2.0 usd-core
    python3 build.py --out out                       # out/juanita.blend + out/JuanitaCartoon.usda
    python3 package.py out/JuanitaCartoon.usda out/JuanitaCartoon.usdz
    python3 render.py -- out/juanita.blend out three face   # preview PNGs (Cycles, CPU)
    cp out/JuanitaCartoon.usdz ../../Hallways/

Contract with the game (CartoonJuanita.swift / AdministrationReception):
SceneKit frame baked in (Y up, faces +Z, metres, height ~1.81 m, bald, no antenna),
every joint node unrotated/unscaled at rest, named exactly:
adminBody > adminHead (neck pivot) > adminEyes (eye-height pivot) >
adminPupils (at the eyes' origin), adminMouth;
adminArmPoint / adminArmRest (shoulder pivots, arms hang along -Y; her right =
-X points) > adminElbow* > adminHand* (> adminFinger on the pointing hand).

Classic stand-in: launch with `-HallwaysClassicJuanita YES`.
