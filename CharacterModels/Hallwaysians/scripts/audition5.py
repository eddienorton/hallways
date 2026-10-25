# AUDITION, ROUND FIVE (Oct 12, refinement): "the character must read before
# the mechanism does." Three revisions, simple and substantial, faces big:
#   VIEW-MASTER 2  one rounded red body, two big black-rimmed eyepieces (its
#                  eyes), the nose notch for a mouth, the reel's white crest,
#                  one plain lever. (Round three's version is kept.)
#   ROLODEX 2      a chunky black base and two big wheels; a solid fan of
#                  cards; one big face card in front that flips. (Kept: v1.)
#   CAMERA         the vintage camera itself: eyes in the silver top plate,
#                  the lens for a mouth (its aperture opens), a small
#                  flashcube to one side like a hat. (Kept: the flashcube.)
import sys, os, math
import bpy, bmesh
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hallwaysian_kit as K
from mathutils import Vector
from audition import face_eye, brow, rot_to, lid_cap, WHITE, PUPIL, GLINT
from audition3 import apply_mods, cut, rounded_slab, eye_iris

OUT = sys.argv[sys.argv.index('--out') + 1]
ONLY = sys.argv[sys.argv.index('--only') + 1].split(',') if '--only' in sys.argv else None


def half_disc(name, center, r, depth, m, parent, up=True, segs=24):
    """A half disc in the x-z plane (flat side down when up=True), `depth` along y."""
    bm = bmesh.new()
    cx, cy, cz = center
    pts = [(cx + r * math.cos(math.pi * k / segs), cz + (1 if up else -1) * r * math.sin(math.pi * k / segs)) for k in range(segs + 1)]
    front = [bm.verts.new((x, cy - depth / 2, z)) for x, z in pts]
    back = [bm.verts.new((x, cy + depth / 2, z)) for x, z in pts]
    bm.faces.new(front); bm.faces.new(list(reversed(back)))
    for i in range(len(pts)):
        j = (i + 1) % len(pts)
        bm.faces.new((front[i], back[i], back[j], front[j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new(name, me); bpy.context.scene.collection.objects.link(o)
    o.data.materials.append(m)
    return K.own(o, parent)


def sector(name, a0, a1, r0, r1, width, axis_z, m, parent, steps=24):
    """A solid annular sector about the X axis at height axis_z: angles from
    straight up (0), positive toward the front (-Y)."""
    bm = bmesh.new()
    rings = []
    for k in range(steps + 1):
        a = a0 + (a1 - a0) * k / steps
        d = Vector((0, -math.sin(a), math.cos(a)))
        quad = []
        for (x, r) in ((-width / 2, r0), (width / 2, r0), (width / 2, r1), (-width / 2, r1)):
            p = Vector((x, 0, axis_z)) + d * r
            quad.append(bm.verts.new(p))
        rings.append(quad)
    bm.faces.new(rings[0]); bm.faces.new(list(reversed(rings[-1])))
    for k in range(steps):
        a, b = rings[k], rings[k + 1]
        for i in range(4):
            j = (i + 1) % 4
            bm.faces.new((a[i], a[j], b[j], b[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new(name, me); bpy.context.scene.collection.objects.link(o)
    o.data.materials.append(m)
    return K.own(o, parent)


# =============================================================== VIEW-MASTER 2
def viewmaster2():
    K.reset()
    RED = K.mat('vm2Red', (0.66, 0.05, 0.05), rough=0.28, coat=0.8)
    BLACK = K.mat('vm2Black', (0.03, 0.03, 0.035), rough=0.35, coat=0.5)
    DARK = K.mat('vm2Dark', (0.05, 0.0, 0.0), rough=0.8)
    REEL = K.mat('vm2Reel', (0.96, 0.95, 0.91), rough=0.4)
    FILM = K.mat('vm2Film', (0.55, 0.62, 0.70), rough=0.3)
    SLIDE = K.mat('vm2SlideWhite', (0.98, 0.96, 0.90), rough=0.25)
    IRIS = K.mat('vm2Iris', (0.15, 0.45, 0.85), rough=0.25)
    GLASS = K.mat('vm2LensGlass', (0.7, 0.75, 0.8), rough=0.03, coat=1)
    root = K.joint('hwViewMaster2'); body = K.joint('vm2Body', (0, 0, 0), root)
    for s in (-1, 1):
        K.box((s * 0.11, 0, 0.008), (0.07, 0.14, 0.016), BLACK, bevel=0.005, parent=body, name='foot')
    head = K.joint('vm2Head', (0, 0, 0.016), body)
    shell = rounded_slab('shell', 0.36, 0.30, 0.18, 0.075, RED, segs=8, parent=head)
    shell.location = (0, 0, 0.17)
    bv = shell.modifiers.new('bv', 'BEVEL'); bv.width = 0.025; bv.segments = 4; bv.limit_method = 'ANGLE'
    apply_mods(shell)
    # the nose notch: a deep arch up from the bottom edge (its mouth sits in it)
    notch = rounded_slab('notchCut', 0.10, 0.18, 0.3, 0.05, RED, segs=10)
    notch.location = (0, 0, 0.02)
    cut(shell, notch)
    for p in shell.data.polygons: p.use_smooth = True
    if hasattr(shell.data, 'set_sharp_from_angle'): shell.data.set_sharp_from_angle(angle=math.radians(40))
    # eyepieces: big black-rimmed barrels -- its eyes
    for s in (1, -1):
        c = Vector((s * 0.085, -0.09, 0.205))
        K.cyl(c + Vector((0, -0.02, 0)), 0.074, 0.04, RED, rot=(math.pi / 2, 0, 0), verts=48, parent=head, name='barrel')
        K.torus(c + Vector((0, -0.04, 0)), 0.068, 0.012, BLACK, rot=(math.pi / 2, 0, 0), maj=48, mino=10, parent=head, name='rim')
        eye_iris('vm2', s, c + Vector((0, -0.012, 0)), 0.056, RED, head, iris=IRIS, look=(s * 0.03, -1, 0.0),
                 pupil=0.62, back=0.4, white=SLIDE)
        K.cyl(c + Vector((0, -0.05, 0)), 0.06, 0.003, GLASS, rot=(math.pi / 2, 0, 0), verts=48, parent=head, name='lensGlass')
        brow('vm2', s, (s * 0.085, -0.1, 0.3), 0.1, 0.012, BLACK, head, tilt=-0.04, curve=0.012)
    # the mouth, at the top of the notch: a dark arch that opens
    m = K.joint('vm2Mouth', (0, -0.085, 0.105), head)
    half_disc('mouthArch', (0, -0.085, 0.07), 0.04, 0.02, DARK, m, up=True)
    # the reel: a white crest out of the slot on its head
    K.box((0, 0.02, 0.322), (0.22, 0.03, 0.014), BLACK, bevel=0.004, parent=head, name='slot')
    reel = K.joint('vm2Reel', (0, 0.02, 0.27), head)
    K.cyl((0, 0.02, 0.27), 0.135, 0.01, REEL, rot=(math.pi / 2, 0, 0), verts=64, parent=reel, name='reelDisc')
    K.cyl((0, 0.02, 0.27), 0.02, 0.014, REEL, rot=(math.pi / 2, 0, 0), verts=24, parent=reel, name='reelHub')
    for k in range(7):
        a = 2 * math.pi * k / 7 + math.pi / 2
        K.box((math.cos(a) * 0.1, 0.014, 0.27 + math.sin(a) * 0.1), (0.03, 0.004, 0.022), FILM, rot=(0, -a, 0), bevel=0.002, parent=reel, name='frame')
    # one plain lever on its left side (+x)
    lv = K.joint('vm2Lever', (0.185, 0.05, 0.26), head)
    K.cyl((0.187, 0.05, 0.26), 0.022, 0.014, BLACK, rot=(0, math.pi / 2, 0), parent=lv, name='leverHub')
    K.tube([(0.19, 0.05, 0.26), (0.205, 0.0, 0.2), (0.207, -0.03, 0.13)], 0.014, RED, parent=lv, name='leverArm')
    K.sphere((0.207, -0.035, 0.115), 0.028, RED, scale=(0.7, 1, 1.2), parent=lv, name='leverKnob')
    K.export('AuditionViewMaster2', OUT, face='+Z')


# =============================================================== ROLODEX 2
CARDS2 = 8
FACES2 = {0: 'neutral', 1: 'blink', 3: 'worried', 4: 'happy', 6: 'surprised', 7: 'scowl'}


def rolodex2():
    K.reset()
    BLACK = K.mat('rol2Black', (0.04, 0.04, 0.045), rough=0.3, coat=0.6)
    CHROME = K.mat('rol2Chrome', (0.85, 0.86, 0.88), metal=1, rough=0.15)
    CARD = K.mat('rol2Card', (0.97, 0.95, 0.88), rough=0.75)
    EDGE = K.mat('rol2CardEdge', (0.80, 0.77, 0.68), rough=0.8)
    INK = K.mat('rol2Ink', (0.06, 0.08, 0.2), rough=0.6)
    INKR = K.mat('rol2InkRed', (0.75, 0.12, 0.10), rough=0.6)
    tabs = [K.mat(f'rol2Tab{i}', c, rough=0.4) for i, c in enumerate([(0.88, 0.2, 0.2), (0.2, 0.45, 0.88), (0.25, 0.68, 0.3), (0.98, 0.78, 0.15)])]
    root = K.joint('hwRolodex2'); body = K.joint('rol2Body', (0, 0, 0), root)
    K.box((0, 0, 0.03), (0.40, 0.28, 0.06), BLACK, bevel=0.02, parent=body, name='base')
    K.box((0, -0.141, 0.03), (0.36, 0.004, 0.012), CHROME, bevel=0.002, parent=body, name='baseTrim')
    head = K.joint('rol2Head', (0, 0, 0.06), body)
    AX = 0.2
    for s in (1, -1):
        S = 'L' if s > 0 else 'R'
        kj = K.joint(f'rol2Knob{S}', (s * 0.19, 0, AX), head)
        K.cyl((s * 0.19, 0, AX), 0.13, 0.03, BLACK, rot=(0, math.pi / 2, 0), verts=56, parent=kj, name='wheel')
        K.torus((s * 0.206, 0, AX), 0.13, 0.008, CHROME, rot=(0, math.pi / 2, 0), maj=56, mino=8, parent=kj, name='wheelRim')
        K.cyl((s * 0.21, 0, AX), 0.04, 0.02, CHROME, rot=(0, math.pi / 2, 0), verts=32, parent=kj, name='hub')
        for k in range(4):
            a = math.pi / 4 + k * math.pi / 2
            K.box((s * 0.207, math.cos(a) * 0.085, AX + math.sin(a) * 0.085), (0.008, 0.03, 0.03), CHROME, bevel=0.006, parent=kj, name='grip')
        K.box((s * 0.19, 0, 0.1), (0.03, 0.05, 0.1), BLACK, bevel=0.01, parent=head, name='strut')
    K.cyl((0, 0, AX), 0.012, 0.38, CHROME, rot=(0, math.pi / 2, 0), parent=head, name='axle')
    # the fan of cards: one solid mass behind, a little one fallen in front
    sector('fanBack', -0.3, -1.75, 0.02, 0.165, 0.32, AX, CARD, head)
    sector('fanFront', 1.05, 1.6, 0.02, 0.165, 0.32, AX, CARD, head)
    for k in range(9):
        a = -0.4 - k * 0.15
        sector(f'groove{k}', a, a - 0.012, 0.03, 0.166, 0.322, AX, EDGE, head, steps=1)
    for k in range(4):
        a = -0.38
        x = -0.11 + k * 0.073
        d = Vector((0, -math.sin(a), math.cos(a)))
        K.box(Vector((x, 0, AX)) + d * 0.18, (0.05, 0.006, 0.03), tabs[k], rot=(a, 0, 0), bevel=0.004, parent=head, name='tab')
    # the face cards (one joint each, on the axle): the face is the card that's up
    W, R0, R1 = 0.30, 0.02, 0.19
    for i in range(CARDS2):
        cj = K.joint(f'rol2Card{i}', (0, 0, AX), head)
        K.box((0, 0, AX + (R0 + R1) / 2), (W, 0.003, R1 - R0), CARD, bevel=0.0, parent=cj, name='card')
        K.box((-0.09 + (i % 4) * 0.06, 0, AX + R1 + 0.012), (0.05, 0.004, 0.025), tabs[i % 4], bevel=0.003, parent=cj, name='cardTab')
        y = -0.0022
        face = FACES2.get(i)
        if face is None:
            K.box((-0.05, y, AX + 0.165), (0.16, 0.001, 0.012), INK, bevel=0, parent=cj, name='nameLine')
            for k in range(3):
                K.box((-0.02, y, AX + 0.13 - k * 0.025), (0.2 - k * 0.03, 0.001, 0.006), INK, bevel=0, parent=cj, name='line')
            continue
        ez = AX + 0.145
        for s in (1, -1):
            ex = s * 0.07
            if face == 'blink':
                K.tube([(ex - 0.028, y, ez - 0.002), (ex, y, ez - 0.01), (ex + 0.028, y, ez - 0.002)], 0.005, INK, parent=cj, name='inkLid')
            elif face == 'happy':
                K.tube([(ex - 0.028, y, ez - 0.01), (ex, y, ez + 0.012), (ex + 0.028, y, ez - 0.01)], 0.006, INK, parent=cj, name='inkArc')
            else:
                r = 0.03 if face == 'surprised' else 0.025
                K.torus((ex, y, ez), r, 0.005, INK, rot=(math.pi / 2, 0, 0), maj=32, mino=6, parent=cj, name='inkEye')
                K.sphere((ex - (0.006 * s if face == 'worried' else 0), y - 0.001, ez - (0.005 if face == 'scowl' else 0)),
                         0.012, INK, scale=(1, 0.15, 1), seg=16, ring=8, parent=cj, name='inkPupil')
            if face in ('worried', 'scowl', 'surprised'):
                bz = ez + (0.05 if face == 'surprised' else 0.042)
                if face == 'worried':
                    a, b = (ex - s * 0.03, bz + 0.008), (ex + s * 0.03, bz - 0.006)
                elif face == 'scowl':
                    a, b = (ex - s * 0.03, bz - 0.01), (ex + s * 0.03, bz + 0.006)
                else:
                    a, b = (ex - s * 0.03, bz), (ex + s * 0.03, bz)
                K.tube([(a[0], y, a[1]), (b[0], y, b[1])], 0.005, INK, parent=cj, name='inkBrow')
        mz = AX + 0.085
        if face == 'happy':
            K.tube([(-0.05, y, mz + 0.012), (-0.025, y, mz - 0.01), (0, y, mz - 0.016), (0.025, y, mz - 0.01), (0.05, y, mz + 0.012)], 0.007, INKR, parent=cj, name='inkMouth')
        elif face == 'surprised':
            K.torus((0, y, mz - 0.004), 0.022, 0.006, INKR, rot=(math.pi / 2, 0, 0), maj=28, mino=6, parent=cj, name='inkMouth')
        elif face == 'worried':
            K.tube([(-0.04, y, mz - 0.006), (-0.02, y, mz + 0.004), (0, y, mz - 0.003), (0.02, y, mz + 0.005), (0.04, y, mz - 0.005)], 0.0055, INKR, parent=cj, name='inkMouth')
        elif face == 'scowl':
            K.tube([(-0.038, y, mz - 0.008), (0, y, mz + 0.004), (0.038, y, mz - 0.008)], 0.006, INKR, parent=cj, name='inkMouth')
        else:
            K.tube([(-0.034, y, mz + 0.004), (0, y, mz - 0.008), (0.034, y, mz + 0.004)], 0.0055, INKR, parent=cj, name='inkMouth')
    K.export('AuditionRolodex2', OUT, face='+Z')


# =============================================================== THE CAMERA
def camera():
    K.reset()
    LEATHER = K.mat('camLeather', (0.035, 0.035, 0.038), rough=0.75)
    SILVER = K.mat('camSilver', (0.82, 0.82, 0.84), metal=1, rough=0.22)
    BLACK = K.mat('camBlack', (0.02, 0.02, 0.022), rough=0.3, coat=0.6)
    RED = K.mat('camRed', (0.8, 0.1, 0.08), rough=0.35)
    LENSGLASS = K.mat('camLensDark', (0.05, 0.07, 0.12), rough=0.03, coat=1)
    APERTURE = K.mat('camAperture', (0.0, 0.0, 0.0), rough=0.9)
    WINDOW = K.mat('camWindowGlass', (0.7, 0.75, 0.8), rough=0.03, coat=1)
    IRIS = K.mat('camIris', (0.42, 0.26, 0.10), rough=0.2)
    BULB = K.mat('camBulb', (0.85, 0.92, 1.0), rough=0.08)
    BLIST = K.mat('camBlistGlass', (0.55, 0.75, 0.95), rough=0.05, coat=1)
    PLASTIC = K.mat('camPlastic', (0.12, 0.12, 0.13), rough=0.35)
    root = K.joint('hwCamera'); body = K.joint('camBody', (0, 0, 0), root)
    for s in (-1, 1):
        K.box((s * 0.15, 0, 0.006), (0.06, 0.12, 0.012), BLACK, bevel=0.004, parent=body, name='foot')
    head = K.joint('camHead', (0, 0, 0.012), body)
    K.box((0, 0, 0.1), (0.42, 0.16, 0.18), LEATHER, bevel=0.025, parent=head, name='bodyLower')
    K.box((0, 0, 0.225), (0.425, 0.165, 0.09), SILVER, bevel=0.025, parent=head, name='topPlate')
    K.box((0, -0.081, 0.185), (0.41, 0.006, 0.006), BLACK, bevel=0.0, parent=head, name='seam')
    # its eyes: two round windows in the silver plate
    for s in (1, -1):
        c = Vector((s * 0.09, -0.07, 0.228))
        K.torus(c + Vector((0, -0.04, 0)), 0.045, 0.009, BLACK, rot=(math.pi / 2, 0, 0), maj=40, mino=8, parent=head, name='windowRim')
        eye_iris('cam', s, c, 0.04, SILVER, head, iris=IRIS, look=(s * 0.04, -1, 0.02), pupil=0.6, back=0.35)
        K.cyl(c + Vector((0, -0.043, 0)), 0.042, 0.003, WINDOW, rot=(math.pi / 2, 0, 0), verts=40, parent=head, name='windowGlass')
        brow('cam', s, (s * 0.09, -0.088, 0.284), 0.08, 0.01, BLACK, head, tilt=-0.05, curve=0.008)
    # the lens: its mouth (the aperture opens); it zooms to look closer
    lens = K.joint('camLens', (0, -0.08, 0.1), head)
    K.cyl((0, -0.09, 0.1), 0.078, 0.02, SILVER, rot=(math.pi / 2, 0, 0), verts=48, parent=lens, name='lensMount')
    K.cyl((0, -0.115, 0.1), 0.066, 0.05, BLACK, rot=(math.pi / 2, 0, 0), verts=48, parent=lens, name='barrel')
    K.torus((0, -0.14, 0.1), 0.066, 0.006, SILVER, rot=(math.pi / 2, 0, 0), maj=48, mino=8, parent=lens, name='lensRing')
    for k in range(24):
        a = 2 * math.pi * k / 24
        K.box((math.cos(a) * 0.069, -0.112, 0.1 + math.sin(a) * 0.069), (0.006, 0.03, 0.006), SILVER, rot=(0, -a, 0), bevel=0, parent=lens, name='knurl')
    K.cyl((0, -0.141, 0.1), 0.056, 0.004, LENSGLASS, rot=(math.pi / 2, 0, 0), verts=48, parent=lens, name='glass')
    m = K.joint('camMouth', (0, -0.144, 0.1), lens)
    K.cyl((0, -0.144, 0.1), 0.02, 0.003, APERTURE, rot=(math.pi / 2, 0, 0), verts=6, parent=m, name='aperture')
    # shutter button, the winding lever (it winds after every picture)
    K.cyl((-0.15, -0.02, 0.278), 0.014, 0.014, RED, parent=head, name='shutter')
    lv = K.joint('camLever', (0.16, 0.03, 0.272), head)
    K.cyl((0.16, 0.03, 0.276), 0.016, 0.01, SILVER, parent=lv, name='leverHub')
    K.box((0.12, 0.03, 0.28), (0.08, 0.016, 0.006), SILVER, bevel=0.003, parent=lv, name='leverArm')
    # a small flashcube to one side, like a hat (a secondary feature)
    fx = 0.13
    K.box((fx, 0.0, 0.285), (0.03, 0.03, 0.012), PLASTIC, bevel=0.003, parent=head, name='socket')
    K.box((fx, 0.0, 0.33), (0.07, 0.07, 0.07), BLIST, bevel=0.008, parent=head, name='flashCube')
    K.sphere((fx, -0.03, 0.33), 0.014, BULB, parent=head, name='camBulbFront')
    K.box((fx, -0.028, 0.33), (0.05, 0.002, 0.05), SILVER, bevel=0.002, parent=head, name='reflector')
    # wrist strap
    K.tube([(-0.21, 0.0, 0.2), (-0.24, -0.01, 0.14), (-0.235, 0.0, 0.06), (-0.215, 0.01, 0.04)], 0.006, BLACK, parent=head, name='strap')
    K.export('AuditionCamera', OUT, face='+Z')


for name, fn in (('viewmaster2', viewmaster2), ('rolodex2', rolodex2), ('camera', camera)):
    if ONLY is None or name in ONLY:
        fn()
