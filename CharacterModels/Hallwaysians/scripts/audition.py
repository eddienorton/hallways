# AUDITION CAST -- five new Hallwaysians for the Floor 3 conference-room
# audition (Oct 11). Built with hallwaysian_kit, same export contract as
# Juanita / Mr. Tinky. All face +Z in SceneKit (Blender -Y). Origin = the
# bottom of the character (it sits on a chair seat there).
#
# Face rig (every character, prefix p, S = L/R by the CHARACTER's own side):
#   pHead > pEyeS > pPupilS   (pupil joint at the eye centre: rotate to look)
#   pHead > pLidS             (upper lid cap, joint at eye centre: +x closes)
#   pHead > pBrowS            (rotate z to tilt, move y to raise)
#   pMouth                    (hinge: rotate x; or scale: open by scaling y)
import sys, os, math
import bpy, bmesh
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hallwaysian_kit as K
from mathutils import Vector, Matrix

OUT = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else "."
ONLY = sys.argv[sys.argv.index('--only') + 1].split(',') if '--only' in sys.argv else None

def rot_to(d):
    return Vector(d).normalized().to_track_quat('Z', 'Y').to_euler()

def facets(name, verts, faces, m, parent=None, flat=True):
    me = bpy.data.meshes.new(name + 'Mesh'); me.from_pydata([tuple(v) for v in verts], [], faces); me.update()
    o = bpy.data.objects.new(name, me); bpy.context.scene.collection.objects.link(o)
    o.data.materials.append(m)
    if not flat:
        for p in o.data.polygons: p.use_smooth = True
    sol = o.modifiers.new('s', 'SOLIDIFY'); sol.thickness = 0.003; sol.offset = 0
    return K.own(o, parent)

def lid_cap(name, center, r, m, parent, back=0.55, half=math.radians(72)):
    bm = bmesh.new(); bmesh.ops.create_uvsphere(bm, u_segments=28, v_segments=18, radius=r * 1.1)
    axis = Vector((0, math.sin(back), math.cos(back)))
    kill = [v for v in bm.verts if v.co.normalized().dot(axis) < math.cos(half)]
    bmesh.ops.delete(bm, geom=kill, context='VERTS')
    me = bpy.data.meshes.new(name + 'Mesh'); bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new(name, me); bpy.context.scene.collection.objects.link(o); o.location = center
    o.data.materials.append(m)
    for p in o.data.polygons: p.use_smooth = True
    sol = o.modifiers.new('s', 'SOLIDIFY'); sol.thickness = r * 0.09
    return K.own(o, parent)

def WHITE(): return K.mat('hwEyeWhite', (0.93, 0.92, 0.88), rough=0.15)
def PUPIL(): return K.mat('hwPupil', (0.01, 0.01, 0.012), rough=0.06, coat=1)
def GLINT(): return K.mat('hwGlint', (1, 1, 1), rough=0.05)

def face_eye(p, side, center, r, lid_m, head, look=(0, -1, 0), pupil=0.5, white=None, lid=True, back=0.55):
    S = 'L' if side > 0 else 'R'
    c = Vector(center); L = Vector(look).normalized()
    eye = K.joint(f'{p}Eye{S}', c, head)
    K.sphere(c, r, white or WHITE(), seg=28, ring=16, parent=eye, name=f'{p}Ball{S}')
    pj = K.joint(f'{p}Pupil{S}', c, eye)
    K.sphere(c + L * (r * 0.8), r * pupil, PUPIL(), seg=20, ring=12, parent=pj, name=f'{p}PupilDot{S}')
    up = Vector((0, 0, 1)); side_v = L.cross(up).normalized()
    K.sphere(c + L * (r * 0.97) + up * (r * 0.28) - side_v * (r * 0.2), r * 0.12, GLINT(), seg=10, ring=6, parent=pj, name=f'{p}Glint{S}')
    if lid:
        lj = K.joint(f'{p}Lid{S}', c, head)
        lid_cap(f'{p}LidCap{S}', c, r, lid_m, lj, back=back)
    return eye

def brow(p, side, center, length, thick, m, head, tilt=0.0, yaw=0.0, curve=0.0):
    S = 'L' if side > 0 else 'R'
    j = K.joint(f'{p}Brow{S}', center, head)
    c = Vector(center); n = 7; pts = []
    for i in range(n):
        t = i / (n - 1) - 0.5
        x = t * length
        z = -curve * (2 * t) ** 2 + t * length * math.tan(tilt) * side
        pts.append(Vector((x * math.cos(yaw), x * math.sin(yaw), z)) + c)
    K.tube([tuple(q) for q in pts], thick, m, parent=j, name=f'{p}BrowBar{S}')
    return j

# =============================================================== THE COMMODORE
def commodore():
    K.reset()
    COPPER = K.mat('commCopper', (0.70, 0.40, 0.22), metal=1, rough=0.30)
    BRASS = K.mat('commBrass', (0.80, 0.60, 0.28), metal=1, rough=0.25)
    PATINA = K.mat('commPatina', (0.33, 0.60, 0.52), rough=0.7)
    GLASS = K.mat('commPortGlass', (0.10, 0.14, 0.16), rough=0.04, coat=1)
    DARK = K.mat('commDark', (0.015, 0.012, 0.01), rough=0.9)
    HOSE = K.mat('commHose', (0.12, 0.11, 0.10), rough=0.75)
    root = K.joint('hwCommodore'); body = K.joint('commBody', (0, 0, 0), root)
    # the corselet (breastplate) he sits on
    K.lathe('corselet', [(0.0, 0.225, 0.19), (0.05, 0.222, 0.188), (0.12, 0.19, 0.165), (0.17, 0.15, 0.15)], COPPER,
            parent=body, cap_bottom=True, nu=40)
    for k in range(8):
        a = 2 * math.pi * (k + 0.5) / 8
        K.sphere((0.218 * math.cos(a), 0.186 * math.sin(a), 0.03), 0.012, BRASS, parent=body, name=f'wingNut{k}')
    K.torus((0, 0, 0.012), 0.21, 0.013, BRASS, parent=body, name='corseletRim')
    K.torus((0, 0, 0.172), 0.148, 0.016, BRASS, parent=body, name='neckRing')
    # the helmet: his head (turns on the neck ring)
    head = K.joint('commHead', (0, 0, 0.18), body)
    C = Vector((0, 0, 0.385)); R = 0.215
    K.sphere(C, R, COPPER, scale=(1, 1, 1.04), seg=40, ring=24, parent=head, name='helmet')
    for (u, v, s) in ((0.6, 0.3, 0.035), (-0.4, 0.8, 0.028), (0.2, -0.5, 0.03), (-0.75, 0.1, 0.022)):
        d = Vector((math.sin(u) * math.cos(v), math.cos(u) * math.cos(v), math.sin(v)))
        K.sphere(C + d * R * 0.995, s, PATINA, scale=(1, 1, 0.35), parent=head, name='patina')
    # crown valve
    K.cyl(C + Vector((0, 0.02, R + 0.01)), 0.03, 0.03, BRASS, parent=head, name='valve')
    K.sphere(C + Vector((0, 0.02, R + 0.035)), 0.02, BRASS, parent=head, name='valveKnob')
    # air hose at the back, looping down to the shoulder
    hp = [C + Vector((0, R * 0.92, -0.02)), C + Vector((0, R + 0.09, -0.06)), C + Vector((0.02, R + 0.12, -0.17)),
          C + Vector((0.05, R + 0.06, -0.29)), Vector((0.08, 0.17, 0.08))]
    K.tube([tuple(q) for q in hp], 0.022, HOSE, parent=head, name='airHose')
    K.cyl(C + Vector((0, R * 0.95, -0.02)), 0.032, 0.04, BRASS, rot=(math.pi / 2, 0, 0), parent=head, name='hoseFitting')
    # the MOUTH: the round front faceplate, hinged at its top (it swings open)
    fc = C + Vector((0, -R * 0.93, -0.06))
    mouth = K.joint('commMouth', fc + Vector((0, -0.01, 0.085)), head)
    K.cyl(fc + Vector((0, 0.012, 0)), 0.078, 0.01, DARK, rot=(math.pi / 2, 0, 0), parent=head, name='mouthDark')
    K.torus(fc, 0.085, 0.014, BRASS, rot=(math.pi / 2, 0, 0), parent=mouth, name='faceRing')
    K.cyl(fc, 0.078, 0.008, GLASS, rot=(math.pi / 2, 0, 0), parent=mouth, name='faceGlass')
    for x in (-0.042, 0, 0.042):     # the grille: his teeth
        K.rod(fc + Vector((x, -0.012, -0.072)), fc + Vector((x, -0.012, 0.072)), 0.0065, BRASS, parent=mouth, name='grilleBar')
    K.sphere(fc + Vector((0, -0.01, 0.088)), 0.016, BRASS, parent=mouth, name='hingeKnuckle')
    # EYES: the two upper portholes; brass shutter lids; riveted strap brows
    for s in (1, -1):
        a, e = math.radians(33), math.radians(26)
        d = Vector((s * math.sin(a) * math.cos(e), -math.cos(a) * math.cos(e), math.sin(e)))
        ec = C + d * (R * 0.93)
        look = (d * 0.25 + Vector((0, -1, 0)) * 0.75).normalized()
        face_eye('comm', s, ec, 0.052, BRASS, head, look=look, pupil=0.48)
        K.torus(ec - d * 0.004, 0.058, 0.0095, BRASS, rot=rot_to(d), parent=head, name='portRing')
        bc = ec + Vector((0, 0.012, 0.072))
        b = brow('comm', s, bc, 0.10, 0.0085, BRASS, head, tilt=0.0, yaw=-s * a, curve=0.008)
        for t in (-0.035, 0.035):
            K.sphere(bc + Vector((t * math.cos(-s * a), t * math.sin(-s * a), 0.006 - 0.008 * (2 * t / 0.1) ** 2)), 0.0065, COPPER,
                     parent=b, name='browRivet')
    K.export('AuditionCommodore', OUT, face='+Z')

# =============================================================== THE CLOCHE (a cloud in a bell jar)
def cloche():
    K.reset()
    WALNUT = K.mat('clocheWalnut', (0.25, 0.13, 0.06), rough=0.3, coat=0.6)
    BRASS = K.mat('clocheBrass', (0.80, 0.60, 0.28), metal=1, rough=0.25)
    GLASS = K.mat('clocheGlass', (0.86, 0.93, 0.96), rough=0.03)
    CLOUD = K.mat('clocheCloud', (0.97, 0.97, 1.0), rough=0.95)
    INK = K.mat('clocheInk', (0.22, 0.24, 0.30), rough=0.6)
    MOUTH = K.mat('clocheMouthDark', (0.20, 0.10, 0.14), rough=0.6)
    root = K.joint('hwCloche'); body = K.joint('clocheBody', (0, 0, 0), root)
    K.cyl((0, 0, 0.025), 0.175, 0.05, WALNUT, verts=48, parent=body, name='plinth', bevel=0.006)
    K.torus((0, 0, 0.05), 0.158, 0.006, BRASS, parent=body, name='plinthRing')
    K.lathe('jar', [(0.05, 0.155, 0.155), (0.30, 0.152, 0.152), (0.40, 0.125, 0.125), (0.45, 0.07, 0.07), (0.468, 0.0, 0.0)],
            GLASS, parent=body, nu=48)
    K.sphere((0, 0, 0.48), 0.022, GLASS, parent=body, name='jarKnob')
    cloud = K.joint('clocheHead', (0, 0, 0.23), body)   # the cloud is its head: it floats
    for (x, y, z, r, sx) in ((0, 0, 0.23, 0.082, 1.3), (-0.07, 0.01, 0.255, 0.058, 1), (0.07, 0.01, 0.26, 0.06, 1),
                             (0.0, 0.03, 0.30, 0.062, 1.1), (-0.095, 0.02, 0.215, 0.042, 1), (0.098, 0.02, 0.215, 0.044, 1),
                             (0.035, -0.01, 0.19, 0.05, 1.2), (-0.04, 0.0, 0.19, 0.048, 1.1)):
        K.sphere((x, y, z), r, CLOUD, scale=(sx, 0.85, 0.9), seg=24, ring=14, parent=cloud, name='puff')
    for s in (1, -1):
        face_eye('cloche', s, (s * 0.036, -0.074, 0.245), 0.022, CLOUD, cloud, look=(s * 0.1, -1, 0.0), pupil=0.55, back=0.45)
        brow('cloche', s, (s * 0.04, -0.077, 0.284), 0.032, 0.0035, INK, cloud, tilt=0.0, curve=0.004)
    m = K.joint('clocheMouth', (0, -0.088, 0.205), cloud)
    K.sphere((0, -0.088, 0.205), 0.016, MOUTH, scale=(1.5, 0.45, 0.6), seg=20, ring=10, parent=m, name='mouthO')
    K.export('AuditionCloche', OUT, face='+Z')

# =============================================================== ASPIC (a ruby jelly on a cake stand)
def aspic():
    K.reset()
    STAND = K.mat('aspicStandGlass', (0.82, 0.90, 0.92), rough=0.04)
    JELLY = K.mat('aspicJelly', (0.72, 0.05, 0.10), rough=0.06, coat=1)
    PEAR = K.mat('aspicPear', (0.97, 0.94, 0.80), rough=0.2, coat=0.6)
    PEEL = K.mat('aspicPeel', (0.95, 0.55, 0.10), rough=0.5)
    CHERRY = K.mat('aspicCherry', (0.55, 0.02, 0.05), rough=0.1, coat=1)
    STEM = K.mat('aspicStem', (0.30, 0.45, 0.12), rough=0.6)
    MINT = K.mat('aspicMint', (0.20, 0.55, 0.22), rough=0.5)
    MOUTH = K.mat('aspicMouthDark', (0.25, 0.01, 0.03), rough=0.3)
    root = K.joint('hwAspic'); body = K.joint('aspicBody', (0, 0, 0), root)
    K.cyl((0, 0, 0.006), 0.09, 0.012, STAND, verts=40, parent=body, name='foot')
    K.cone((0, 0, 0.09), 0.03, 0.018, 0.16, STAND, parent=body, name='stem')
    K.cyl((0, 0, 0.176), 0.175, 0.012, STAND, verts=48, parent=body, name='plate')
    K.torus((0, 0, 0.182), 0.172, 0.006, STAND, parent=body, name='plateRim')
    jelly = K.joint('aspicHead', (0, 0, 0.182), body)     # the whole jelly is the head (it wobbles)
    K.lathe('jelly', [(0.0, 0.15, 0.15), (0.05, 0.148, 0.148), (0.12, 0.125, 0.125), (0.18, 0.09, 0.09), (0.21, 0.05, 0.05), (0.218, 0.0, 0.0)],
            JELLY, center=(0, 0, 0.182), parent=jelly, nu=60, wobble=lambda lon, z: 1 + 0.055 * math.cos(10 * lon))
    # cherry on top, a mint leaf
    K.sphere((0, 0, 0.415), 0.03, CHERRY, parent=jelly, name='cherry')
    K.tube([(0, 0, 0.44), (0.01, 0.005, 0.47), (0.03, 0.01, 0.49)], 0.003, STEM, parent=jelly, name='cherryStem')
    for a in (0.6, 2.4):
        K.sphere((0.035 * math.cos(a), 0.035 * math.sin(a), 0.405), 0.03, MINT, scale=(1, 0.45, 0.12), parent=jelly, name='mintLeaf')
    # pear-half eyes set in the jelly's front, peel brows, a little slot of a mouth
    for s in (1, -1):
        face_eye('aspic', s, (s * 0.045, -0.118, 0.29), 0.03, JELLY, jelly, look=(s * 0.08, -1, 0.05), pupil=0.5, white=PEAR, back=0.5)
        brow('aspic', s, (s * 0.05, -0.098, 0.338), 0.045, 0.0045, PEEL, jelly, tilt=0.0, curve=0.006)
    m = K.joint('aspicMouth', (0, -0.142, 0.235), jelly)
    K.sphere((0, -0.142, 0.235), 0.02, MOUTH, scale=(1.7, 0.5, 0.55), seg=20, ring=10, parent=m, name='mouthSlot')
    K.export('AuditionAspic', OUT, face='+Z')

# =============================================================== THE CRANE (folded paper)
def crane():
    K.reset()
    PAPER = K.mat('cranePaper', (0.95, 0.93, 0.86), rough=0.85)
    BLUE = K.mat('cranePaperBlue', (0.36, 0.52, 0.78), rough=0.8)
    INK = K.mat('craneInk', (0.03, 0.03, 0.04), rough=0.5)
    BEAK = K.mat('cranePaperRed', (0.82, 0.22, 0.16), rough=0.8)
    root = K.joint('hwCrane'); body = K.joint('craneBody', (0, 0, 0), root)
    # the body: a folded kite, sitting
    F, Bk, Lf, Rt, T, D = (0, -0.11, 0.12), (0, 0.13, 0.13), (-0.075, 0.01, 0.10), (0.075, 0.01, 0.10), (0, 0.0, 0.22), (0, 0.01, 0.0)
    facets('craneTorso', [F, Bk, Lf, Rt, T, D], [(0, 2, 4), (0, 4, 3), (1, 4, 2), (1, 3, 4), (0, 5, 2), (0, 3, 5), (1, 2, 5), (1, 5, 3)], PAPER, body)
    # the tail: a slim upturned point
    facets('craneTail', [(0, 0.10, 0.12), (-0.012, 0.12, 0.15), (0.012, 0.12, 0.15), (0, 0.26, 0.40)],
           [(0, 1, 3), (0, 3, 2), (1, 2, 3)], PAPER, body)
    # wings (blue on top, as origami paper is): joints at the shoulders
    for s in (1, -1):
        S = 'L' if s > 0 else 'R'
        w = K.joint(f'craneWing{S}', (s * 0.05, 0.01, 0.17), body)
        wv = [(s * 0.04, -0.05, 0.15), (s * 0.04, 0.09, 0.17), (s * 0.21, 0.05, 0.22), (s * 0.33, 0.03, 0.44), (s * 0.14, -0.01, 0.36)]
        facets(f'craneWingTop{S}', wv, [(0, 1, 2), (0, 2, 3), (0, 3, 4)] if s > 0 else [(0, 2, 1), (0, 3, 2), (0, 4, 3)], BLUE, w)
        wu = [(x, y + 0.004, z - 0.006) for (x, y, z) in wv]
        facets(f'craneWingUnder{S}', wu, [(0, 2, 1), (0, 3, 2), (0, 4, 3)] if s > 0 else [(0, 1, 2), (0, 2, 3), (0, 3, 4)], PAPER, w)
    # neck (a slim folded point) and the head
    neck = K.joint('craneNeck', (0, -0.09, 0.15), body)
    facets('craneNeckFold', [(0, -0.07, 0.12), (-0.024, -0.10, 0.17), (0.024, -0.10, 0.17), (0, -0.17, 0.46)],
           [(0, 1, 3), (0, 3, 2), (1, 2, 3)], PAPER, neck)
    head = K.joint('craneHead', (0, -0.17, 0.46), neck)
    hc = Vector((0, -0.19, 0.48))
    # a folded paper head: an octahedron, wider than a real crane's (it has a face)
    hv = [hc + Vector(v) for v in ((0, 0.05, 0), (0, -0.065, 0), (-0.062, 0, 0), (0.062, 0, 0), (0, 0, 0.065), (0, 0, -0.05))]
    facets('craneHeadFold', hv, [(1, 3, 4), (1, 4, 2), (0, 4, 3), (0, 2, 4), (1, 5, 3), (1, 2, 5), (0, 3, 5), (0, 5, 2)], PAPER, head)
    # beak: upper fixed, lower hinged (the mouth)
    br = hc + Vector((0, -0.06, -0.012))
    facets('craneBeakUpper', [br + Vector((-0.012, 0, 0.008)), br + Vector((0.012, 0, 0.008)), br + Vector((0, -0.075, -0.004)), br + Vector((0, 0, -0.003))],
           [(0, 2, 1), (0, 3, 2), (1, 2, 3)], BEAK, head)
    mouth = K.joint('craneMouth', br + Vector((0, 0, -0.004)), head)
    facets('craneBeakLower', [br + Vector((-0.009, 0, -0.006)), br + Vector((0.009, 0, -0.006)), br + Vector((0, -0.06, -0.012))],
           [(0, 2, 1), (0, 1, 2)], BEAK, mouth)
    for s in (1, -1):
        face_eye('crane', s, hc + Vector((s * 0.03, -0.042, 0.014)), 0.021, PAPER, head, look=(s * 0.2, -1, 0.05), pupil=0.52, back=0.5)
        brow('crane', s, hc + Vector((s * 0.032, -0.042, 0.048)), 0.034, 0.0032, INK, head, tilt=0.0, yaw=s * -0.15, curve=0.0)
    K.export('AuditionCrane', OUT, face='+Z')

# =============================================================== THE PROSCENIUM (a toy theatre that looks back)
def proscenium():
    K.reset()
    GILT = K.mat('procGilt', (0.85, 0.66, 0.30), metal=1, rough=0.3)
    WOOD = K.mat('procWood', (0.20, 0.09, 0.05), rough=0.35, coat=0.5)
    VELVET = K.mat('procVelvet', (0.55, 0.04, 0.07), rough=0.85)
    NIGHT = K.mat('procNight', (0.05, 0.08, 0.20), rough=0.7)
    STAR = K.mat('procStar', (1.0, 0.92, 0.6), rough=0.3)
    BULB = K.mat('procBulb', (1.0, 0.86, 0.5), rough=0.2)
    MOUTH = K.mat('procMouthDark', (0.02, 0.01, 0.02), rough=0.8)
    root = K.joint('hwProscenium'); body = K.joint('procBody', (0, 0, 0), root)
    K.box((0, 0.0, 0.03), (0.42, 0.25, 0.06), WOOD, parent=body, name='plinth', bevel=0.006)
    K.box((0, -0.128, 0.055), (0.40, 0.012, 0.02), GILT, parent=body, name='plinthTrim')
    K.box((0, 0.01, 0.065), (0.32, 0.20, 0.01), WOOD, parent=body, name='stageFloor')
    K.box((0, 0.10, 0.25), (0.32, 0.02, 0.36), NIGHT, parent=body, name='backdrop')
    for (x, z) in ((-0.11, 0.38), (0.12, 0.35), (-0.05, 0.40), (0.07, 0.41), (0.13, 0.20), (-0.13, 0.15)):
        K.sphere((x, 0.088, z), 0.005, STAR, parent=body, name='star')
    for s in (1, -1):
        K.box((s * 0.15, 0.0, 0.25), (0.02, 0.20, 0.38), WOOD, parent=body, name='wing')
        K.box((s * 0.18, -0.085, 0.25), (0.05, 0.05, 0.40), GILT, parent=body, name='pillar', bevel=0.008)
        K.sphere((s * 0.18, -0.085, 0.06), 0.03, GILT, parent=body, name='pillarFoot')
    K.box((0, -0.085, 0.465), (0.42, 0.06, 0.07), GILT, parent=body, name='header', bevel=0.008)
    K.sphere((0, -0.085, 0.52), 0.085, GILT, scale=(1.2, 0.25, 0.7), parent=body, name='crest')
    K.sphere((0, -0.11, 0.53), 0.022, STAR, parent=body, name='crestStar')
    for k in range(7):
        x = -0.135 + k * 0.045
        K.sphere((x, -0.07, 0.415), 0.024, VELVET, scale=(1, 0.6, 0.8), parent=body, name='valance')
        K.sphere((x, -0.08, 0.392), 0.006, GILT, parent=body, name='tassel')
    for k in range(6):
        K.sphere((-0.11 + k * 0.044, -0.115, 0.077), 0.009, BULB, parent=body, name='footlight')
    head = K.joint('procHead', (0, 0, 0.25), body)     # the face inside the stage (it can lean out)
    for s in (1, -1):
        face_eye('proc', s, (s * 0.058, 0.0, 0.29), 0.042, NIGHT, head, look=(s * 0.05, -1, 0), pupil=0.5, lid=False)
        brow('proc', s, (s * 0.06, -0.02, 0.348), 0.06, 0.006, VELVET, head, tilt=0.0, curve=0.01)
    m = K.joint('procMouth', (0, -0.02, 0.17), head)
    K.sphere((0, -0.02, 0.17), 0.03, MOUTH, scale=(1.8, 0.4, 0.6), seg=24, ring=12, parent=m, name='mouthO')
    # the curtains: its eyelids (slide toward the centre to close)
    for s in (1, -1):
        S = 'L' if s > 0 else 'R'
        c = K.joint(f'procCurtain{S}', (s * 0.115, -0.065, 0.24), body)
        for k in range(4):
            x = s * (0.135 - k * 0.022)
            K.cyl((x, -0.065 + (k % 2) * 0.006, 0.24), 0.013, 0.33, VELVET, verts=12, parent=c, name='pleat')
        K.torus((s * 0.105, -0.07, 0.17), 0.04, 0.004, GILT, rot=(0, math.pi / 2, 0), parent=c, name='tieback')
    K.export('AuditionProscenium', OUT, face='+Z')

if __name__ == '__main__':
  for name, fn in (('commodore', commodore), ('cloche', cloche), ('aspic', aspic), ('crane', crane), ('proscenium', proscenium)):
    if ONLY is None or name in ONLY:
        fn()
