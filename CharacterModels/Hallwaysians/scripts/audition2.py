# AUDITION, ROUND TWO -- five new Hallwaysians with mass and readable faces,
# for the Floor 3 conference-room audition (Oct 11, late). Same kit, same
# export contract and face rig as audition.py (round one):
#   pHead > pEyeS > pPupilS, pHead > pLidS (+x closes), pHead > pBrowS, pMouth.
# All face +Z in SceneKit (Blender -Y); origin = the bottom of the character.
import sys, os, math
import bpy, bmesh
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hallwaysian_kit as K
from mathutils import Vector
from audition import face_eye, brow, rot_to, facets, lid_cap  # shared rig helpers (round one)

OUT = sys.argv[sys.argv.index('--out') + 1]
ONLY = sys.argv[sys.argv.index('--only') + 1].split(',') if '--only' in sys.argv else None

def chain(p0, p1, n, r, m, parent, name='link'):
    p0, p1 = Vector(p0), Vector(p1)
    for i in range(n):
        c = p0 + (p1 - p0) * ((i + 0.5) / n) + Vector((0, 0, -0.012 * math.sin(math.pi * (i + 0.5) / n)))
        K.torus(c, r, r * 0.28, m, rot=(0, (math.pi / 2) * (i % 2), 0) if True else (0, 0, 0), maj=12, mino=6, parent=parent, name=name)

# =============================================================== THE SAFE (the leader)
def safe():
    K.reset()
    GREEN = K.mat('safeEnamel', (0.07, 0.15, 0.11), rough=0.22, coat=0.8)
    PANEL = K.mat('safePanel', (0.09, 0.19, 0.14), rough=0.25, coat=0.8)
    GOLD = K.mat('safeGold', (0.86, 0.66, 0.28), metal=1, rough=0.25)
    IRON = K.mat('safeIron', (0.10, 0.10, 0.11), metal=0.6, rough=0.4)
    SLOT = K.mat('safeSlotDark', (0.01, 0.01, 0.01), rough=0.9)
    root = K.joint('hwSafe'); body = K.joint('safeBody', (0, 0, 0), root)
    for sx in (-1, 1):
        for sy in (-1, 1):
            c = Vector((sx * 0.17, sy * 0.13, 0.035))
            K.sphere(c, 0.034, GOLD, scale=(1, 1, 0.9), parent=body, name='paw')
            for t in (-1, 0, 1):
                K.sphere(c + Vector((t * 0.018, -0.03, -0.012)), 0.013, GOLD, parent=body, name='toe')
    head = K.joint('safeHead', (0, 0, 0.065), body)     # the whole iron box turns, deliberately
    K.box((0, 0, 0.27), (0.44, 0.36, 0.40), GREEN, bevel=0.022, parent=head, name='box')
    K.box((0, 0, 0.485), (0.47, 0.39, 0.03), GREEN, bevel=0.01, parent=head, name='cornice')
    K.box((0, 0, 0.472), (0.475, 0.395, 0.008), GOLD, bevel=0.002, parent=head, name='corniceTrim')
    K.box((0, 0, 0.08), (0.46, 0.38, 0.03), GREEN, bevel=0.01, parent=head, name='plinth')
    K.box((0, -0.181, 0.275), (0.38, 0.012, 0.33), PANEL, bevel=0.006, parent=head, name='door')
    # gold pinstripe on the door
    y = -0.188
    pts = [(-0.175, y, 0.12), (0.175, y, 0.12), (0.175, y, 0.43), (-0.175, y, 0.43), (-0.175, y, 0.12)]
    K.tube(pts, 0.003, GOLD, parent=head, name='pinstripe')
    # THE MONOCLE: its right eye looks out through the combination dial
    dc = Vector((-0.085, -0.19, 0.335))
    dial = K.joint('safeDial', dc, head)
    K.torus(dc, 0.078, 0.012, GOLD, rot=(math.pi / 2, 0, 0), parent=dial, name='dialRing')
    for k in range(20):
        a = 2 * math.pi * k / 20
        K.box(dc + Vector((math.cos(a) * 0.064, -0.004, math.sin(a) * 0.064)), (0.004, 0.004, 0.012 if k % 5 else 0.02),
              GOLD, rot=(0, -a + math.pi / 2, 0), bevel=0, parent=dial, name='tick')
    face_eye('safe', -1, dc + Vector((0, -0.012, 0)), 0.05, GREEN, head, look=(0.05, -1, 0), pupil=0.5)
    face_eye('safe', 1, (0.095, -0.2, 0.335), 0.046, GREEN, head, look=(-0.05, -1, 0), pupil=0.5, back=0.35)
    # the watch chain from the monocle to its moustache
    chain(dc + Vector((-0.05, -0.012, -0.06)), (-0.085, -0.205, 0.165), 7, 0.012, GOLD, head)
    # heavy iron brows, set stern (inner ends down)
    brow('safe', -1, (-0.085, -0.2, 0.432), 0.105, 0.013, IRON, head, tilt=0.22, curve=0.004)
    brow('safe', 1, (0.095, -0.2, 0.418), 0.095, 0.013, IRON, head, tilt=0.22, curve=0.004)
    # the mouth: the deposit slot
    m = K.joint('safeMouth', (0, -0.192, 0.215), head)
    K.box((0, -0.19, 0.215), (0.13, 0.02, 0.022), SLOT, bevel=0.004, parent=m, name='slot')
    K.torus((0, -0.193, 0.215), 0.07, 0.006, GOLD, rot=(math.pi / 2, 0, 0), parent=m, name='slotLip') if False else \
        K.box((0, -0.194, 0.215), (0.15, 0.006, 0.036), GOLD, bevel=0.003, parent=m, name='slotLip')
    K.box((0, -0.197, 0.215), (0.13, 0.006, 0.022), SLOT, bevel=0.002, parent=m, name='slotHole')
    # the moustache: its brass T-handle
    h = K.joint('safeHandle', (0, -0.2, 0.165), head)
    K.cyl((0, -0.205, 0.165), 0.016, 0.03, GOLD, rot=(math.pi / 2, 0, 0), parent=h, name='handleHub')
    K.tube([(-0.09, -0.222, 0.18), (-0.06, -0.222, 0.162), (0, -0.222, 0.165), (0.06, -0.222, 0.162), (0.09, -0.222, 0.18)],
           0.009, GOLD, parent=h, name='handleBar')
    for s in (-1, 1):
        K.sphere((s * 0.095, -0.222, 0.186), 0.013, GOLD, parent=h, name='handleCurl')
    K.box((0.14, -0.19, 0.15), (0.03, 0.006, 0.04), GOLD, bevel=0.002, parent=head, name='keyPlate')
    K.box((0.14, -0.194, 0.15), (0.006, 0.006, 0.016), SLOT, bevel=0, parent=head, name='keyHole')
    K.export('AuditionSafe', OUT, face='+Z')

# =============================================================== THE STOVE (the grouch)
def stove():
    K.reset()
    IRON = K.mat('stoveIron', (0.06, 0.06, 0.065), metal=0.5, rough=0.42)
    NICKEL = K.mat('stoveNickel', (0.78, 0.78, 0.75), metal=1, rough=0.2)
    COALS = K.mat('stoveCoals', (1.0, 0.42, 0.06), rough=0.6)
    DARK = K.mat('stoveDark', (0.02, 0.01, 0.0), rough=0.9)
    RUST = K.mat('stoveRust', (0.42, 0.18, 0.08), rough=0.85)
    root = K.joint('hwStove'); body = K.joint('stoveBody', (0, 0, 0), root)
    for k in range(3):
        a = math.radians(90 + 120 * k)
        x, y = math.cos(a), math.sin(a)
        K.tube([(x * 0.13, y * 0.13, 0.11), (x * 0.18, y * 0.18, 0.06), (x * 0.20, y * 0.20, 0.02)], 0.022, IRON, parent=body, name='leg')
        K.sphere((x * 0.205, y * 0.205, 0.016), 0.026, IRON, scale=(1, 1, 0.6), parent=body, name='foot')
    head = K.joint('stoveHead', (0, 0, 0.1), body)     # the whole belly (it turns a little, it heaves)
    K.cyl((0, 0, 0.105), 0.19, 0.03, IRON, parent=head, name='base', bevel=0.006)
    K.lathe('belly', [(0.12, 0.17, 0.17), (0.20, 0.215, 0.215), (0.32, 0.228, 0.228), (0.44, 0.198, 0.198), (0.50, 0.15, 0.15), (0.535, 0.105, 0.105)],
            IRON, parent=head, cap_bottom=True, nu=48)
    K.torus((0, 0, 0.30), 0.229, 0.008, NICKEL, parent=head, name='band')
    K.cyl((0, 0, 0.545), 0.11, 0.03, NICKEL, parent=head, name='collar', bevel=0.004)
    for (u, v) in ((0.7, 0.36), (-1.1, 0.26), (2.4, 0.4)):
        K.sphere((math.sin(u) * 0.222, -math.cos(u) * 0.222, v), 0.03, RUST, scale=(1, 1, 0.5), parent=head, name='rust')
    pipe = K.joint('stovePipe', (0, 0, 0.56), head)
    K.cyl((0, 0, 0.73), 0.062, 0.34, IRON, parent=pipe, name='pipe')
    K.torus((0, 0, 0.66), 0.064, 0.006, NICKEL, parent=pipe, name='damperRing')
    K.cyl((0.064, 0, 0.66), 0.006, 0.04, NICKEL, rot=(0, math.pi / 2, 0), parent=pipe, name='damperKey')
    K.tube([(0, 0, 0.88), (0, 0.03, 0.94), (0, 0.10, 0.96)], 0.062, IRON, parent=pipe, name='elbow')
    K.joint('stovePipeTop', (0, 0.13, 0.96), pipe)
    # the firebox door: its mouth (hinged at the bottom; the grate is its teeth)
    K.box((0, -0.19, 0.205), (0.15, 0.03, 0.11), DARK, bevel=0.01, parent=head, name='fireboxDark')
    K.box((0, -0.175, 0.205), (0.13, 0.02, 0.085), COALS, bevel=0.01, parent=head, name='coals')
    m = K.joint('stoveMouth', (0, -0.215, 0.145), head)
    K.box((0, -0.218, 0.208), (0.18, 0.014, 0.125), IRON, bevel=0.012, parent=m, name='doorFrame') if False else None
    for x in (-0.085, 0.085):
        K.box((x, -0.22, 0.205), (0.016, 0.016, 0.12), NICKEL, bevel=0.004, parent=m, name='doorSide')
    for z in (0.148, 0.262):
        K.box((0, -0.22, z), (0.186, 0.016, 0.016), NICKEL, bevel=0.004, parent=m, name='doorRail')
    for x in (-0.05, -0.017, 0.017, 0.05):
        K.rod((x, -0.222, 0.152), (x, -0.222, 0.258), 0.0065, IRON, parent=m, name='grate')
    K.sphere((0.07, -0.235, 0.23), 0.012, NICKEL, parent=m, name='doorKnob')
    # the nose: the air-intake knob
    K.sphere((0, -0.232, 0.37), 0.03, NICKEL, parent=head, name='nose')
    K.cyl((0, -0.218, 0.37), 0.02, 0.02, NICKEL, rot=(math.pi / 2, 0, 0), parent=head, name='noseStem')
    # small hooded eyes, low iron lids, a heavy scowl
    for s in (1, -1):
        e = Vector((s * 0.075, -0.192, 0.432))
        face_eye('stove', s, e, 0.038, IRON, head, look=(s * 0.05, -1, -0.05), pupil=0.55, back=0.05)
        brow('stove', s, (s * 0.08, -0.205, 0.478), 0.085, 0.014, IRON, head, tilt=0.32, curve=0.0)
    K.export('AuditionStove', OUT, face='+Z')

# =============================================================== THE VACUUM (the innocent)
def vacuum():
    K.reset()
    MINT = K.mat('vacMint', (0.52, 0.80, 0.70), rough=0.22, coat=0.7)
    CREAM = K.mat('vacCream', (0.95, 0.92, 0.82), rough=0.35, coat=0.4)
    CHROME = K.mat('vacChrome', (0.85, 0.86, 0.88), metal=1, rough=0.15)
    HOSE = K.mat('vacHose', (0.30, 0.32, 0.36), rough=0.55)
    RUBBER = K.mat('vacRubber', (0.05, 0.05, 0.05), rough=0.8)
    BLUSH = K.mat('vacBlush', (0.95, 0.55, 0.55), rough=0.6)
    MOUTH = K.mat('vacMouthDark', (0.25, 0.08, 0.1), rough=0.6)
    root = K.joint('hwVacuum'); body = K.joint('vacBody', (0, 0, 0), root)
    for sx in (-1, 1):
        for sy in (-1, 1):
            K.cyl((sx * 0.1, sy * 0.13, 0.03), 0.03, 0.022, RUBBER, rot=(0, math.pi / 2, 0), parent=body, name='caster')
    head = K.joint('vacHead', (0, 0, 0.06), body)
    K.sphere((0, 0.01, 0.19), 0.17, MINT, scale=(1, 1.3, 0.85), seg=40, ring=24, parent=head, name='canister')
    K.torus((0, 0.01, 0.19), 0.172, 0.012, CHROME, rot=(0, math.pi / 2, 0), scale=(1, 1, 1), parent=head, name='band') if False else \
        K.torus((0, 0.02, 0.19), 0.172, 0.011, CHROME, rot=(math.pi / 2, 0, 0), parent=head, name='band')
    K.sphere((0, -0.17, 0.19), 0.13, CREAM, scale=(1, 0.42, 0.9), seg=36, ring=20, parent=head, name='faceplate')
    for s in (1, -1):
        face_eye('vac', s, (s * 0.058, -0.205, 0.235), 0.048, MINT, head, look=(s * 0.06, -1, 0.05), pupil=0.62, back=0.75)
        brow('vac', s, (s * 0.062, -0.205, 0.302), 0.045, 0.006, CREAM, head, tilt=-0.15, curve=0.008)
        K.sphere((s * 0.1, -0.198, 0.17), 0.022, BLUSH, scale=(1, 0.3, 0.6), parent=head, name='blush')
    m = K.joint('vacMouth', (0, -0.208, 0.135), head)
    K.sphere((0, -0.208, 0.135), 0.016, MOUTH, scale=(1.2, 0.45, 0.8), parent=m, name='mouthO')
    # the trunk (its hose), three joints; rest: lifted a little, curious
    pts = [Vector((0, -0.215, 0.17)), Vector((0, -0.285, 0.12)), Vector((0, -0.34, 0.15)), Vector((0, -0.365, 0.235))]
    t1 = K.joint('vacTrunk1', pts[0], head)
    t2 = K.joint('vacTrunk2', pts[1], t1)
    t3 = K.joint('vacTrunk3', pts[2], t2)
    for (a, b, j, r0, r1) in ((pts[0], pts[1], t1, 0.03, 0.027), (pts[1], pts[2], t2, 0.027, 0.024), (pts[2], pts[3], t3, 0.024, 0.022)):
        n = 6
        for i in range(n + 1):
            c = a + (b - a) * (i / n)
            d = (b - a).normalized()
            K.torus(c, r0 + (r1 - r0) * i / n, 0.006, HOSE, rot=rot_to(d), maj=18, mino=6, parent=j, name='rib')
        K.rod(a, b, (r0 + r1) / 2 * 0.85, HOSE, parent=j, name='hoseCore')
    K.cone(pts[3] + Vector((0, -0.004, 0.022)), 0.022, 0.034, 0.05, CHROME, rot=rot_to(Vector((0, -0.2, 1))), parent=t3, name='nozzle')
    # ears: the dust-bag flaps
    for s in (1, -1):
        S = 'L' if s > 0 else 'R'
        ej = K.joint(f'vacEar{S}', (s * 0.14, -0.04, 0.29), head)
        K.cyl((s * 0.17, -0.04, 0.31), 0.065, 0.014, CREAM, rot=(0, math.pi / 2 - s * 0.5, 0), parent=ej, name='ear')
        K.cyl((s * 0.176, -0.044, 0.31), 0.045, 0.008, MINT, rot=(0, math.pi / 2 - s * 0.5, 0), parent=ej, name='earInner')
    # its tail: the power cord and plug
    K.tube([(0, 0.21, 0.16), (0.03, 0.27, 0.12), (-0.02, 0.31, 0.08), (0.04, 0.34, 0.05)], 0.007, RUBBER, parent=head, name='cord')
    K.box((0.04, 0.355, 0.05), (0.03, 0.03, 0.025), RUBBER, bevel=0.004, parent=head, name='plug')
    for x in (0.03, 0.05):
        K.box((x, 0.375, 0.05), (0.004, 0.02, 0.008), CHROME, bevel=0, parent=head, name='prong')
    K.export('AuditionVacuum', OUT, face='+Z')

# =============================================================== THE ACCORDION (the melancholy one)
def accordion():
    K.reset()
    RED = K.mat('accLacquer', (0.52, 0.06, 0.07), rough=0.2, coat=0.9)
    PEARL = K.mat('accPearl', (0.93, 0.91, 0.86), rough=0.25, coat=0.5)
    BLACK = K.mat('accBlack', (0.03, 0.03, 0.035), rough=0.4)
    BELLOW = K.mat('accBellows', (0.10, 0.09, 0.12), rough=0.7)
    TRIM = K.mat('accTrim', (0.88, 0.85, 0.74), rough=0.5)
    CHROME = K.mat('accChrome', (0.85, 0.86, 0.88), metal=1, rough=0.15)
    LEATHER = K.mat('accLeather', (0.30, 0.17, 0.08), rough=0.7)
    MOUTH = K.mat('accMouthDark', (0.06, 0.01, 0.02), rough=0.8)
    root = K.joint('hwAccordion'); body = K.joint('accBody', (0, 0, 0), root)
    K.box((0, 0, 0.06), (0.34, 0.20, 0.12), RED, bevel=0.012, parent=body, name='bassEnd')
    for cx in (-1, 1):
        for cy in (-1, 1):
            K.box((cx * 0.162, cy * 0.092, 0.06), (0.03, 0.03, 0.125), CHROME, bevel=0.006, parent=body, name='corner')
    for r in range(3):
        for c in range(5):
            K.sphere((-0.08 + c * 0.04, -0.103, 0.035 + r * 0.03), 0.009, PEARL, parent=body, name='bassButton')
    bel = K.joint('accBellows', (0, 0, 0.12), body)     # scaled (y) to breathe
    n = 8
    for i in range(n):
        z = 0.12 + (i + 0.5) * 0.026
        K.box((0, 0, z), (0.31 - (i % 2) * 0.012, 0.18 - (i % 2) * 0.012, 0.026), BELLOW, bevel=0.003, parent=bel, name='pleat')
        if i % 2 == 0:
            K.box((0, -0.091, z), (0.29, 0.004, 0.006), TRIM, bevel=0, parent=bel, name='pleatTrim')
    head = K.joint('accHead', (0, 0, 0.33), body)       # rides on top of the bellows
    K.box((0, 0, 0.42), (0.34, 0.20, 0.18), RED, bevel=0.014, parent=head, name='trebleEnd')
    for cx in (-1, 1):
        for cy in (-1, 1):
            K.box((cx * 0.162, cy * 0.092, 0.42), (0.03, 0.03, 0.185), CHROME, bevel=0.006, parent=head, name='corner')
    # the grille band above the keys (a moustache of chrome)
    K.box((0, -0.101, 0.392), (0.24, 0.006, 0.02), CHROME, bevel=0.002, parent=head, name='grille')
    # the keyboard: its mouth (the jaw drops)
    K.box((0, -0.098, 0.358), (0.25, 0.012, 0.03), MOUTH, bevel=0.004, parent=head, name='mouthDark')
    m = K.joint('accMouth', (0, -0.08, 0.346), head)
    K.box((0, -0.104, 0.347), (0.26, 0.022, 0.016), RED, bevel=0.004, parent=m, name='jaw')
    for k in range(9):
        x = -0.104 + k * 0.026
        K.box((x, -0.112, 0.36), (0.022, 0.012, 0.022), PEARL, bevel=0.002, parent=m, name='key')
        if k % 7 not in (2, 6) and k < 8:
            K.box((x + 0.013, -0.12, 0.366), (0.012, 0.01, 0.014), BLACK, bevel=0.001, parent=m, name='sharp')
    # big, droopy eyes; sad brows
    for s in (1, -1):
        face_eye('acc', s, (s * 0.068, -0.105, 0.455), 0.044, RED, head, look=(s * 0.04, -1, -0.04), pupil=0.55, back=0.12)
        brow('acc', s, (s * 0.07, -0.108, 0.512), 0.06, 0.006, BLACK, head, tilt=-0.35, curve=0.006)
    # register switches on top: a little tuft
    for k in range(5):
        K.box((-0.06 + k * 0.03, -0.02, 0.516), (0.016, 0.03, 0.016 + 0.006 * (k % 2)), PEARL, bevel=0.003, parent=head, name='register')
    # strap loops: its arms
    for s in (1, -1):
        S = 'L' if s > 0 else 'R'
        a = K.joint(f'accArm{S}', (s * 0.17, 0, 0.44), head)
        K.tube([(s * 0.17, -0.06, 0.47), (s * 0.215, -0.05, 0.40), (s * 0.225, 0, 0.30), (s * 0.20, 0.05, 0.22), (s * 0.17, 0.06, 0.16)],
               0.011, LEATHER, parent=a, name='strap')
    K.export('AuditionAccordion', OUT, face='+Z')

# =============================================================== THE MAILBOX (the gossip)
def mailbox():
    K.reset()
    BLUE = K.mat('mailBlue', (0.08, 0.20, 0.52), rough=0.28, coat=0.6)
    WHITE = K.mat('mailWhite', (0.94, 0.94, 0.92), rough=0.4)
    RED = K.mat('mailRed', (0.80, 0.09, 0.07), rough=0.35, coat=0.4)
    CHROME = K.mat('mailChrome', (0.85, 0.86, 0.88), metal=1, rough=0.15)
    DARK = K.mat('mailDark', (0.02, 0.02, 0.03), rough=0.9)
    PAPER = K.mat('mailPaper', (0.96, 0.95, 0.90), rough=0.8)
    root = K.joint('hwMailbox'); body = K.joint('mailBody', (0, 0, 0), root)
    for sx in (-1, 1):
        for sy in (-1, 1):
            K.box((sx * 0.13, sy * 0.10, 0.035), (0.05, 0.05, 0.07), BLUE, bevel=0.008, parent=body, name='leg')
            K.box((sx * 0.13, sy * 0.10 - 0.012, 0.006), (0.06, 0.075, 0.012), BLUE, bevel=0.004, parent=body, name='foot')
    head = K.joint('mailHead', (0, 0, 0.07), body)      # the whole box leans in to listen
    K.box((0, 0, 0.25), (0.34, 0.30, 0.36), BLUE, bevel=0.012, parent=head, name='box')
    K.cyl((0, 0.004, 0.43), 0.17, 0.288, BLUE, rot=(math.pi / 2, 0, 0), verts=40, parent=head, name='dome')
    K.box((0, -0.151, 0.13), (0.30, 0.004, 0.025), WHITE, bevel=0.001, parent=head, name='stripe')
    # eyes on the dome's face, big brows
    for s in (1, -1):
        face_eye('mail', s, (s * 0.068, -0.15, 0.505), 0.05, BLUE, head, look=(s * 0.08, -1, -0.02), pupil=0.5, back=0.45)
        brow('mail', s, (s * 0.07, -0.15, 0.575), 0.065, 0.009, BLUE, head, tilt=-0.1, curve=0.01)
    # the mouth: the mail slot's pull-down flap (hinged at the bottom)
    K.box((0, -0.149, 0.33), (0.22, 0.006, 0.06), DARK, bevel=0.004, parent=head, name='slotDark')
    K.box((0.04, -0.13, 0.33), (0.08, 0.02, 0.045), PAPER, rot=(0, 0, 0.12), bevel=0.002, parent=head, name='letterInside')
    m = K.joint('mailMouth', (0, -0.158, 0.298), head)
    K.box((0, -0.16, 0.332), (0.24, 0.012, 0.07), BLUE, bevel=0.006, parent=m, name='flap')
    K.tube([(-0.07, -0.172, 0.352), (-0.07, -0.18, 0.358), (0.07, -0.18, 0.358), (0.07, -0.172, 0.352)], 0.006, CHROME, parent=m, name='flapHandle')
    # the gossip flag (raised when it has news)
    f = K.joint('mailFlag', (0.175, 0.02, 0.33), head)
    K.cyl((0.178, 0.02, 0.33), 0.016, 0.012, CHROME, rot=(0, math.pi / 2, 0), parent=f, name='flagPivot')
    K.box((0.185, 0.11, 0.33), (0.008, 0.18, 0.018), RED, bevel=0.002, parent=f, name='flagArm')
    K.box((0.185, 0.19, 0.35), (0.009, 0.07, 0.05), RED, bevel=0.003, parent=f, name='flag')
    K.export('AuditionMailbox', OUT, face='+Z')

for name, fn in (('safe', safe), ('stove', stove), ('vacuum', vacuum), ('accordion', accordion), ('mailbox', mailbox)):
    if ONLY is None or name in ONLY:
        fn()
