# The next four Hallwaysians (assets only; not placed in the game yet).
# Each faces SceneKit +Z (built facing Blender -Y). Joint names per character.
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hallwaysian_kit as K
import bpy, bmesh
from mathutils import Vector
OUT = sys.argv[sys.argv.index('--out') + 1]
WHICH = sys.argv[sys.argv.index('--only') + 1].split(',') if '--only' in sys.argv else ['elwood', 'hum', 'dottie', 'nan']

def brass(): return K.mat('hwBrass', (0.78, 0.58, 0.28), metal=1, rough=0.28)
def chrome(): return K.mat('hwChrome', (0.85, 0.86, 0.88), metal=1, rough=0.14)

# ---------------------------------------------------------------- ELWOOD
def elwood():
    K.reset()
    WOOD = K.mat('elwoodBoxwood', (0.80, 0.62, 0.33), rough=0.35, coat=0.5)
    INK = K.mat('elwoodInk', (0.05, 0.04, 0.03), rough=0.6)
    BR = brass(); OLD = K.mat('elwoodBrassOld', (0.60, 0.46, 0.24), metal=1, rough=0.45)
    def seg(a, b, parent, w=0.05, t=0.02, ticks=True):
        a, b = Vector(a), Vector(b); d = b - a
        o = K.box((a + b) / 2, (w, t, d.length), WOOD, bevel=0.003, parent=parent, name='rule')
        o.rotation_mode = 'QUATERNION'; o.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(d.normalized())
        if ticks:
            n = int(d.length / 0.05)
            for i in range(1, n):
                p = a + d * (i / n)
                tk = K.box(p, (0.018 if i % 2 else 0.028, t * 1.04, 0.003), INK, bevel=0.0, parent=parent, name='tick')
                tk.rotation_mode = 'QUATERNION'; tk.rotation_quaternion = o.rotation_quaternion
                off = Vector((-(w / 2) + (0.009 if i % 2 else 0.014), 0, 0)); off.rotate(o.rotation_quaternion); tk.location = p + off
    def pin(p, parent):
        K.cyl(p, 0.015, t := 0.028, BR, rot=(math.pi / 2, 0, 0), verts=12, parent=parent, name='rivet')
    root = K.joint('hwElwood'); body = K.joint('elwoodBody', (0, 0, 1.12), root)
    for s, nm in ((-1, 'R'), (1, 'L')):
        leg = K.joint(f'elwoodLeg{nm}', (s * 0.05, 0, 1.12), body)
        pts = [(s * 0.05, 0, 1.12), (s * 0.18, 0, 0.78), (s * 0.06, 0, 0.40), (s * 0.20, 0, 0.05)]
        for a, b in zip(pts, pts[1:]): seg(a, b, leg)
        for p in pts[1:]: pin(p, leg)
        K.box((s * 0.20, -0.04, 0.012), (0.09, 0.15, 0.02), OLD, bevel=0.004, parent=leg, name='hingeFoot')
    pin((0, 0, 1.12), body)
    spine = [(0, 0, 1.12), (0.08, 0, 1.40), (-0.02, 0, 1.68), (0, 0, 1.78)]
    for a, b in zip(spine, spine[1:]): seg(a, b, body, w=0.06)
    for p in spine[1:]: pin(p, body)
    for s, nm in ((-1, 'R'), (1, 'L')):
        arm = K.joint(f'elwoodArm{nm}', (s * 0.03, 0, 1.70), body)
        pts = [(s * 0.03, 0, 1.70), (s * 0.12, -0.02, 1.38), (s * 0.05, -0.03, 1.08), (s * 0.13, -0.02, 0.84)]
        for a, b in zip(pts, pts[1:]): seg(a, b, arm, w=0.035, t=0.015, ticks=False)
        for p in pts[1:]: pin(p, arm)
    head = K.joint('elwoodHead', (0, 0, 1.79), body)
    seg((0, 0, 1.80), (0, 0, 2.55), head, w=0.15, t=0.03)
    K.cyl((0, 0, 2.56), 0.078, 0.022, OLD, scale=(1, 0.28, 1), parent=head, name='endCap')
    eyes = K.joint('elwoodEyes', (0, -0.04, 2.40), head); pupils = K.joint('elwoodPupils', (0, -0.04, 2.40), eyes)
    for s in (-1, 1):
        K.eye((s * 0.042, -0.05, 2.40), 0.041, WOOD, look=(0, -1, -0.15), lid=0.55, lid_tilt=s * 0.35, parent=eyes, prefix='eye')
    for o in bpy.context.scene.objects:
        if 'Pupil' in o.name and o.type == 'MESH': K.own(o, pupils)
    K.rod((0.065, 0.02, 2.18), (0.14, -0.02, 2.40), 0.008, K.mat('elwoodPencil', (0.95, 0.70, 0.08), rough=0.5), verts=6, parent=head, name='pencil', smooth=False)
    K.export('Elwood', OUT)

# ---------------------------------------------------------------- HUM
def hum():
    K.reset()
    MINT = K.mat('humMint', (0.44, 0.62, 0.55), rough=0.25, coat=0.8); CH = chrome()
    root = K.joint('hwHum'); body = K.joint('humBody', (0, 0, 0), root)
    K.sphere((0, 0, 0), 0.28, MINT, scale=(1, 1, 0.28), seg=32, ring=12, parent=body, name='foot')
    K.cyl((0, 0, 0.62), 0.022, 1.15, CH, parent=body, name='pole')
    K.cyl((0, 0, 0.64), 0.031, 0.06, CH, parent=body, name='heightCollar')
    head = K.joint('humHead', (0, 0, 1.20), body)          # tilt (x) and oscillate (y) about the yoke
    K.rod((0, 0, 1.19), (0, 0.17, 1.24), 0.02, CH, parent=head, name='yoke')
    H = Vector((0, 0, 1.30))
    K.sphere(H + Vector((0, 0.17, 0)), 0.13, MINT, scale=(1, 1.3, 1), seg=28, ring=16, parent=head, name='motor')
    K.cyl(H + Vector((0, 0.32, 0.07)), 0.01, 0.08, CH, parent=head, name='knobStem')
    K.sphere(H + Vector((0, 0.32, 0.12)), 0.03, CH, parent=head, name='oscillationKnob')
    for rr in (0.34, 0.27, 0.20, 0.13):
        K.torus(H + Vector((0, -0.06 - (0.34 - rr) * 0.35, 0)), rr, 0.005, CH, rot=(math.pi / 2, 0, 0), maj=40, mino=6, parent=head, name='guardRing')
    K.torus(H + Vector((0, 0.04, 0)), 0.34, 0.006, CH, rot=(math.pi / 2, 0, 0), maj=40, mino=6, parent=head, name='guardRim')
    for k in range(16):
        a = 2 * math.pi * k / 16
        K.rod(H + Vector((math.cos(a) * 0.075, -0.15, math.sin(a) * 0.075)), H + Vector((math.cos(a) * 0.34, -0.06, math.sin(a) * 0.34)),
              0.0035, CH, verts=6, parent=head, name='guardWire')
        K.rod(H + Vector((math.cos(a) * 0.34, 0.04, math.sin(a) * 0.34)), H + Vector((math.cos(a) * 0.34, -0.06, math.sin(a) * 0.34)),
              0.0035, CH, verts=6, parent=head, name='guardWireSide')
    blades = K.joint('humBlades', (0, -0.02, 1.30), head)   # spin about the hub axis (SceneKit z)
    for k in range(3):
        a = 2 * math.pi * k / 3 + 0.4
        b = K.sphere(H + Vector((math.cos(a) * 0.16, -0.02, math.sin(a) * 0.16)), 0.13, MINT, scale=(0.45, 0.08, 1), seg=20, ring=10, parent=blades, name='blade')
        b.rotation_euler = (0, -a + math.pi / 2, 0)
    eyes = K.joint('humEyes', (0, -0.12, 1.30), head); pupils = K.joint('humPupils', (0, -0.12, 1.30), eyes)
    K.eye((0, -0.12, 1.30), 0.075, MINT, look=(0, -1, -0.2), lid=0.30, pupil=0.45, parent=eyes, prefix='eye')
    K.torus((0, -0.12, 1.30), 0.08, 0.012, CH, rot=(math.pi / 2, 0, 0), parent=eyes, name='eyeBezel')
    for o in bpy.context.scene.objects:
        if 'Pupil' in o.name and o.type == 'MESH': K.own(o, pupils)
    K.export('Hum', OUT)

# ---------------------------------------------------------------- DOTTIE
def dottie():
    K.reset()
    BAKE = K.mat('dottieBakelite', (0.48, 0.05, 0.05), rough=0.14, coat=1); CH = chrome()
    WHITE = K.mat('dottieDialCard', (0.93, 0.90, 0.82), rough=0.4); RUB = K.mat('dottieRubber', (0.04, 0.04, 0.04), rough=0.8)
    root = K.joint('hwDottie'); body = K.joint('dottieBody', (0, 0, 0), root)
    K.sphere((0, 0, 0.22), 0.30, BAKE, scale=(1, 0.88, 0.72), seg=40, ring=20, parent=body, name='shell')
    K.cyl((0, 0, 0.07), 0.27, 0.08, BAKE, scale=(1, 0.88, 1), verts=40, parent=body, name='base')
    for sx in (-1, 1):
        for sy in (-1, 1):
            K.cyl((sx * 0.18, sy * 0.14, 0.02), 0.035, 0.04, RUB, parent=body, name='foot')
    dial = K.joint('dottieDial', (0, -0.275, 0.19), body)       # spins about its own axis
    dc = Vector((0, -0.275, 0.19))
    o = K.cyl(dc, 0.125, 0.025, CH, verts=48, parent=dial, name='dialPlate'); o.rotation_euler = (math.pi / 2 - 0.35, 0, 0)
    for i in range(10):
        a = math.radians(60 + i * 26)
        K.sphere(dc + Vector((math.cos(a) * 0.088, -0.02, math.sin(a) * 0.088 * 0.94)), 0.019, WHITE, scale=(1, 0.4, 1), seg=12, ring=8, parent=dial, name='fingerHole')
    K.sphere(dc + Vector((0, -0.016, 0)), 0.045, WHITE, scale=(1, 0.3, 1), parent=dial, name='dialCard')
    for s in (-1, 1):
        K.sphere((s * 0.17, 0, 0.43), 0.045, BAKE, scale=(1, 1.3, 1.4), parent=body, name='prong')
    eyes = K.joint('dottieEyes', (0, -0.08, 0.44), body); pupils = K.joint('dottiePupils', (0, -0.08, 0.44), eyes)
    for s in (-1, 1):
        K.eye((s * 0.075, -0.08, 0.44), 0.082, BAKE, look=(-0.25, -1, 0.1), lid=0.2, lid_tilt=-s * 0.2, parent=eyes, prefix='eye')
    for o in bpy.context.scene.objects:
        if 'Pupil' in o.name and o.type == 'MESH': K.own(o, pupils)
    # handset hinged at her right prong (it lifts like an eyebrow)
    hs = K.joint('dottieHandset', (-0.17, 0.0, 0.50), body)
    K.rod((-0.20, 0.02, 0.52), (0.20, 0.02, 0.56), 0.038, BAKE, verts=16, parent=hs, name='handle')
    for x, z in ((-0.21, 0.505), (0.21, 0.545)):
        K.sphere((x, 0.01, z), 0.07, BAKE, scale=(1, 1.1, 0.75), parent=hs, name='cup')
    K.helix((0.21, 0.05, 0.50), (0.2, 1, -0.9), 0.48, 0.03, 12, 0.006, BAKE, parent=body, name='cord')
    K.export('Dottie', OUT)

# ---------------------------------------------------------------- NAN
def nan():
    K.reset()
    ROSE = K.mat('nanWoolRose', (0.58, 0.28, 0.30), rough=0.95); MUST = K.mat('nanWoolMustard', (0.78, 0.62, 0.30), rough=0.95)
    CHINA = K.mat('nanChina', (0.92, 0.93, 0.95), rough=0.12, coat=1); BLUE = K.mat('nanChinaBlue', (0.12, 0.22, 0.55), rough=0.15, coat=1)
    GAP = K.mat('nanGap', (0.08, 0.05, 0.05), rough=1); BR = brass()
    root = K.joint('hwNan'); body = K.joint('nanBody', (0, 0, 0), root)
    K.cyl((0, 0, 0.03), 0.22, 0.06, CHINA, verts=40, parent=body, name='foot')
    K.torus((0, 0, 0.05), 0.215, 0.012, BLUE, parent=body, name='footBand')
    # the cozy: ribbed dome built as knitted stripes (rose / mustard)
    def prof(z):  # dome radius at height z (0.05 .. 0.47)
        t = (z - 0.05) / 0.42; return 0.30 * math.sqrt(max(0.0, 1 - max(0.0, t - 0.25) ** 2 / 0.75 ** 2))
    rib = lambda lon, z: 1 + 0.035 * math.cos(lon * 24)
    zs = [0.05 + 0.42 * i / 9 for i in range(10)]
    for i, (z0, z1) in enumerate(zip(zs, zs[1:])):
        sub = [z0 + (z1 - z0) * k / 3 for k in range(4)]
        K.lathe(f'knit{i}', [(z - 0.0, prof(z), prof(z) * 0.93) for z in sub], ROSE if i % 2 == 0 else MUST,
                parent=body, nu=48, steps=1, wobble=rib, cap_top=(i == 8))
    K.sphere((0, 0, 0.50), 0.07, MUST, parent=body, name='pompom', seg=20, ring=12)
    K.tube([(-0.22, -0.10, 0.18), (-0.32, -0.16, 0.24), (-0.38, -0.20, 0.33), (-0.40, -0.21, 0.37)], 0.03, CHINA, parent=body, name='spout')
    K.tube([(0.24, 0.10, 0.30), (0.36, 0.12, 0.28), (0.38, 0.12, 0.16), (0.25, 0.10, 0.12)], 0.022, CHINA, parent=body, name='handle')
    K.sphere((0, -0.215, 0.32), 0.12, GAP, scale=(1, 0.3, 0.38), parent=body, name='knitGap')
    eyes = K.joint('nanEyes', (0, -0.235, 0.32), body); pupils = K.joint('nanPupils', (0, -0.235, 0.32), eyes)
    for s in (-1, 1):
        K.eye((s * 0.055, -0.235, 0.32), 0.045, CHINA, look=(0, -1, 0), lid=0.55, lid_tilt=s * 0.15, parent=eyes, prefix='eye')
        K.torus((s * 0.055, -0.285, 0.32), 0.05, 0.004, BR, rot=(math.pi / 2, 0, 0), parent=eyes, name='spectacle')
    for o in bpy.context.scene.objects:
        if 'Pupil' in o.name and o.type == 'MESH': K.own(o, pupils)
    K.rod((-0.006, -0.286, 0.32), (0.006, -0.286, 0.32), 0.004, BR, parent=eyes, name='bridge')
    for s in (-1, 1):
        K.tube([(s * 0.105, -0.285, 0.32), (s * 0.15, -0.20, 0.24), (s * 0.12, -0.15, 0.10)], 0.002, BR, parent=body, name='chain')
    K.export('Nan', OUT)

for w in WHICH:
    globals()[w]()
