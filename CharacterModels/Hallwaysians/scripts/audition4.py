# AUDITION, ROUND FOUR (Oct 12): the LP, the road map, the Dymo label
# maker (experimental), the Vacuum revised (no ring, little feet) -- and an
# ALTERNATE BODY for Mr. Tinky (a 35mm film canister; audition only; his
# original MrTinky.usdz is untouched). Same kit/contract as rounds 1-3.
import sys, os, math
import bpy, bmesh
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hallwaysian_kit as K
from mathutils import Vector
from audition import face_eye, brow, rot_to, lid_cap, WHITE, PUPIL, GLINT

OUT = sys.argv[sys.argv.index('--out') + 1]
ONLY = sys.argv[sys.argv.index('--only') + 1].split(',') if '--only' in sys.argv else None


def ring_dot(loc, r, m, parent, name, normal=(0, -1, 0)):
    return K.torus(loc, r, r * 0.22, m, rot=rot_to(normal), maj=28, mino=6, parent=parent, name=name)


def flat(loc, r, m, parent, name, sy=0.12, sz=1.0, seg=24):
    return K.sphere(loc, r, m, scale=(1, sy, sz), seg=seg, ring=10, parent=parent, name=name)


# =============================================================== THE LP (the romantic)
def lp():
    K.reset()
    VINYL = K.mat('lpVinyl', (0.015, 0.015, 0.017), rough=0.12, coat=1)
    GROOVE = K.mat('lpGroove', (0.05, 0.05, 0.055), rough=0.3)
    LABEL = K.mat('lpLabel', (0.70, 0.10, 0.08), rough=0.45)
    CREAM = K.mat('lpCream', (0.95, 0.90, 0.76), rough=0.5)
    DARK = K.mat('lpHoleDark', (0.01, 0.01, 0.01), rough=0.9)
    SLEEVE = K.mat('lpSleeve', (0.93, 0.89, 0.80), rough=0.7)
    ORANGE = K.mat('lpArtOrange', (0.92, 0.45, 0.12), rough=0.6)
    TEAL = K.mat('lpArtTeal', (0.10, 0.45, 0.48), rough=0.6)
    INK = K.mat('lpArtInk', (0.06, 0.06, 0.07), rough=0.6)
    WIRE = K.mat('lpWire', (0.82, 0.82, 0.84), metal=1, rough=0.2)
    root = K.joint('hwLP'); body = K.joint('lpBody', (0, 0, 0), root)
    # a wire record stand
    for sx in (-1, 1):
        K.tube([(sx * 0.12, -0.05, 0.004), (sx * 0.12, 0.05, 0.004), (sx * 0.12, 0.05, 0.06)], 0.004, WIRE, parent=body, name='stand')
        K.tube([(sx * 0.12, -0.05, 0.004), (sx * 0.12, -0.03, 0.04)], 0.004, WIRE, parent=body, name='standLip')
    head = K.joint('lpHead', (0, 0, 0.008), body)
    SQ = 0.32
    # the sleeve: two panels with the record between them; cover art on the front
    for y, nm in ((-0.007, 'sleeveFront'), (0.007, 'sleeveBack')):
        K.box((0, y, 0.008 + SQ / 2), (SQ, 0.004, SQ), SLEEVE, bevel=0.002, parent=head, name=nm)
    for x in (-SQ / 2, SQ / 2):
        K.box((x, 0, 0.008 + SQ / 2), (0.004, 0.018, SQ), SLEEVE, bevel=0.0015, parent=head, name='sleeveEdge')
    K.box((0, 0, 0.008), (SQ, 0.018, 0.004), SLEEVE, bevel=0.0015, parent=head, name='sleeveBottom')
    fy = -0.0095
    K.cyl((0.06, fy, 0.13), 0.085, 0.002, ORANGE, rot=(math.pi / 2, 0, 0), verts=48, parent=head, name='artSun')
    for k in range(5):
        K.box((-0.09 + k * 0.022, fy - 0.001, 0.12), (0.012, 0.002, 0.16 - k * 0.022), TEAL, bevel=0, parent=head, name='artBar')
    K.box((0, fy - 0.0015, 0.255), (0.26, 0.002, 0.006), INK, bevel=0, parent=head, name='artRule')
    for k in range(3):
        K.box((-0.08 + k * 0.03, fy - 0.0015, 0.285), (0.022, 0.002, 0.012), INK, bevel=0, parent=head, name='artTitleBlock')
    # the record: slides up out of the sleeve, spins, wobbles
    CZ = 0.40
    disc = K.joint('lpDisc', (0, 0, CZ), head)
    K.cyl((0, 0, CZ), 0.15, 0.003, VINYL, rot=(math.pi / 2, 0, 0), verts=96, parent=disc, name='vinyl')
    for r in (0.07, 0.085, 0.10, 0.115, 0.13, 0.142):
        for y in (-0.0017, 0.0017):
            K.torus((0, y, CZ), r, 0.0007, GROOVE, rot=(math.pi / 2, 0, 0), maj=96, mino=4, parent=disc, name='groove')
    for y in (-1, 1):
        K.cyl((0, y * 0.0018, CZ), 0.05, 0.0012, LABEL, rot=(math.pi / 2, 0, 0), verts=48, parent=disc, name='label')
    LY = -0.0028
    # the label's face: printed eyes, printed brows, the spindle hole for a mouth
    for s in (1, -1):
        S = 'L' if s > 0 else 'R'
        c = Vector((s * 0.019, LY, CZ + 0.016))
        ej = K.joint(f'lpEye{S}', c, disc)
        flat(c, 0.011, CREAM, ej, f'lpEyeWhite{S}', sy=0.1)
        pj = K.joint(f'lpPupil{S}', c, ej)
        flat(c + Vector((0, -0.0008, -0.002)), 0.0055, DARK, pj, f'lpPupilDot{S}', sy=0.1)
        bj = K.joint(f'lpBrow{S}', (s * 0.019, LY, CZ + 0.033), disc)
        K.tube([(s * 0.019 - 0.01, LY - 0.0005, CZ + 0.031), (s * 0.019, LY - 0.0005, CZ + 0.035), (s * 0.019 + 0.01, LY - 0.0005, CZ + 0.031)],
               0.0018, CREAM, parent=bj, name=f'lpBrowArc{S}')
    for k in range(2):     # printed arcs along the label's lower edge (no words)
        a0 = math.radians(210 + k * 70)
        pts = [(math.cos(a0 + t * 0.6) * 0.04, LY - 0.0004, CZ + math.sin(a0 + t * 0.6) * 0.04) for t in (0, 0.25, 0.5, 0.75, 1.0)]
        K.tube(pts, 0.0012, CREAM, parent=disc, name='labelPrint')
    m = K.joint('lpMouth', (0, LY, CZ - 0.008), disc)
    flat((0, LY - 0.0005, CZ - 0.008), 0.0065, DARK, m, 'spindleHole', sy=0.1, sz=0.6)
    K.export('AuditionLP', OUT, face='+Z')


# =============================================================== THE ROAD MAP (the know-it-all who can't fold)
PANELS = 6
PW = 0.13


def roadmap():
    K.reset()
    PAPER = K.mat('mapPaper', (0.96, 0.94, 0.86), rough=0.85)
    GREEN = K.mat('mapGreen', (0.78, 0.88, 0.70), rough=0.85)
    WATER = K.mat('mapWater', (0.62, 0.80, 0.92), rough=0.85)
    RED = K.mat('mapRed', (0.82, 0.12, 0.10), rough=0.6)
    BLUE = K.mat('mapBlue', (0.12, 0.28, 0.70), rough=0.6)
    YEL = K.mat('mapYellow', (0.98, 0.80, 0.15), rough=0.6)
    INK = K.mat('mapInk', (0.08, 0.08, 0.09), rough=0.6)
    GRID = K.mat('mapGrid', (0.55, 0.50, 0.42), rough=0.8)
    COVER = K.mat('mapCoverRed', (0.72, 0.10, 0.08), rough=0.5)
    H = 0.30
    root = K.joint('hwRoadMap'); body = K.joint('mapBody', (0, 0, 0), root)
    head = K.joint('mapHead', (0, 0, 0.0), body)          # the cover panel (and the whole map) turns
    y0 = -0.0016                                           # just in front of the paper

    def panel(parent, x0, k):
        """Panel k spans x0..x0+PW (unfolded layout), paper face at y=0."""
        cx = x0 + PW / 2
        K.box((cx, 0, H / 2 + 0.002), (PW - 0.002, 0.002, H), PAPER, bevel=0, parent=parent, name=f'paper{k}')
        # the back: an index grid
        for g in range(1, 4):
            K.box((x0 + g * PW / 4, 0.0012, H / 2), (0.001, 0.0004, H - 0.02), GRID, bevel=0, parent=parent, name='gridV')
        for g in range(1, 6):
            K.box((cx, 0.0012, 0.002 + g * H / 6), (PW - 0.02, 0.0004, 0.001), GRID, bevel=0, parent=parent, name='gridH')
        if k == 0:
            return
        # the front: land, a lake, and the roads
        K.box((cx, y0, H * 0.45), (PW - 0.014, 0.0008, H * 0.7), GREEN, bevel=0, parent=parent, name='land')
        if k % 2 == 0:
            K.sphere((cx + 0.02, y0 - 0.0006, H * 0.62), 0.025, WATER, scale=(1, 0.05, 0.7), parent=parent, name='lake')
        pts = [(x0 + 0.004, y0 - 0.001, H * (0.30 + 0.1 * (k % 3))), (cx, y0 - 0.001, H * 0.42), (x0 + PW - 0.004, y0 - 0.001, H * (0.3 + 0.1 * ((k + 1) % 3)))]
        K.tube(pts, 0.0025, RED, parent=parent, name='interstate')
        K.tube([(cx - 0.03, y0 - 0.001, 0.03), (cx - 0.01, y0 - 0.001, H * 0.5), (cx + 0.02, y0 - 0.001, H - 0.04)], 0.0018, BLUE, parent=parent, name='route')
        K.tube([(x0 + 0.01, y0 - 0.001, H * 0.7), (cx + 0.03, y0 - 0.001, H * 0.62)], 0.0016, YEL, parent=parent, name='byway')
        for t in range(3):
            K.cyl((x0 + 0.03 + t * 0.035, y0 - 0.0012, H * (0.2 + 0.25 * t)), 0.004, 0.0008, INK, rot=(math.pi / 2, 0, 0), verts=12, parent=parent, name='town')

    # panel 0: the cover, with its face
    panel(head, -PW / 2, 0)
    K.box((0, y0, H * 0.86), (PW - 0.006, 0.0008, H * 0.2), COVER, bevel=0, parent=head, name='coverBand')
    # a highway shield on the band (a badge, no words)
    K.cyl((0, y0 - 0.0008, H * 0.86), 0.022, 0.0008, PAPER, rot=(math.pi / 2, 0, 0), verts=6, parent=head, name='shield')
    K.cyl((0, y0 - 0.0012, H * 0.86), 0.016, 0.0008, BLUE, rot=(math.pi / 2, 0, 0), verts=6, parent=head, name='shieldInner')
    K.box((0, y0 - 0.0002, H * 0.4), (PW - 0.014, 0.0008, H * 0.52), GREEN, bevel=0, parent=head, name='coverLand')
    # a river and two county roads around its face (it is a map first)
    K.tube([(-0.06, y0 - 0.0012, 0.05), (-0.03, y0 - 0.0012, 0.08), (-0.045, y0 - 0.0012, 0.14), (-0.058, y0 - 0.0012, 0.2)], 0.003, WATER, parent=head, name='coverRiver')
    K.tube([(0.06, y0 - 0.0012, 0.06), (0.035, y0 - 0.0012, 0.1), (0.05, y0 - 0.0012, 0.22)], 0.0016, YEL, parent=head, name='coverRoad')
    K.tube([(-0.06, y0 - 0.0012, 0.215), (0.06, y0 - 0.0012, 0.205)], 0.0014, BLUE, parent=head, name='coverRoad2')
    # eyes: two city symbols (a ring and a dot) -- the dots look
    for s in (1, -1):
        S = 'L' if s > 0 else 'R'
        c = Vector((s * 0.03, y0 - 0.0014, H * 0.56))
        ej = K.joint(f'mapEye{S}', c, head)
        flat(c, 0.017, PAPER, ej, f'mapEyeWhite{S}', sy=0.08)
        ring_dot(c + Vector((0, -0.0004, 0)), 0.017, INK, ej, f'mapEyeRing{S}')
        pj = K.joint(f'mapPupil{S}', c, ej)
        flat(c + Vector((0, -0.0012, -0.002)), 0.0075, INK, pj, f'mapPupilDot{S}', sy=0.08)
        bj = K.joint(f'mapBrow{S}', (s * 0.03, y0 - 0.0016, H * 0.56 + 0.03), head)
        K.tube([(s * 0.03 - 0.016, y0 - 0.0016, H * 0.56 + 0.028), (s * 0.03 + 0.016, y0 - 0.0016, H * 0.56 + 0.032)], 0.0028, BLUE, parent=bj, name=f'mapBrowRoute{S}')
    # the mouth: a red highway (it bends into a smile or a frown)
    m = K.joint('mapMouth', (0, y0 - 0.0016, H * 0.4), head)
    K.tube([(-0.035, y0 - 0.0016, H * 0.4 + 0.004), (-0.012, y0 - 0.0016, H * 0.4 - 0.004), (0.012, y0 - 0.0016, H * 0.4 - 0.004),
            (0.035, y0 - 0.0016, H * 0.4 + 0.004)], 0.0038, RED, parent=m, name='mouthHighway')
    for x in (-0.035, 0.035):
        K.cyl((x, y0 - 0.002, H * 0.4 + 0.004), 0.006, 0.001, INK, rot=(math.pi / 2, 0, 0), verts=12, parent=m, name='mouthTown')
    # the other panels, hinged in a chain (unfolded layout; the game folds them)
    parent = head
    for k in range(1, PANELS):
        x0 = -PW / 2 + k * PW
        j = K.joint(f'mapPanel{k}', (x0, 0, 0), parent)
        panel(j, x0, k)
        parent = j
    K.export('AuditionRoadMap', OUT, face='+Z')


# =============================================================== THE DYMO (experimental)
def dymo():
    K.reset()
    BODY = K.mat('dymoTeal', (0.12, 0.42, 0.50), rough=0.3, coat=0.6)
    BLACK = K.mat('dymoBlack', (0.03, 0.03, 0.035), rough=0.4)
    CHROME = K.mat('dymoChrome', (0.85, 0.86, 0.88), metal=1, rough=0.15)
    TAPE = K.mat('dymoTapeRed', (0.82, 0.10, 0.10), rough=0.35, coat=0.6)
    WHITE_ = K.mat('dymoLetter', (0.95, 0.95, 0.92), rough=0.4)
    root = K.joint('hwDymo'); body = K.joint('dymoBody', (0, 0, 0), root)
    # it sits on its squeeze handle like a bird on a perch
    head = K.joint('dymoHead', (0, 0, 0.0), body)
    K.box((0, 0.02, 0.13), (0.11, 0.30, 0.10), BODY, bevel=0.03, parent=head, name='housing')
    K.cyl((0, 0.06, 0.19), 0.095, 0.03, BODY, verts=48, parent=head, name='wheelWell')
    # the letter wheel (turns while it thinks), with its pointer
    wj = K.joint('dymoWheel', (0, 0.06, 0.21), head)
    K.cyl((0, 0.06, 0.21), 0.085, 0.016, BLACK, verts=48, parent=wj, name='wheel')
    for k in range(24):
        a = 2 * math.pi * k / 24
        K.box((math.cos(a) * 0.072, 0.06 + math.sin(a) * 0.072, 0.219), (0.008, 0.008, 0.002), WHITE_, rot=(0, 0, a), bevel=0, parent=wj, name='glyph')
    K.cyl((0, 0.06, 0.222), 0.025, 0.012, CHROME, verts=24, parent=wj, name='hub')
    # eyes: the two chrome rivets on its snout, now looking
    for s in (1, -1):
        face_eye('dymo', s, (s * 0.032, -0.125, 0.155), 0.022, BODY, head, look=(s * 0.08, -1, 0.05), pupil=0.55, back=0.3)
        brow('dymo', s, (s * 0.033, -0.13, 0.19), 0.03, 0.005, BLACK, head, tilt=0.05, curve=0.003)
    # the mouth: the tape exit (a little red tongue of label tape)
    m = K.joint('dymoMouth', (0, -0.128, 0.105), head)
    K.box((0, -0.128, 0.105), (0.05, 0.012, 0.012), BLACK, bevel=0.003, parent=m, name='slot')
    tj = K.joint('dymoTape', (0, -0.13, 0.105), head)
    K.box((0, -0.16, 0.105), (0.03, 0.06, 0.003), TAPE, bevel=0.001, parent=tj, name='tape')
    for k in range(3):
        K.box((-0.008 + k * 0.008, -0.165, 0.1068), (0.005, 0.006, 0.0012), WHITE_, bevel=0, parent=tj, name='embossed')
    # the squeeze handle under it (its jaw): hinged at the front
    hj = K.joint('dymoHandle', (0, -0.1, 0.07), head)
    K.box((0, 0.04, 0.045), (0.08, 0.26, 0.03), BLACK, bevel=0.012, parent=hj, name='handle')
    K.box((0, 0.15, 0.022), (0.09, 0.05, 0.044), BLACK, bevel=0.012, parent=hj, name='handleFoot')
    K.box((0, -0.07, 0.022), (0.09, 0.05, 0.044), BLACK, bevel=0.012, parent=head, name='frontFoot')
    K.export('AuditionDymo', OUT, face='+Z')


# =============================================================== THE VACUUM, REVISED (no ring; little feet)
def vacuum2():
    K.reset()
    MINT = K.mat('vacMint', (0.52, 0.80, 0.70), rough=0.22, coat=0.7)
    CREAM = K.mat('vacCream', (0.95, 0.92, 0.82), rough=0.35, coat=0.4)
    CHROME = K.mat('vacChrome', (0.85, 0.86, 0.88), metal=1, rough=0.15)
    HOSE = K.mat('vacHose', (0.30, 0.32, 0.36), rough=0.55)
    RUBBER = K.mat('vacRubber', (0.05, 0.05, 0.05), rough=0.8)
    BLUSH = K.mat('vacBlush', (0.95, 0.55, 0.55), rough=0.6)
    MOUTH = K.mat('vacMouthDark', (0.25, 0.08, 0.1), rough=0.6)
    root = K.joint('hwVacuum'); body = K.joint('vacBody', (0, 0, 0), root)
    # four little feet (stubby, mint, with cream soles) in place of the casters
    for sx in (-1, 1):
        for sy in (-1, 1):
            K.sphere((sx * 0.09, sy * 0.12 - 0.01, 0.03), 0.032, MINT, scale=(1, 1.25, 0.9), parent=body, name='foot')
            K.sphere((sx * 0.09, sy * 0.12 - 0.022, 0.008), 0.03, CREAM, scale=(1, 1.3, 0.3), parent=body, name='sole')
    head = K.joint('vacHead', (0, 0, 0.06), body)
    K.sphere((0, 0.01, 0.19), 0.17, MINT, scale=(1, 1.3, 0.85), seg=40, ring=24, parent=head, name='canister')
    # (the chrome band is gone) -- a chrome toe-latch and a little carry handle instead
    K.tube([(-0.05, 0.03, 0.33), (-0.03, 0.03, 0.37), (0.03, 0.03, 0.37), (0.05, 0.03, 0.33)], 0.01, CHROME, parent=head, name='carryHandle')
    K.sphere((0, -0.17, 0.19), 0.13, CREAM, scale=(1, 0.42, 0.9), seg=36, ring=20, parent=head, name='faceplate')
    for s in (1, -1):
        face_eye('vac', s, (s * 0.058, -0.205, 0.235), 0.048, MINT, head, look=(s * 0.06, -1, 0.05), pupil=0.62, back=0.75)
        brow('vac', s, (s * 0.062, -0.205, 0.302), 0.045, 0.006, CREAM, head, tilt=-0.15, curve=0.008)
        K.sphere((s * 0.1, -0.198, 0.17), 0.022, BLUSH, scale=(1, 0.3, 0.6), parent=head, name='blush')
    m = K.joint('vacMouth', (0, -0.208, 0.135), head)
    K.sphere((0, -0.208, 0.135), 0.016, MOUTH, scale=(1.2, 0.45, 0.8), parent=m, name='mouthO')
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
    for s in (1, -1):
        S = 'L' if s > 0 else 'R'
        ej = K.joint(f'vacEar{S}', (s * 0.14, -0.04, 0.29), head)
        K.cyl((s * 0.17, -0.04, 0.31), 0.065, 0.014, CREAM, rot=(0, math.pi / 2 - s * 0.5, 0), parent=ej, name='ear')
        K.cyl((s * 0.176, -0.044, 0.31), 0.045, 0.008, MINT, rot=(0, math.pi / 2 - s * 0.5, 0), parent=ej, name='earInner')
    K.tube([(0, 0.21, 0.16), (0.03, 0.27, 0.12), (-0.02, 0.31, 0.08), (0.04, 0.34, 0.05)], 0.007, RUBBER, parent=head, name='cord')
    K.box((0.04, 0.355, 0.05), (0.03, 0.03, 0.025), RUBBER, bevel=0.004, parent=head, name='plug')
    for x in (0.03, 0.05):
        K.box((x, 0.375, 0.05), (0.004, 0.02, 0.008), CHROME, bevel=0, parent=head, name='prong')
    K.export('AuditionVacuum2', OUT, face='+Z')


# =============================================================== MR. TINKY, ALTERNATE BODY: a film canister
def tinky_canister():
    """Same joints, proportions, eyes, ears and pencil legs as tinky.py; the
    tin can becomes a 35mm film cassette lying on its side, and the spring
    tail becomes the film leader, curling out of the felt slot."""
    K.reset()
    BLACK = K.mat('tinkyCassette', (0.05, 0.05, 0.055), metal=0.6, rough=0.3)
    YEL = K.mat('tinkyCassetteYellow', (0.95, 0.72, 0.10), rough=0.4)
    CAPM = K.mat('tinkyCassetteEnd', (0.70, 0.70, 0.72), metal=1, rough=0.25)
    FELT = K.mat('tinkyFelt', (0.06, 0.04, 0.04), rough=1)
    FILM = K.mat('tinkyFilm', (0.45, 0.22, 0.08), rough=0.25, coat=0.6)
    PENCIL = K.mat('tinkyPencil', (0.96, 0.74, 0.12), rough=0.55)
    WOOD = K.mat('tinkyPencilWood', (0.86, 0.70, 0.50), rough=0.8)
    FERRULE = K.mat('tinkyFerrule', (0.74, 0.74, 0.70), metal=1, rough=0.3)
    ERASER = K.mat('tinkyEraser', (0.93, 0.55, 0.60), rough=0.85)
    CAP = K.mat('tinkyCap', (0.72, 0.12, 0.10), metal=0.5, rough=0.3)
    SPRING = K.mat('tinkySpring', (0.80, 0.81, 0.83), metal=1, rough=0.2)
    TIN = K.mat('tinkyTin', (0.76, 0.77, 0.79), metal=1, rough=0.24)
    H = 0.16; R = 0.062; L = 0.19
    root = K.joint('hwTinky')
    body = K.joint('tinCanRatBody', (0, 0, H), root)
    RX = (math.pi / 2, 0, 0)
    K.cyl((0, 0, H), R, L, BLACK, rot=RX, verts=40, parent=body, name='cassette')
    K.cyl((0, 0, H), R + 0.0012, 0.12, YEL, rot=RX, verts=40, parent=body, name='band', cap=False)
    K.cyl((0, 0.0, H), R + 0.0018, 0.012, BLACK, rot=RX, verts=40, parent=body, name='bandStripe', cap=False)
    for y in (-L / 2, L / 2):
        K.cyl((0, y, H), R * 0.98, 0.008, CAPM, rot=RX, verts=40, parent=body, name='endCap')
    K.cyl((0, L / 2 + 0.01, H), 0.018, 0.02, CAPM, rot=RX, verts=20, parent=body, name='spoolKnob')   # his nose
    # the felt-lipped slot along his side, and the film leader (his tail) curling out of it
    K.box((R * 0.92, 0, H - 0.01), (0.012, L * 0.85, 0.02), FELT, bevel=0.003, parent=body, name='feltSlot')
    for s in (-1, 1):
        base = (s * 0.028, L / 2 + 0.008, H + 0.024)
        K.helix(base, (0, 1, 0.1), 0.016, 0.006, 3.0, 0.0016, SPRING, parent=body, name='eyeSpring')
        K.eye((s * 0.028, L / 2 + 0.04, H + 0.026), 0.02, TIN, look=(s * 0.12, 1, 0.08), lid=0.12, pupil=0.5, parent=body, prefix='eye')
    for i, s in enumerate((-1, 1)):
        ear = K.joint(f'tinCanRatEar{i}', (s * 0.042, L / 2 - 0.03, H + R + 0.012), body)
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
    tail = K.joint('tinCanRatTail', (R * 0.95, -L / 2 + 0.03, H - 0.01), body)
    pts = []
    for k in range(14):
        t = k / 13
        pts.append((R * 0.95 + 0.06 * t + 0.01 * math.sin(t * 6), -L / 2 + 0.03 - 0.17 * t, H - 0.01 + 0.09 * math.sin(t * 2.6)))
    for k in range(len(pts) - 1):
        a, b = Vector(pts[k]), Vector(pts[k + 1])
        seg = K.box((a + b) / 2, (0.003, (b - a).length + 0.002, 0.028), FILM, bevel=0, parent=tail, name='leader')
        seg.rotation_euler = (0, 0, math.atan2(-(b - a).x, (b - a).y))
    hips = [(-0.042, 0.06), (0.042, 0.06), (-0.042, -0.06), (0.042, -0.06)]
    hz = H - R * 0.55
    for i, (x, y) in enumerate(hips):
        leg = K.joint(f'tinCanRatLeg{i}', (x, y, hz), body)
        K.rod((x, y, hz + 0.012), (x, y, hz + 0.022), 0.0045, WOOD, r1=0.0012, verts=6, parent=leg, name='pencilTip', smooth=False)
        K.rod((x, y, hz - 0.075), (x, y, hz + 0.012), 0.0058, PENCIL, verts=6, parent=leg, name='pencil', smooth=False)
        K.cyl((x, y, hz - 0.083), 0.0061, 0.016, FERRULE, verts=12, parent=leg, name='ferrule')
        K.sphere((x, y, 0.016), 0.0072, ERASER, scale=(1, 1, 1.9), seg=12, ring=8, parent=leg, name='eraser')
    K.export('MrTinkyCanister', OUT)


for name, fn in (('lp', lp), ('roadmap', roadmap), ('dymo', dymo), ('vacuum2', vacuum2), ('tinky', tinky_canister)):
    if ONLY is None or name in ONLY:
        fn()
