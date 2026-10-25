# AUDITION, ROUND THREE -- yesterday's technology (Oct 12): the rotary
# telephone, the View-Master, the Rolodex, the flashcube (on its Instamatic)
# and the rabbit-ear television. Same kit and export contract as rounds one
# and two. Faces come from each object's own mechanism:
#   TELEPHONE   eyes = the cradle plungers; brow = the handset (it lifts, it
#               slams); mouth = the dial's centre card; the dial turns.
#   VIEW-MASTER eyes = the eyepieces (each blink is a slide change: the
#               lever clicks, the reel advances, the irises change colour);
#               mouth = the nose notch.
#   ROLODEX     its face is drawn on its cards: expressions are cards it
#               flips to (a riffle through contacts on the way).
#   FLASHCUBE   one eye per side (reflector + bulb); a quarter turn shows
#               another side -- one of them burned out. Mouth = the
#               Instamatic's lens below.
#   TELEVISION  a glowing face on the screen; brows/arms = the rabbit ears.
# All face +Z in SceneKit (Blender -Y); origin = the bottom of the character.
import sys, os, math
import bpy, bmesh
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hallwaysian_kit as K
from mathutils import Vector, Matrix
from audition import face_eye, brow, rot_to, lid_cap, WHITE, PUPIL, GLINT

OUT = sys.argv[sys.argv.index('--out') + 1]
ONLY = sys.argv[sys.argv.index('--only') + 1].split(',') if '--only' in sys.argv else None


# ------------------------------------------------------------------ helpers
def apply_mods(o):
    bpy.context.view_layer.objects.active = o
    for m in list(o.modifiers):
        bpy.ops.object.modifier_apply(modifier=m.name)


def cut(target, cutter):
    b = target.modifiers.new('cut', 'BOOLEAN'); b.operation = 'DIFFERENCE'; b.solver = 'EXACT'; b.object = cutter
    apply_mods(target)
    bpy.data.objects.remove(cutter)


def prism(name, profile_yz, width, m, bevel=0.0, segs=4, parent=None):
    """A solid extruded along X from a closed (y, z) profile, edges rounded."""
    bm = bmesh.new()
    a = [bm.verts.new((-width / 2, y, z)) for (y, z) in profile_yz]
    b = [bm.verts.new((width / 2, y, z)) for (y, z) in profile_yz]
    n = len(profile_yz)
    bm.faces.new(list(reversed(a)))
    bm.faces.new(b)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((a[i], a[j], b[j], b[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new(name, me); bpy.context.scene.collection.objects.link(o)
    if bevel:
        bv = o.modifiers.new('bv', 'BEVEL'); bv.width = bevel; bv.segments = segs; bv.limit_method = 'ANGLE'
        apply_mods(o)
    o.data.materials.append(m)
    for p in o.data.polygons: p.use_smooth = True
    if hasattr(o.data, 'set_sharp_from_angle'): o.data.set_sharp_from_angle(angle=math.radians(35))
    return K.own(o, parent)


def rounded_slab(name, w, h, depth, r, m, segs=6, parent=None):
    """A slab w (x) by h (z), `depth` along y, rounded in the x-z plane."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co.x *= w; v.co.y *= depth; v.co.z *= h
    edges = [e for e in bm.edges if abs(e.verts[0].co.y - e.verts[1].co.y) > 1e-6]
    bmesh.ops.bevel(bm, geom=edges, offset=r, segments=segs, affect='EDGES', profile=0.5)
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new(name, me); bpy.context.scene.collection.objects.link(o)
    o.data.materials.append(m)
    return K.own(o, parent)


def flat_disc(loc, r, depth, m, normal=(0, -1, 0), parent=None, name='disc', verts=32, scale=(1, 1, 1)):
    o = K.cyl(loc, r, depth, m, rot=rot_to(normal), verts=verts, parent=parent, name=name)
    o.scale = scale
    return o


def ink_dot(loc, r, m, parent, name='ink', sy=0.25):
    return K.sphere(loc, r, m, scale=(1, sy, 1), seg=16, ring=8, parent=parent, name=name)


def eye_iris(p, side, center, r, lid_m, head, iris, look=(0, -1, 0), pupil=0.5, back=0.55, white=None, lid=True):
    """face_eye with a coloured iris ring around the pupil."""
    S = 'L' if side > 0 else 'R'
    e = face_eye(p, side, center, r, lid_m, head, look=look, pupil=pupil * 0.55, back=back, white=white, lid=lid)
    pj = bpy.data.objects[f'{p}Pupil{S}']
    L = Vector(look).normalized()
    K.sphere(Vector(center) + L * (r * 0.72), r * pupil, iris, seg=20, ring=12, scale=(1, 1, 1), parent=pj, name=f'{p}Iris{S}')
    return e


# =============================================================== THE TELEPHONE (the chairman?)
def telephone():
    K.reset()
    BAK = K.mat('telBakelite', (0.010, 0.010, 0.012), rough=0.16, coat=1.0)
    NICKEL = K.mat('telNickel', (0.82, 0.82, 0.80), metal=1, rough=0.18)
    CARD = K.mat('telCard', (0.94, 0.92, 0.85), rough=0.5)
    RED = K.mat('telRed', (0.62, 0.07, 0.06), rough=0.4)
    PLUNGER = K.mat('telPlunger', (0.93, 0.92, 0.88), rough=0.12)
    FELT = K.mat('telFelt', (0.18, 0.13, 0.10), rough=1)
    MOUTH = K.mat('telMouthDark', (0.02, 0.0, 0.0), rough=0.9)
    root = K.joint('hwTelephone'); body = K.joint('telBody', (0, 0, 0), root)
    for sx in (-1, 1):
        for sy in (-1, 1):
            K.cyl((sx * 0.12, sy * 0.13, 0.004), 0.018, 0.008, FELT, parent=body, name='foot')
    head = K.joint('telHead', (0, 0, 0.008), body)          # the whole set turns, deliberately
    prof = [(-0.165, 0.008), (-0.172, 0.03), (-0.162, 0.05), (-0.045, 0.138), (0.04, 0.152),
            (0.125, 0.147), (0.163, 0.095), (0.168, 0.008)]
    prism('telShell', prof, 0.30, BAK, bevel=0.028, segs=5, parent=head)
    K.box((0, 0, 0.012), (0.27, 0.30, 0.012), BAK, bevel=0.004, parent=head, name='telSkirt')
    # the dial, on the sloping front
    n = Vector((0, -0.6, 0.8)).normalized()
    c = Vector((0, -0.104, 0.094)) + n * 0.004
    flat_disc(c, 0.072, 0.006, CARD, normal=n, parent=head, name='numberPlate')
    for k in range(10):                                      # the numbers: small dark marks under the holes
        a = math.radians(60 + k * 30)
        u = Vector((1, 0, 0)); v = n.cross(u)
        q = c + n * 0.0035 + (u * math.cos(a) + v * math.sin(a)) * 0.056
        K.sphere(q, 0.004, BAK, scale=(1, 1, 1), seg=8, ring=6, parent=head, name='numberMark')
    dial = K.joint('telDial', c, head)
    wheel = flat_disc(c + n * 0.007, 0.066, 0.008, BAK, normal=n, parent=dial, name='fingerWheel', verts=48)
    for k in range(10):
        a = math.radians(60 + k * 30)
        u = Vector((1, 0, 0)); v = n.cross(u)
        q = c + n * 0.007 + (u * math.cos(a) + v * math.sin(a)) * 0.048
        hole = K.cyl(q, 0.0115, 0.03, BAK, rot=rot_to(n), verts=20)
        cut(wheel, hole)
    K.torus(c + n * 0.011, 0.066, 0.0035, NICKEL, rot=rot_to(n), maj=48, mino=6, parent=dial, name='wheelRim')
    # finger stop (fixed, lower right as you face it = its left, +x)
    u = Vector((1, 0, 0)); v = n.cross(u)
    fs = c + n * 0.01 + (u * math.cos(math.radians(-35)) + v * math.sin(math.radians(-35))) * 0.07
    K.rod(fs - (u * 0.0) + n * 0.0, fs + (u * -0.012 + v * 0.012) + n * 0.014, 0.004, NICKEL, parent=head, name='fingerStop')
    # the mouth: the dial's centre card (a white card, a red ring; it opens dark)
    flat_disc(c + n * 0.013, 0.027, 0.004, CARD, normal=n, parent=head, name='centerCard')
    K.torus(c + n * 0.016, 0.027, 0.0025, RED, rot=rot_to(n), maj=32, mino=6, parent=head, name='centerRing')
    m = K.joint('telMouth', c + n * 0.017, head)
    K.sphere(c + n * 0.016, 0.016, MOUTH, scale=(1.0, 1.0, 1.0), seg=24, ring=12, parent=m, name='mouthO')
    mo = bpy.data.objects['mouthO']
    # flatten the mouth into the dial's plane, thin "closed" line
    mo.scale = (1.0, 0.25, 0.25)
    mo.rotation_euler = rot_to(Vector((0, 0.8, 0.6)))        # local Z along the slope's up direction
    # the cradle horns, and the plungers between them: its eyes
    for s in (1, -1):
        K.box((s * 0.112, 0.03, 0.172), (0.062, 0.085, 0.06), BAK, bevel=0.024, parent=head, name='horn')
    for s in (1, -1):
        eye_iris('tel', s, (s * 0.044, -0.018, 0.158), 0.027, BAK, head, iris=K.mat('telIris', (0.30, 0.20, 0.10), rough=0.2),
                 look=(s * 0.04, -1, 0.1), pupil=0.55, back=0.25, white=PLUNGER)
    # the handset: its great brow (lifts, tilts, slams)
    h = K.joint('telHandset', (0, 0.02, 0.205), head)
    K.tube([(-0.12, 0.02, 0.212), (-0.07, 0.02, 0.226), (0, 0.02, 0.232), (0.07, 0.02, 0.226), (0.12, 0.02, 0.212)],
           0.019, BAK, parent=h, name='handle')
    for s in (-1, 1):
        cc = Vector((s * 0.135, 0.02, 0.198))
        K.lathe(f'cup{s}', [(-0.028, 0.034, 0.034), (-0.012, 0.045, 0.045), (0.006, 0.047, 0.047), (0.018, 0.03, 0.03)],
                BAK, center=cc, parent=h, cap_bottom=True, cap_top=True, nu=36)
        K.cyl(cc + Vector((0, 0, -0.03)), 0.03, 0.004, NICKEL if s > 0 else BAK, parent=h, name='cupFace')
    # the coiled cord, from the mouthpiece end down to the back of the set
    K.helix((0.15, 0.06, 0.19), (0.02, 0.6, -1), 0.17, 0.011, 13, 0.0032, BAK, parent=h, name='cord')
    K.export('AuditionTelephone', OUT, face='+Z')


# =============================================================== THE VIEW-MASTER (the dreamer)
def viewmaster():
    K.reset()
    RED = K.mat('vmRed', (0.62, 0.05, 0.05), rough=0.25, coat=0.8)
    DARK = K.mat('vmDark', (0.04, 0.01, 0.01), rough=0.7)
    REEL = K.mat('vmReel', (0.95, 0.94, 0.90), rough=0.4)
    GLASS = K.mat('vmLensGlass', (0.70, 0.75, 0.80), rough=0.03, coat=1)
    SLIDE = K.mat('vmSlideWhite', (0.98, 0.95, 0.86), rough=0.3)
    chips = [K.mat(f'vmChip{i}', c, rough=0.3) for i, c in enumerate([(0.15, 0.45, 0.85), (0.2, 0.6, 0.25), (0.95, 0.6, 0.15),
                                                                       (0.85, 0.2, 0.35), (0.35, 0.3, 0.8), (0.95, 0.85, 0.3), (0.2, 0.7, 0.75)])]
    root = K.joint('hwViewMaster'); body = K.joint('vmBody', (0, 0, 0), root)
    for sx in (-1, 1):
        K.box((sx * 0.1, 0, 0.005), (0.05, 0.13, 0.01), DARK, bevel=0.004, parent=body, name='foot')
    head = K.joint('vmHead', (0, 0, 0.01), body)
    K.box((0, 0, 0.13), (0.30, 0.17, 0.24), RED, bevel=0.045, parent=head, name='shell')
    # the visor ridge over the eyepieces
    K.box((0, -0.075, 0.232), (0.27, 0.035, 0.03), RED, bevel=0.012, parent=head, name='visor')
    # eyepieces: barrels, lenses, and the slide-lit eyes behind them
    for s in (1, -1):
        bc = Vector((s * 0.07, -0.088, 0.165))
        K.cyl(bc + Vector((0, -0.012, 0)), 0.047, 0.03, RED, rot=(math.pi / 2, 0, 0), verts=40, parent=head, name='barrel')
        K.torus(bc + Vector((0, -0.028, 0)), 0.043, 0.006, RED, rot=(math.pi / 2, 0, 0), maj=40, mino=8, parent=head, name='barrelLip')
        eye_iris('vm', s, bc + Vector((0, -0.006, 0)), 0.034, DARK, head, iris=chips[0 if s > 0 else 1],
                 look=(s * 0.03, -1, 0.0), pupil=0.62, back=0.4, white=SLIDE)
        K.cyl(bc + Vector((0, -0.04, 0)), 0.04, 0.003, GLASS, rot=(math.pi / 2, 0, 0), verts=40, parent=head, name='lensGlass')
        brow('vm', s, (s * 0.07, -0.096, 0.236), 0.07, 0.008, RED, head, tilt=-0.05, curve=0.006)
    # the nose notch: its mouth (a dark arch at the bottom of the face)
    m = K.joint('vmMouth', (0, -0.088, 0.035), head)
    arch = K.cyl((0, -0.087, 0.035), 0.034, 0.012, DARK, rot=(math.pi / 2, 0, 0), verts=32, parent=m, name='notch')
    arch.scale = (1, 1, 1)
    K.box((0, -0.087, 0.022), (0.075, 0.014, 0.03), DARK, bevel=0.0, parent=m, name='notchBase') if False else None
    # the reel in its slot (a crest of slides), turning a frame at each blink
    K.box((0, 0.01, 0.255), (0.15, 0.022, 0.012), DARK, bevel=0.004, parent=head, name='slot')
    reel = K.joint('vmReel', (0, 0.01, 0.235), head)
    K.cyl((0, 0.01, 0.235), 0.11, 0.006, REEL, rot=(math.pi / 2, 0, 0), verts=56, parent=reel, name='reelDisc')
    K.cyl((0, 0.01, 0.235), 0.016, 0.009, REEL, rot=(math.pi / 2, 0, 0), verts=20, parent=reel, name='reelHub')
    for k in range(14):
        a = 2 * math.pi * k / 14
        K.box((math.cos(a) * 0.08, 0.01, 0.235 + math.sin(a) * 0.08), (0.026, 0.008, 0.02), chips[k % 7], rot=(0, -a, 0),
              bevel=0.002, parent=reel, name='slide')
    # the lever on its left side (+x): it clicks
    lv = K.joint('vmLever', (0.15, 0.045, 0.2), head)
    K.tube([(0.155, 0.045, 0.2), (0.17, 0.0, 0.17), (0.172, -0.03, 0.11), (0.172, -0.035, 0.07)], 0.01, RED, parent=lv, name='leverArm')
    K.sphere((0.172, -0.037, 0.06), 0.018, RED, scale=(0.6, 1, 1.3), parent=lv, name='leverPaddle')
    K.cyl((0.152, 0.045, 0.2), 0.016, 0.01, DARK, rot=(0, math.pi / 2, 0), parent=lv, name='leverHub')
    K.export('AuditionViewMaster', OUT, face='+Z')


# =============================================================== THE ROLODEX (the worrier)
CARDS = 18
FACE_CARDS = {0: 'neutral', 3: 'worried', 6: 'happy', 9: 'surprised', 12: 'scowl', 15: 'blink'}


def rolodex():
    K.reset()
    CHROME = K.mat('rolChrome', (0.84, 0.85, 0.87), metal=1, rough=0.15)
    BASE = K.mat('rolBase', (0.08, 0.08, 0.09), rough=0.35, coat=0.6)
    TAN = K.mat('rolTan', (0.55, 0.45, 0.30), rough=0.5)
    CARD = K.mat('rolCard', (0.97, 0.96, 0.92), rough=0.7)
    INK = K.mat('rolInk', (0.08, 0.10, 0.22), rough=0.6)
    INKR = K.mat('rolInkRed', (0.72, 0.12, 0.10), rough=0.6)
    tabs = [K.mat(f'rolTab{i}', c, rough=0.4) for i, c in enumerate([(0.85, 0.2, 0.2), (0.2, 0.45, 0.85), (0.25, 0.65, 0.3),
                                                                     (0.95, 0.75, 0.15), (0.6, 0.3, 0.75)])]
    root = K.joint('hwRolodex'); body = K.joint('rolBody', (0, 0, 0), root)
    K.cyl((0, 0, 0.012), 0.16, 0.024, BASE, scale=(1.0, 0.75, 1), verts=48, parent=body, name='base')
    K.torus((0, 0, 0.022), 0.16, 0.004, CHROME, maj=48, mino=6, parent=body, name='baseTrim').scale = (1, 0.75, 1)
    head = K.joint('rolHead', (0, 0, 0.024), body)           # the drum turns on its base
    AX = 0.125                                                 # spindle height
    for s in (1, -1):
        # side plates and knobs (the knobs turn with the drum)
        K.cyl((s * 0.135, 0, AX), 0.075, 0.008, CHROME, rot=(0, math.pi / 2, 0), verts=40, parent=head, name='sidePlate')
        K.box((s * 0.135, 0, 0.05), (0.008, 0.08, 0.06), CHROME, bevel=0.003, parent=head, name='sideLeg')
        kj = K.joint(f'rolKnob{"L" if s > 0 else "R"}', (s * 0.15, 0, AX), head)
        K.cyl((s * 0.152, 0, AX), 0.05, 0.022, TAN, rot=(0, math.pi / 2, 0), verts=36, parent=kj, name='knob')
        for k in range(6):
            a = 2 * math.pi * k / 6
            K.box((s * 0.165, math.cos(a) * 0.035, AX + math.sin(a) * 0.035), (0.006, 0.012, 0.012), CHROME, bevel=0.002,
                  parent=kj, name='knobStud')
    K.cyl((0, 0, AX), 0.006, 0.27, CHROME, rot=(0, math.pi / 2, 0), parent=head, name='spindle')
    K.box((0, 0, 0.034), (0.27, 0.06, 0.02), CHROME, bevel=0.004, parent=head, name='crossbar')
    # the cards: each its own joint on the spindle (rotate x to fan/flip)
    W, R0, R1 = 0.21, 0.018, 0.15
    for i in range(CARDS):
        cj = K.joint(f'rolCard{i}', (0, 0, AX), head)
        K.box((0, 0, AX + (R0 + R1) / 2), (W, 0.0025, R1 - R0), CARD, bevel=0.0, parent=cj, name='card')
        # the two spindle slots (dark) and an index tab
        tx = -0.07 + (i % 5) * 0.035
        K.box((tx, 0, AX + R1 + 0.008), (0.03, 0.003, 0.016), tabs[i % 5], bevel=0.002, parent=cj, name='tab')
        y = -0.0016
        face = FACE_CARDS.get(i)
        z0 = AX + (R0 + R1) / 2
        if face is None:
            # a contact card: a name and three lines
            K.box((-0.03, y, z0 + 0.04), (0.11, 0.001, 0.008), INK, bevel=0, parent=cj, name='nameLine')
            for k in range(3):
                K.box((-0.02 + (k % 2) * 0.01, y, z0 + 0.012 - k * 0.022), (0.13 - k * 0.02, 0.001, 0.004), INK, bevel=0, parent=cj, name='line')
            continue
        # a face, drawn on the card
        ez = z0 + 0.018
        for s in (1, -1):
            ex = s * 0.05
            if face == 'blink':
                K.box((ex, y, ez - 0.004), (0.036, 0.001, 0.006), INK, bevel=0, parent=cj, name='inkLid')
            elif face == 'happy':
                K.tube([(ex - 0.02, y, ez - 0.008), (ex, y, ez + 0.01), (ex + 0.02, y, ez - 0.008)], 0.004, INK, parent=cj, name='inkArc')
            else:
                r = 0.018 if face == 'surprised' else 0.0145
                ring = K.torus((ex, y, ez), r, 0.0025, INK, rot=(math.pi / 2, 0, 0), maj=24, mino=4, parent=cj, name='inkEye')
                look = 0.004 if face == 'worried' else 0.0
                ink_dot((ex + look * -s, y - 0.0005, ez - (0.002 if face == 'scowl' else 0)), 0.0075, INK, cj, name='inkPupil')
            if face in ('worried', 'scowl', 'surprised'):
                tilt = {'worried': -0.35, 'scowl': 0.4, 'surprised': 0.0}[face]
                bz = ez + (0.036 if face == 'surprised' else 0.029)
                K.tube([(ex - s * 0.016, y, bz + s * 0.016 * math.tan(tilt) * -1 * 0 + (-0.016) * math.tan(tilt) * (1 if s < 0 else 1) * 0),
                        (ex + s * 0.016, y, bz)], 0.003, INK, parent=cj, name='inkBrow') if False else None
                d = 0.02
                inner = Vector((ex - s * d, y, bz - (math.tan(tilt) * d if face != 'surprised' else 0)))
                outer = Vector((ex + s * d, y, bz + (math.tan(tilt) * d if face != 'surprised' else 0)))
                if face == 'worried':
                    inner, outer = Vector((ex - s * d, y, bz + 0.006)), Vector((ex + s * d, y, bz - 0.004))
                K.tube([tuple(inner), tuple(outer)], 0.003, INK, parent=cj, name='inkBrow')
        mz = z0 - 0.03
        if face == 'happy':
            K.tube([(-0.0405, y, mz + 0.008), (-0.0203, y, mz - 0.006), (0, y, mz - 0.01), (0.0203, y, mz - 0.006), (0.0405, y, mz + 0.008)],
                   0.0042, INKR, parent=cj, name='inkMouth')
        elif face == 'surprised':
            K.torus((0, y, mz - 0.002), 0.015, 0.0038, INKR, rot=(math.pi / 2, 0, 0), maj=24, mino=4, parent=cj, name='inkMouth')
        elif face == 'worried':
            K.tube([(-0.0297, y, mz - 0.004), (-0.0135, y, mz + 0.002), (0.0, y, mz - 0.002), (0.0135, y, mz + 0.003), (0.0297, y, mz - 0.003)],
                   0.004, INKR, parent=cj, name='inkMouth')
        elif face == 'scowl':
            K.tube([(-0.027, y, mz - 0.004), (0, y, mz + 0.002), (0.027, y, mz - 0.004)], 0.0042, INKR, parent=cj, name='inkMouth')
        else:
            K.tube([(-0.0243, y, mz + 0.002), (0, y, mz - 0.004), (0.0243, y, mz + 0.002)], 0.004, INKR, parent=cj, name='inkMouth')
    K.export('AuditionRolodex', OUT, face='+Z')


# =============================================================== THE FLASHCUBE (the nervous one)
def flashcube():
    K.reset()
    SILVER = K.mat('flashSilver', (0.80, 0.80, 0.82), metal=1, rough=0.25)
    LEATHER = K.mat('flashLeather', (0.05, 0.05, 0.05), rough=0.7)
    PLASTIC = K.mat('flashPlastic', (0.12, 0.12, 0.13), rough=0.35)
    BLUE = K.mat('flashBlistGlass', (0.55, 0.75, 0.95), rough=0.05, coat=1)
    REFL = K.mat('flashReflector', (0.92, 0.92, 0.95), metal=1, rough=0.08)
    LENS = K.mat('flashLensDark', (0.05, 0.06, 0.09), rough=0.03, coat=1)
    root = K.joint('hwFlashcube'); body = K.joint('flashBody', (0, 0, 0), root)
    # the Instamatic: black body, silver top, the lens (its mouth) in front
    K.box((0, 0, 0.055), (0.30, 0.10, 0.09), LEATHER, bevel=0.012, parent=body, name='cameraBody')
    K.box((0, 0, 0.11), (0.30, 0.10, 0.025), SILVER, bevel=0.008, parent=body, name='cameraTop')
    K.box((-0.1, -0.051, 0.08), (0.05, 0.004, 0.03), LENS, bevel=0.003, parent=body, name='viewfinder')
    K.cyl((0.1, 0, 0.128), 0.012, 0.012, SILVER, parent=body, name='shutterButton')
    K.cyl((0, -0.055, 0.058), 0.04, 0.016, SILVER, rot=(math.pi / 2, 0, 0), verts=40, parent=body, name='lensRing')
    K.cyl((0, -0.062, 0.058), 0.031, 0.006, PLASTIC, rot=(math.pi / 2, 0, 0), verts=40, parent=body, name='lensBezel')
    m = K.joint('flashMouth', (0, -0.066, 0.058), body)
    K.cyl((0, -0.066, 0.058), 0.024, 0.003, LENS, rot=(math.pi / 2, 0, 0), verts=40, parent=m, name='lensGlass')
    K.cyl((0, 0, 0.13), 0.03, 0.02, PLASTIC, parent=body, name='socket')
    # the cube: turns (in quarter turns) on its socket
    head = K.joint('flashHead', (0, 0, 0.14), body)
    S = 0.16
    cz = 0.14 + S / 2 + 0.008
    K.box((0, 0, 0.145), (0.06, 0.06, 0.012), PLASTIC, bevel=0.003, parent=head, name='plug')
    K.box((0, 0, cz), (S - 0.02, S - 0.02, S), PLASTIC, bevel=0.01, parent=head, name='core')
    for k in range(4):
        a = k * math.pi / 2
        d = Vector((math.sin(a), -math.cos(a), 0))          # side 0 faces -Y (front)
        t = Vector((math.cos(a), math.sin(a), 0))
        c = Vector((0, 0, cz)) + d * (S / 2 - 0.012)
        # reflector dish (the eye's white) and the bulb (the pupil)
        K.lathe(f'refl{k}', [(0.0, 0.012, 0.012), (0.012, 0.035, 0.035), (0.02, 0.058, 0.058)], REFL,
                center=(0, 0, 0), parent=None, nu=40)
        r = bpy.data.objects[f'refl{k}']
        r.rotation_euler = rot_to(d); r.location = c - d * 0.012
        K.own(r, head)
        ej = K.joint(f'flashEye{k}', c, head)
        pj = K.joint(f'flashPupil{k}', c, ej)
        bulb = K.mat(f'flashBulb{k}', (0.85, 0.92, 1.0), rough=0.08)
        K.sphere(c + d * 0.002, 0.021, bulb, seg=20, ring=12, parent=pj, name=f'bulb{k}')
        K.sphere(c + d * 0.02, 0.0075, PLASTIC, seg=12, ring=8, parent=pj, name=f'bulbDot{k}')  # the pupil spot
        # the lid: a plastic shutter inside the blister
        lj = K.joint(f'flashLid{k}', c, head)
        cap = lid_cap(f'flashLidCap{k}', c, 0.05, PLASTIC, lj, back=0.25)
        cap.rotation_euler = (0, 0, a)
        # the blister (clear blue-ish) over it all
        bl = K.box(c + d * 0.012, (0.15, 0.03, 0.15), BLUE, bevel=0.012)
        bl.rotation_euler = (0, 0, a)
        K.own(bl, head, f'blister{k}')
    K.box((0, 0, cz + S / 2 + 0.004), (S - 0.01, S - 0.01, 0.01), PLASTIC, bevel=0.004, parent=head, name='lidTop')
    K.export('AuditionFlashcube', OUT, face='+Z')


# =============================================================== THE TELEVISION (the star)
def television():
    K.reset()
    WALNUT = K.mat('tvWalnut', (0.28, 0.15, 0.08), rough=0.35, coat=0.6)
    BEZEL = K.mat('tvBezel', (0.82, 0.74, 0.55), metal=0.5, rough=0.3)
    SCREEN = K.mat('tvScreenFace', (0.10, 0.12, 0.11), rough=0.06, coat=1)
    GLOW = K.mat('tvGlow', (0.92, 0.95, 0.92), rough=0.5)
    PUP = K.mat('tvPupilDark', (0.06, 0.07, 0.07), rough=0.5)
    CLOTH = K.mat('tvCloth', (0.62, 0.52, 0.36), rough=0.95)
    BRASS = K.mat('tvBrass', (0.80, 0.62, 0.30), metal=1, rough=0.25)
    CHROME = K.mat('tvChrome', (0.85, 0.86, 0.88), metal=1, rough=0.12)
    KNOB = K.mat('tvKnob', (0.06, 0.05, 0.05), rough=0.3, coat=0.6)
    root = K.joint('hwTelevision'); body = K.joint('tvBody', (0, 0, 0), root)
    for sx in (-1, 1):
        for sy in (-1, 1):
            K.rod((sx * 0.15, sy * 0.1, 0.12), (sx * 0.19, sy * 0.13, 0.0), 0.012, WALNUT, parent=body, name='leg', r1=0.006)
            K.sphere((sx * 0.19, sy * 0.13, 0.004), 0.009, BRASS, parent=body, name='ferrule')
    head = K.joint('tvHead', (0, 0, 0.12), body)              # the cabinet turns a little to look
    K.box((0, 0.01, 0.30), (0.42, 0.30, 0.34), WALNUT, bevel=0.03, parent=head, name='cabinet')
    # screen: bezel, curved glass
    rounded_slab('bezel', 0.30, 0.235, 0.012, 0.045, BEZEL, parent=head).location = (-0.04, -0.142, 0.325)
    bpy.data.objects['bezel'].name = 'bezel'
    glass = rounded_slab('screenGlass', 0.27, 0.205, 0.012, 0.04, SCREEN, parent=head)
    glass.location = (-0.04, -0.146, 0.325)
    # the bulge of the tube
    K.sphere((-0.04, -0.06, 0.325), 0.16, SCREEN, scale=(0.84, 0.55, 0.64), seg=40, ring=24, parent=head, name='tubeBulge') if False else None
    # the face, glowing on the screen
    FZ = -0.154
    for s in (1, -1):
        S = 'L' if s > 0 else 'R'
        c = Vector((-0.04 + s * 0.05, FZ, 0.345))
        ej = K.joint(f'tvEye{S}', c, head)
        K.sphere(c, 0.026, GLOW, scale=(1, 0.12, 1.25), seg=24, ring=12, parent=ej, name=f'tvEyeGlow{S}')
        pj = K.joint(f'tvPupil{S}', c, ej)
        K.sphere(c + Vector((0, -0.0035, -0.004)), 0.012, PUP, scale=(1, 0.12, 1.15), seg=16, ring=8, parent=pj, name=f'tvPupilDot{S}')
    m = K.joint('tvMouth', (-0.04, FZ, 0.28), head)
    K.sphere((-0.04, FZ, 0.28), 0.03, GLOW, scale=(1, 0.12, 0.12), seg=24, ring=12, parent=m, name='tvMouthGlow')
    # knobs and the speaker cloth at the side
    for k, z in enumerate((0.385, 0.29)):
        kj = K.joint(f'tvKnob{k}', (0.155, -0.142, z), head)
        K.cyl((0.155, -0.15, z), 0.022, 0.02, KNOB, rot=(math.pi / 2, 0, 0), verts=24, parent=kj, name='knob')
        K.box((0.155, -0.161, z + 0.012), (0.004, 0.004, 0.012), CHROME, bevel=0, parent=kj, name='knobMark')
    K.box((0.155, -0.141, 0.205), (0.07, 0.006, 0.07), CLOTH, bevel=0.004, parent=head, name='speakerCloth')
    for k in range(4):
        K.box((0.155, -0.146, 0.18 + k * 0.016), (0.07, 0.004, 0.004), BRASS, bevel=0, parent=head, name='slat')
    K.box((0, -0.141, 0.155), (0.4, 0.006, 0.012), BRASS, bevel=0.002, parent=head, name='trim')
    # the rabbit ears: its brows (and arms)
    K.sphere((0, 0.03, 0.47), 0.045, KNOB, scale=(1, 1, 0.6), parent=head, name='antennaBase')
    for s in (1, -1):
        S = 'L' if s > 0 else 'R'
        aj = K.joint(f'tvAnt{S}', (s * 0.012, 0.03, 0.49), head)
        tip = Vector((s * 0.17, 0.03, 0.80))
        base = Vector((s * 0.012, 0.03, 0.49))
        for k, (r0, r1) in enumerate(((0.006, 0.005), (0.0045, 0.0038), (0.0032, 0.0028))):
            a = base + (tip - base) * (k / 3)
            b = base + (tip - base) * ((k + 1) / 3 + 0.03)
            K.rod(a, b, r0, CHROME, parent=aj, name='antSeg', r1=r1)
        K.sphere(tip, 0.009, CHROME, parent=aj, name='antTip')
    K.export('AuditionTelevision', OUT, face='+Z')


for name, fn in (('telephone', telephone), ('viewmaster', viewmaster), ('rolodex', rolodex),
                 ('flashcube', flashcube), ('television', television)):
    if ONLY is None or name in ONLY:
        fn()
