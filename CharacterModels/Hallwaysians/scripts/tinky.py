# MR. TINKY -- Hallwaysian. A tin can lying on its side on four pencil legs
# (sharpened ends up into the can, pink eraser feet), bottle-cap ears, bead
# eyes on little springs on the front lid, a coiled-spring tail with a bead,
# a faded two-tone paper label. Built facing Blender +Y = SceneKit -Z (his
# original forward). Same proportions and joint names as TinCanRatModel:
# tinCanRatBody (at bodyHeight 0.16) > tinCanRatLeg0..3 (FL FR BL BR hips),
# tinCanRatEar0/1 (disc axis = up; the game tilts them forward), tinCanRatTail.
# The game scales him 2x.
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hallwaysian_kit as K
OUT = sys.argv[sys.argv.index('--out') + 1]
K.reset()
TIN = K.mat('tinkyTin', (0.76, 0.77, 0.79), metal=1, rough=0.24)
RIM = K.mat('tinkyRim', (0.66, 0.67, 0.69), metal=1, rough=0.2)
LABEL = K.mat('tinkyLabel', (0.66, 0.14, 0.10), rough=0.65)
CREAM = K.mat('tinkyLabelCream', (0.88, 0.82, 0.66), rough=0.7)
PENCIL = K.mat('tinkyPencil', (0.96, 0.74, 0.12), rough=0.55)
WOOD = K.mat('tinkyPencilWood', (0.86, 0.70, 0.50), rough=0.8)
LEAD = K.mat('tinkyLead', (0.15, 0.15, 0.16), metal=0.4, rough=0.4)
FERRULE = K.mat('tinkyFerrule', (0.74, 0.74, 0.70), metal=1, rough=0.3)
ERASER = K.mat('tinkyEraser', (0.93, 0.55, 0.60), rough=0.85)
CAP = K.mat('tinkyCap', (0.72, 0.12, 0.10), metal=0.5, rough=0.3)
SPRING = K.mat('tinkySpring', (0.80, 0.81, 0.83), metal=1, rough=0.2)
BEAD = K.mat('tinkyBead', (0.10, 0.34, 0.62), rough=0.15, coat=1)

H = 0.16; R = 0.07; L = 0.20
root = K.joint('hwTinky')
body = K.joint('tinCanRatBody', (0, 0, H), root)
RX = (math.pi / 2, 0, 0)                      # cylinder axis along Y (the can lies along his length)
K.cyl((0, 0, H), R, L, TIN, rot=RX, verts=32, parent=body, name='can')
K.cyl((0, 0, H), R + 0.0012, 0.11, LABEL, rot=RX, verts=32, parent=body, name='label', cap=False)
for y in (-0.036, 0.036):
    K.cyl((0, y, H), R + 0.0016, 0.012, CREAM, rot=RX, verts=32, parent=body, name='labelStripe', cap=False)
for y in (-L / 2, L / 2):
    K.torus((0, y, H), R, 0.0055, RIM, rot=RX, maj=32, mino=8, parent=body, name='rim')
for y in (-0.072, -0.064, 0.064, 0.072):
    K.torus((0, y, H), R + 0.0004, 0.0022, TIN, rot=RX, maj=32, mino=6, parent=body, name='bead')
K.torus((0, L / 2 + 0.001, H), 0.048, 0.0025, RIM, rot=RX, maj=28, mino=6, parent=body, name='lidRing')
# eyes on short springs out of the front lid
for s in (-1, 1):
    base = (s * 0.03, L / 2, H + 0.025)
    K.helix(base, (0, 1, 0.1), 0.016, 0.006, 3.0, 0.0016, SPRING, parent=body, name='eyeSpring')
    K.eye((s * 0.03, L / 2 + 0.032, H + 0.027), 0.02, TIN, look=(s * 0.12, 1, 0.08), lid=0.12, pupil=0.5,
          parent=body, prefix='eye')
# bottle-cap ears: crimped discs, axis up (the game tilts them to face forward)
for i, s in enumerate((-1, 1)):
    ear = K.joint(f'tinCanRatEar{i}', (s * 0.045, L / 2 - 0.03, H + R + 0.012), body)
    import bmesh, bpy
    bm = bmesh.new(); n = 42; rows = []
    for (z, rr) in ((-0.004, 0.024), (0.003, 0.026), (0.004, 0.0)):
        row = []
        for k in range(n):
            a = 2 * math.pi * k / n
            r = rr * (1 + (0.07 if (k % 2 and rr > 0.025) else 0))
            row.append(bm.verts.new((math.cos(a) * r, math.sin(a) * r, z)))
        rows.append(row)
    for j in range(2):
        for k in range(n):
            bm.faces.new((rows[j][k], rows[j][(k + 1) % n], rows[j + 1][(k + 1) % n], rows[j + 1][k]))
    bm.faces.new(list(reversed(rows[0])))
    me = bpy.data.meshes.new('capMesh'); bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new(f'cap{i}', me); bpy.context.scene.collection.objects.link(o)
    o.location = ear.location
    K._finish(o, CAP, parent=ear)
# coiled-spring tail off the back lid, with a bead
tail = K.joint('tinCanRatTail', (0, -L / 2, H + 0.01), body)
K.helix((0, -L / 2, H + 0.012), (0, -1, 0.85), 0.20, 0.008, 9, 0.0022, SPRING, parent=tail, name='tailSpring', taper=0.4)
K.sphere((0, -L / 2 - 0.20 * 0.762, H + 0.012 + 0.20 * 0.648), 0.011, BEAD, parent=tail, name='tailBead')
# pencil legs: hips FL FR BL BR (front = +Y here)
hips = [(-0.042, 0.06), (0.042, 0.06), (-0.042, -0.06), (0.042, -0.06)]
hz = H - R * 0.55
for i, (x, y) in enumerate(hips):
    leg = K.joint(f'tinCanRatLeg{i}', (x, y, hz), body)
    K.rod((x, y, hz + 0.012), (x, y, hz + 0.022), 0.0045, WOOD, r1=0.0012, verts=6, parent=leg, name='pencilTip', smooth=False)
    K.rod((x, y, hz - 0.075), (x, y, hz + 0.012), 0.0058, PENCIL, verts=6, parent=leg, name='pencil', smooth=False)
    K.cyl((x, y, hz - 0.083), 0.0061, 0.016, FERRULE, verts=12, parent=leg, name='ferrule')
    K.sphere((x, y, 0.016), 0.0072, ERASER, scale=(1, 1, 1.9), seg=12, ring=8, parent=leg, name='eraser')
K.export('MrTinky', OUT)
