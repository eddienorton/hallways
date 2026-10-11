# Cartoon Juanita -- generated in Blender (bpy), exported to USDZ for SceneKit.
# Blender frame: Z up, character faces -Y. Export converts to SceneKit Y-up, face +Z.
import bpy, bmesh, math, sys, os
from mathutils import Vector, Matrix, Euler

OUT = sys.argv[sys.argv.index('--out') + 1] if '--out' in sys.argv else '/tmp/juanita'
os.makedirs(OUT, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

# ---------- materials ----------
def mat(name, color, metal=0.0, rough=0.5, coat=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value = (*color, 1)
    b.inputs['Metallic'].default_value = metal
    b.inputs['Roughness'].default_value = rough
    if coat:
        b.inputs['Coat Weight'].default_value = coat
    return m

GOLD = mat('juanitaGold', (0.78, 0.55, 0.14), metal=0.5, rough=0.3)
GOLD_DARK = mat('juanitaGoldTrim', (0.62, 0.40, 0.08), metal=0.65, rough=0.28)
WHITE = mat('juanitaEyeWhite', (0.95, 0.95, 0.93), rough=0.15)
PUPIL = mat('juanitaPupil', (0.01, 0.01, 0.012), rough=0.05, coat=1.0)
LASH = mat('juanitaLash', (0.015, 0.012, 0.012), rough=0.6)
LIPS = mat('juanitaLips', (0.30, 0.13, 0.07), rough=0.35)
BLOUSE = mat('juanitaBlouse', (0.74, 0.66, 0.53), rough=0.8)
COLLAR = mat('juanitaCollar', (0.86, 0.80, 0.70), rough=0.75)
SKIRT = mat('juanitaSkirt', (0.035, 0.035, 0.038), rough=0.9)
SHOE = mat('juanitaShoe', (0.03, 0.03, 0.03), rough=0.3)
BADGE_TEXT = mat('juanitaBadgeText', (0.02, 0.02, 0.02), rough=0.5)

# ---------- helpers ----------
def new_obj(name, me=None, parent=None, loc=(0, 0, 0)):
    o = bpy.data.objects.new(name, me)
    scene.collection.objects.link(o)
    if parent:
        o.parent = parent
    o.location = loc
    return o

def empty(name, parent=None, loc=(0, 0, 0)):
    return new_obj(name, None, parent, loc)

def finish(me, m):
    me.materials.append(m)
    for p in me.polygons:
        p.use_smooth = True
    return me

def surface(name, fn, nu, nv, m, parent=None, loc=(0, 0, 0), cap_top=False, cap_bottom=False):
    """Closed-in-u parametric surface: fn(u in [0,1), v in [0,1]) -> (x,y,z)."""
    bm = bmesh.new()
    rows = []
    for j in range(nv + 1):
        v = j / nv
        rows.append([bm.verts.new(fn(i / nu, v)) for i in range(nu)])
    for j in range(nv):
        for i in range(nu):
            a, b = rows[j][i], rows[j][(i + 1) % nu]
            c, d = rows[j + 1][(i + 1) % nu], rows[j + 1][i]
            bm.faces.new((a, b, c, d))
    if cap_bottom:
        bm.faces.new(list(reversed(rows[0])))
    if cap_top:
        bm.faces.new(rows[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name + 'Mesh')
    bm.to_mesh(me)
    bm.free()
    return new_obj(name, finish(me, m), parent, loc)

def ellipsoid(name, r, m, parent=None, loc=(0, 0, 0), nu=28, nv=18, deform=None, rot=(0, 0, 0)):
    rx, ry, rz = r
    def fn(u, v):
        lon = 2 * math.pi * u
        lat = -math.pi / 2 + math.pi * v
        lat = max(-math.pi / 2 + 1e-4, min(math.pi / 2 - 1e-4, lat))
        x = rx * math.cos(lat) * math.cos(lon)
        y = ry * math.cos(lat) * math.sin(lon)
        z = rz * math.sin(lat)
        if deform:
            x, y, z = deform(x, y, z)
        return (x, y, z)
    o = surface(name, fn, nu, nv, m, parent, loc, cap_top=True, cap_bottom=True)
    o.rotation_euler = rot
    return o

def lathe(name, profile, m, parent=None, loc=(0, 0, 0), nu=36, bulge=None, steps=4, cap_top=False, cap_bottom=False):
    """profile: [(z, rx, ry)] bottom->top, interpolated (smoothstep) with `steps` per segment."""
    pts = []
    for k in range(len(profile) - 1):
        z0, a0, b0 = profile[k]
        z1, a1, b1 = profile[k + 1]
        for s in range(steps):
            t = s / steps
            t = t * t * (3 - 2 * t)
            pts.append((z0 + (z1 - z0) * (s / steps), a0 + (a1 - a0) * t, b0 + (b1 - b0) * t))
    pts.append(profile[-1])
    nv = len(pts) - 1
    def fn(u, v):
        z, rx, ry = pts[round(v * nv)]
        lon = 2 * math.pi * u
        x, y = rx * math.cos(lon), ry * math.sin(lon)
        if bulge:
            x, y = bulge(x, y, z, lon)
        return (x, y, z)
    return surface(name, fn, nu, nv, m, parent, loc, cap_top=cap_top, cap_bottom=cap_bottom)

def tube(name, p0, p1, r0, r1, m, parent=None, nu=20):
    """Tapered capsule-ish tube from p0 to p1 (local coords), axis aligned."""
    p0, p1 = Vector(p0), Vector(p1)
    d = p1 - p0
    L = d.length
    o = lathe(name, [(0, r0, r0), (L, r1, r1)], m, parent, nu=nu, steps=6, cap_top=True, cap_bottom=True)
    q = Vector((0, 0, 1)).rotation_difference(d.normalized())
    o.rotation_mode = 'QUATERNION'
    o.rotation_quaternion = q
    o.location = p0
    return o

def bake_rotation(o):
    """Apply rotation into the mesh so the exported node is unrotated."""
    if o.data is None:
        return
    o.rotation_mode = 'XYZ'
    mw = o.matrix_basis.copy()
    loc = mw.to_translation()
    rs = mw.to_3x3().to_4x4()
    o.data.transform(rs)
    o.matrix_basis = Matrix.Translation(loc)

# ---------- the figure ----------
root = empty('cartoonJuanita')
body = empty('adminBody', root)

# Legs and shoes (static).
for s in (-1, 1):
    hipx, footx = s * 0.12, s * 0.16
    tube(f'leg{s}', (hipx, 0.0, 0.60), (s * 0.145, -0.01, 0.38), 0.058, 0.052, GOLD, body)
    ellipsoid(f'knee{s}', (0.06, 0.06, 0.06), GOLD, body, (s * 0.145, -0.01, 0.37))
    tube(f'shin{s}', (s * 0.145, -0.01, 0.36), (footx, 0.0, 0.11), 0.052, 0.04, GOLD, body)
    ellipsoid(f'ankle{s}', (0.047, 0.047, 0.03), GOLD_DARK, body, (footx, 0.0, 0.10))
    # Black flat: a rounded slipper, toe forward (-Y); the gold foot shows on top.
    ellipsoid(f'shoe{s}', (0.082, 0.15, 0.05), SHOE, body, (footx, -0.05, 0.05),
              deform=lambda x, y, z: (x, y, z if z > -0.03 else -0.03))
    ellipsoid(f'foot{s}', (0.062, 0.1, 0.035), GOLD, body, (footx, -0.07, 0.083))

# Skirt: pencil, a little flare at the hips, dark charcoal.
def hips(x, y, z, lon):
    # A rounder seat at the back (+Y) and soft front.
    if y > 0:
        y *= 1.0 + 0.10 * math.exp(-((z - 0.70) / 0.12) ** 2)
    return x, y
lathe('skirt', [(0.42, 0.255, 0.20), (0.55, 0.285, 0.215), (0.70, 0.315, 0.235),
                (0.80, 0.29, 0.215), (0.88, 0.245, 0.18), (0.905, 0.235, 0.172)],
      SKIRT, body, bulge=hips, cap_top=True, cap_bottom=True)
lathe('waistband', [(0.875, 0.252, 0.186), (0.905, 0.244, 0.18)], SKIRT, body, steps=2)

# Blouse torso with a bust, fitted waist.
def bust(x, y, z, lon):
    if y < 0:
        for c in (-0.42, 0.42):
            ang = math.atan2(-y, x) - (math.pi / 2 + c)
            k = math.exp(-(ang / 0.33) ** 2) * math.exp(-((z - 1.035) / 0.065) ** 2)
            y -= 0.055 * k
    return x, y
lathe('blouse', [(0.86, 0.235, 0.17), (0.93, 0.245, 0.172), (1.00, 0.29, 0.195), (1.05, 0.31, 0.21),
                 (1.11, 0.305, 0.195), (1.165, 0.25, 0.155), (1.20, 0.12, 0.095), (1.215, 0.07, 0.065)],
      BLOUSE, body, bulge=bust, steps=5)

def blouse_front_y(x, z):
    # Front surface of the blouse at (x, z) (approximate; for buttons/badge/collar).
    prof = [(0.86, 0.235, 0.17), (0.93, 0.245, 0.172), (1.00, 0.29, 0.195), (1.05, 0.31, 0.21),
            (1.11, 0.305, 0.195), (1.165, 0.25, 0.155), (1.20, 0.12, 0.095)]
    for k in range(len(prof) - 1):
        if prof[k][0] <= z <= prof[k + 1][0]:
            t = (z - prof[k][0]) / (prof[k + 1][0] - prof[k][0]); t = t * t * (3 - 2 * t)
            rx = prof[k][1] + (prof[k + 1][1] - prof[k][1]) * t
            ry = prof[k][2] + (prof[k + 1][2] - prof[k][2]) * t
            break
    else:
        rx, ry = 0.25, 0.17
    yy = -ry * math.sqrt(max(0.0, 1 - (x / rx) ** 2))
    _, yb = bust(x, yy, z, 0)
    return yb

# Buttons down the front placket.
for i, z in enumerate((1.12, 1.05, 0.98, 0.91)):
    ellipsoid(f'button{i}', (0.014, 0.008, 0.014), GOLD_DARK, body, (0.0, blouse_front_y(0.0, z) - 0.004, z), nu=16, nv=10)
# Collar: two rounded points lying on the chest + a band round the neck.
for s in (-1, 1):
    c = ellipsoid(f'collar{s}', (0.10, 0.02, 0.06), COLLAR, body,
                  (s * 0.075, blouse_front_y(s * 0.075, 1.165) - 0.004, 1.165), nu=24, nv=14, rot=(0.6, 0, s * 0.55),
                  deform=lambda x, y, z: (x, y, z * (1.0 if z > 0 else 0.7)))
    bake_rotation(c)
lathe('collarBand', [(1.18, 0.083, 0.078), (1.225, 0.072, 0.068)], COLLAR, body, steps=2)

# Name badge on her left (+X) chest.
bz, bx = 1.08, 0.14
by = blouse_front_y(bx, bz) - 0.006
badge = ellipsoid('badge', (0.075, 0.007, 0.024), GOLD, body, (bx, by, bz), nu=24, nv=8,
                  deform=lambda x, y, z: (max(-0.07, min(0.07, x * 1.3)), y, max(-0.021, min(0.021, z * 1.3))))
bpy.ops.object.text_add(location=(0, 0, 0))
txt = bpy.context.object
txt.data.body = 'JUANITA'
txt.data.size = 0.019
txt.data.extrude = 0.0015
txt.data.align_x = 'CENTER'
txt.data.align_y = 'CENTER'
bpy.ops.object.convert(target='MESH')
txt = bpy.context.object
txt.name = 'badgeText'
txt.data.materials.clear(); txt.data.materials.append(BADGE_TEXT)
txt.rotation_euler = (math.pi / 2, 0, 0)
bake_rotation(txt)
txt.parent = body
txt.location = (bx, by - 0.008, bz - 0.001)

# Neck.
tube('neck', (0, 0, 1.17), (0, 0, 1.31), 0.066, 0.06, GOLD, body)

# ---------- head (pivot at the top of the neck) ----------
head = empty('adminHead', body, (0, 0, 1.27))
HC = Vector((0, 0, 0.24))        # head centre, relative to the pivot
HR = (0.43, 0.34, 0.265)
def head_shape(x, y, z):
    # Wider, fuller lower half (cheeks); a slightly smaller crown.
    f = 1.0 + 0.06 * max(0.0, -z / HR[2]) - 0.05 * max(0.0, z / HR[2])
    return x * f, y * f, z
ellipsoid('skull', HR, GOLD, head, tuple(HC), nu=56, nv=36, deform=head_shape)

def head_front_y(x, zrel):
    zz = zrel
    f = 1.0 + 0.06 * max(0.0, -zz / HR[2]) - 0.05 * max(0.0, zz / HR[2])
    t = 1 - (x / (HR[0] * f)) ** 2 - (zz / HR[2]) ** 2
    return -HR[1] * f * math.sqrt(max(0.0, t))

# Eyes: a group whose origin is at eye height (squint/blink scale about it).
EYE_Z = HC.z + 0.10
eyes = empty('adminEyes', head, (0, 0, EYE_Z))
pupils = empty('adminPupils', eyes, (0, 0, 0))
ER = 0.16
for s in (-1, 1):
    ex = s * 0.235
    ey = head_front_y(ex, 0.10) + 0.075
    ellipsoid(f'eyeWhite{s}', (ER, ER * 0.93, ER * 1.05), WHITE, eyes, (ex, ey, 0), nu=36, nv=24)
    # Pupil: a big glossy black lens, looking a touch to the side (toward her left) and up.
    look = Vector((0.18 * 1, -1.0, 0.10)).normalized()
    pc = Vector((ex, ey, 0)) + look * (ER * 0.93 - 0.045)
    p = ellipsoid(f'pupil{s}', (0.092, 0.06, 0.098), PUPIL, pupils, tuple(pc), nu=40, nv=24)
    p.rotation_mode = 'QUATERNION'
    p.rotation_quaternion = Vector((0, -1, 0)).rotation_difference(look)
    bake_rotation(p)
    # Upper lid: a gold shell over the top of the eye, sloping down toward
    # the nose -- the sly, bossy look.
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=36, v_segments=24, radius=ER * 1.06)
    tilt = -s * 0.32                               # inner corner lower
    n = Vector((math.sin(tilt) * 1.0, 0.25, math.cos(tilt))).normalized()
    bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=(0, 0, ER * 0.12),
                           plane_no=n, clear_inner=True)
    me = bpy.data.meshes.new(f'lid{s}Mesh'); bm.to_mesh(me); bm.free()
    lid = new_obj(f'lid{s}', finish(me, GOLD), eyes, (ex, ey, 0))
    sol = lid.modifiers.new('thick', 'SOLIDIFY'); sol.thickness = 0.012
    # Eyeliner: a black band along the lid's lower edge.
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=36, v_segments=24, radius=ER * 1.075)
    geom = lambda: bm.verts[:] + bm.edges[:] + bm.faces[:]
    bmesh.ops.bisect_plane(bm, geom=geom(), plane_co=Vector((0, 0, ER * 0.12)) - n * 0.004, plane_no=n, clear_inner=True)
    bmesh.ops.bisect_plane(bm, geom=geom(), plane_co=Vector((0, 0, ER * 0.12)) + n * 0.022, plane_no=n, clear_outer=True)
    # keep only the front half of the band (the back is buried in the head)
    bmesh.ops.bisect_plane(bm, geom=geom(), plane_co=(0, 0.02, 0), plane_no=(0, 1, 0), clear_outer=True)
    me = bpy.data.meshes.new(f'liner{s}Mesh'); bm.to_mesh(me); bm.free()
    liner = new_obj(f'liner{s}', finish(me, LASH), eyes, (ex, ey, 0))
    lsol = liner.modifiers.new('thick', 'SOLIDIFY'); lsol.thickness = 0.008
    # Lashes: three curled black flicks off the outer top of the lid.
    for k, (ang, ln) in enumerate(((0.62, 0.07), (0.92, 0.085), (1.22, 0.075))):
        a = s * ang
        base = Vector((ex, ey, 0)) + Vector((math.sin(a) * ER * 1.06, -0.035, math.cos(a) * ER * 1.03))
        out = Vector((math.sin(a), -0.25, math.cos(a))).normalized()
        mid = base + out * ln * 0.55
        tip = mid + (out + Vector((s * 0.2, 0, 0.9))).normalized() * ln * 0.55
        tube(f'lash{s}_{k}a', tuple(base), tuple(mid), 0.010, 0.0065, LASH, eyes, nu=10)
        tube(f'lash{s}_{k}b', tuple(mid), tuple(tip), 0.0065, 0.002, LASH, eyes, nu=10)

# Mouth: a small, knowing smirk -- full lips, the right corner (her left) up.
mouth = empty('adminMouth', head, (0, head_front_y(0, -0.105) + 0.010, HC.z - 0.105))
for nm, r, loc, rot in (('lipUpperL', (0.06, 0.026, 0.021), (-0.037, -0.004, 0.013), (0, -0.25, 0)),
                        ('lipUpperR', (0.06, 0.026, 0.021), (0.037, -0.004, 0.016), (0, 0.18, 0)),
                        ('lipLower', (0.082, 0.028, 0.023), (0.005, -0.003, -0.018), (0, 0.08, 0))):
    o = ellipsoid(nm, r, LIPS, mouth, loc, nu=28, nv=16, rot=rot)
    bake_rotation(o)
# (the smirk is in the lips themselves: the right corner sits higher)
bake_children = [c for c in mouth.children]

# No antenna (Oct 9): Hallwaysians are not antenna-bearing creatures. The
# crown is the skull's own smooth curve; Juanita is bald for now.

# ---------- arms (shoulder pivots; arms hang along -Z) ----------
for s in (-1, 1):
    nm = 'Point' if s < 0 else 'Rest'           # her right (-X) is the pointing arm
    sh = empty(f'adminArm{nm}', body, (s * 0.40, 0.0, 1.115))
    ellipsoid(f'shoulderBall{s}', (0.06, 0.06, 0.06), GOLD, sh, (0, 0, 0))
    # Short sleeve: a cream cap over the shoulder flaring into a cuffed tube.
    ellipsoid(f'sleeveCap{s}', (0.092, 0.092, 0.07), BLOUSE, sh, (s * -0.02, 0, 0.015))
    lathe(f'sleeve{s}', [(-0.10, 0.078, 0.076), (-0.085, 0.084, 0.082), (-0.02, 0.092, 0.09), (0.02, 0.088, 0.086)],
          BLOUSE, sh, loc=(s * -0.005, 0, 0), steps=3, cap_bottom=True)
    tube(f'upperArm{s}', (0, 0, -0.03), (0, 0, -0.27), 0.056, 0.05, GOLD, sh)
    el = empty(f'adminElbow{nm}', sh, (0, 0, -0.30))
    ellipsoid(f'elbowBall{s}', (0.058, 0.058, 0.058), GOLD, el, (0, 0, 0))
    lathe(f'elbowRing{s}', [(0.035, 0.054, 0.054), (0.05, 0.054, 0.054)], GOLD_DARK, el, steps=2)
    tube(f'forearm{s}', (0, 0, -0.03), (0, 0, -0.25), 0.052, 0.044, GOLD, el)
    hand = empty(f'adminHand{nm}', el, (0, 0, -0.30))
    lathe(f'wristRing{s}', [(0.02, 0.05, 0.05), (0.045, 0.048, 0.048)], GOLD_DARK, hand, steps=2)
    ellipsoid(f'fist{s}', (0.07, 0.064, 0.08), GOLD, hand, (0, -0.005, -0.04))
    ellipsoid(f'thumb{s}', (0.027, 0.025, 0.042), GOLD, hand, (-s * 0.055, -0.045, -0.02))
    if s < 0:
        f = tube('adminFinger', (0, -0.025, -0.09), (0, -0.035, -0.17), 0.02, 0.017, GOLD, hand, nu=14)

# ---------- export ----------
# Save the Blender (Z-up) scene for previews first.
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'juanita.blend'))
# SceneKit frame, baked INTO the data: every node unrotated, unscaled, Y up,
# face +Z -- so the game's own eulerAngles/scale/position animations on
# adminHead, adminEyes, adminArm... mean exactly what they mean today.
for o in scene.objects:
    if o.type == 'MESH':
        bpy.context.view_layer.objects.active = o
        mb = o.matrix_basis.copy()
        loc = mb.to_translation()
        o.data.transform(mb.to_3x3().to_4x4())
        o.matrix_basis = Matrix.Translation(loc)
    elif o.rotation_mode == 'QUATERNION' or o.rotation_euler.to_matrix() != Matrix.Identity(3):
        raise SystemExit(f'empty {o.name} is rotated')
M = Matrix(((1, 0, 0, 0), (0, 0, 1, 0), (0, -1, 0, 0), (0, 0, 0, 1)))   # (x, y, z) -> (x, z, -y)
for o in scene.objects:
    if o.type == 'MESH':
        o.data.transform(M)
        o.data.update()
    o.location = (M @ o.location.to_4d()).to_3d()
for o in scene.objects:
    o.select_set(True)
usda = os.path.join(OUT, 'JuanitaCartoon.usda')
bpy.ops.wm.usd_export(filepath=usda, export_materials=True, generate_preview_surface=True, export_uvmaps=False,
                      convert_orientation=False, export_subdivision='IGNORE', evaluation_mode='RENDER',
                      export_lights=False, export_cameras=False, root_prim_path='')

tris = sum(len(o.evaluated_get(bpy.context.evaluated_depsgraph_get()).data.loop_triangles) if False else 0 for o in scene.objects)
dg = bpy.context.evaluated_depsgraph_get()
t = 0
for o in scene.objects:
    if o.type == 'MESH':
        me = o.evaluated_get(dg).to_mesh(); me.calc_loop_triangles(); t += len(me.loop_triangles); o.evaluated_get(dg).to_mesh_clear()
print('TRIANGLES', t, 'OBJECTS', len(scene.objects))
