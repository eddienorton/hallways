# JUANITA -- Hallwaysian. Reception. A slate enamel pillar on a weighted brass
# base with castors, brass collar, a three-stage telescoping neck, a broad flat
# head with bulging frog-set eyes under sly lids, a service bell on her crown,
# a rubber-stamp right hand and a brass pincer left hand. No mouth.
# Joint contract (SceneKit, faces +Z): adminBody > juanitaNeck1 > juanitaNeck2 >
# adminHead > adminEyes > adminPupils; adminArmPoint/Rest > adminElbow* > adminHand*.
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hallwaysian_kit as K
from mathutils import Vector
OUT = sys.argv[sys.argv.index('--out') + 1]
K.reset()
SLATE = K.mat('juanitaSlate', (0.19, 0.23, 0.28), rough=0.22, coat=0.8)
PUTTY = K.mat('juanitaPutty', (0.60, 0.50, 0.36), rough=0.32, coat=0.4)
BRASS = K.mat('juanitaBrass', (0.78, 0.58, 0.28), metal=1, rough=0.28)
CHROME = K.mat('juanitaChrome', (0.85, 0.86, 0.88), metal=1, rough=0.14)
RUBBER = K.mat('juanitaRubber', (0.04, 0.04, 0.04), rough=0.8)
WOOD = K.mat('juanitaStampWood', (0.42, 0.22, 0.09), rough=0.4, coat=0.5)
STAMPRED = K.mat('juanitaStampRubber', (0.45, 0.06, 0.05), rough=0.75)

root = K.joint('hwJuanita')
body = K.joint('adminBody', (0, 0, 0), root)
# weighted base on three castors
K.cyl((0, 0, 0.065), 0.30, 0.05, BRASS, verts=40, parent=body, name='base', bevel=0.008)
for k in range(3):
    a = math.radians(90 + 120 * k); x, y = math.cos(a) * 0.21, math.sin(a) * 0.21
    K.box((x, y, 0.035), (0.05, 0.03, 0.03), BRASS, parent=body, name=f'castorBracket{k}')
    K.cyl((x, y, 0.022), 0.022, 0.018, RUBBER, rot=(0, math.pi / 2, 0), parent=body, name=f'castor{k}')
# slate enamel pillar
K.lathe('pillar', [(0.09, 0.26, 0.26), (0.30, 0.235, 0.235), (0.80, 0.19, 0.19), (1.20, 0.155, 0.155), (1.27, 0.15, 0.15)],
        SLATE, parent=body, cap_top=True, nu=40)
K.torus((0, 0, 0.42), 0.229, 0.011, BRASS, parent=body, name='band')
# brass shoulder yoke and collar
K.cyl((0, 0, 1.25), 0.24, 0.035, BRASS, parent=body, name='yoke', bevel=0.006)
K.cyl((0, 0, 1.31), 0.19, 0.06, BRASS, parent=body, name='collar', bevel=0.008)
K.torus((0, 0, 1.345), 0.17, 0.016, BRASS, parent=body, name='collarRim')
K.cyl((0, 0, 1.38), 0.064, 0.10, BRASS, parent=body, name='neckBase')
# telescoping neck: each section is a joint that slides up (+Y in SceneKit)
n1 = K.joint('juanitaNeck1', (0, 0, 1.43), body)
K.cyl((0, 0, 1.35), 0.053, 0.22, CHROME, parent=n1, name='neckSection1')
K.torus((0, 0, 1.46), 0.056, 0.008, BRASS, parent=n1, name='neckRing1')
n2 = K.joint('juanitaNeck2', (0, 0, 1.49), n1)
K.cyl((0, 0, 1.40), 0.043, 0.20, CHROME, parent=n2, name='neckSection2')
K.torus((0, 0, 1.50), 0.046, 0.007, BRASS, parent=n2, name='neckRing2')
# head
head = K.joint('adminHead', (0, 0, 1.50), n2)
K.sphere((0, 0, 1.61), 0.36, PUTTY, scale=(1, 0.60, 0.40), seg=40, ring=20, parent=head, name='headShell')
# the service bell on her crown
K.sphere((0, 0.05, 1.735), 0.072, CHROME, scale=(1, 1, 0.62), seg=24, ring=12, parent=head, name='bellDome')
K.cyl((0, 0.05, 1.795), 0.009, 0.05, CHROME, parent=head, name='bellStem')
K.sphere((0, 0.05, 1.825), 0.018, CHROME, parent=head, name='bellButton')
# bulging frog-set eyes, sly slate lids (inner corners lower)
eyes = K.joint('adminEyes', (0, 0, 1.70), head)
pupils = K.joint('adminPupils', (0, 0, 1.70), eyes)
for s in (-1, 1):
    K.eye((s * 0.20, -0.07, 1.70), 0.115, SLATE, look=(s * -0.05, -1, -0.10), lid=0.47, lid_tilt=-s * 0.35,
          pupil=0.55, parent=eyes, prefix=f'eye{"R" if s < 0 else "L"}')
    # pupils belong to adminPupils (they glance)
for o in list(K.bpy.context.scene.objects):
    if o.name.startswith(('eyeRPupil', 'eyeLPupil')):
        K.own(o, pupils)
# arms
for s in (-1, 1):
    side = 'Point' if s < 0 else 'Rest'
    sx = s * 0.235
    K.box((s * 0.20, 0, 1.25), (0.07, 0.05, 0.03), BRASS, parent=body, name=f'shoulderBracket{side}')
    sh = K.joint(f'adminArm{side}', (sx, 0, 1.24), body)
    K.sphere((sx, 0, 1.24), 0.032, BRASS, parent=sh, name=f'shoulderBall{side}')
    K.rod((sx, 0, 1.22), (sx, 0, 1.00), 0.016, BRASS, parent=sh, name=f'upperArm{side}')
    el = K.joint(f'adminElbow{side}', (sx, 0, 0.99), sh)
    K.sphere((sx, 0, 0.99), 0.027, BRASS, parent=el, name=f'elbow{side}')
    K.rod((sx, 0, 0.97), (sx, 0, 0.79), 0.014, BRASS, parent=el, name=f'forearm{side}')
    hand = K.joint(f'adminHand{side}', (sx, 0, 0.78), el)
    if s < 0:   # rubber stamp: knob, neck, block, red rubber pad (facing down = out when she points)
        K.sphere((sx, 0, 0.775), 0.036, WOOD, parent=hand, name='stampKnob')
        K.cyl((sx, 0, 0.735), 0.016, 0.05, WOOD, parent=hand, name='stampNeck')
        K.box((sx, 0, 0.695), (0.10, 0.065, 0.035), WOOD, parent=hand, name='stampBlock')
        K.box((sx, 0, 0.672), (0.095, 0.06, 0.012), STAMPRED, bevel=0.002, parent=hand, name='adminFinger')
    else:       # brass pincer
        K.sphere((sx, 0, 0.775), 0.022, BRASS, parent=hand, name='pincerHub')
        for k in (-1, 1):
            K.rod((sx, 0, 0.77), (sx + k * 0.025, -0.01, 0.70), 0.007, BRASS, parent=hand, name=f'pincer{k}')
K.export('Juanita', OUT, face='+Z')
