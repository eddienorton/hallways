# Simulates the seated player's view in the Floor 3 conference room on a portrait
# iPhone (75 deg vertical FOV, 390x844), with the round-two cast placed exactly
# as ConferenceAudition places them. SceneKit (x, y, z) -> Blender (x, -z, y).
import bpy, math, sys, os
from mathutils import Vector
OUT = sys.argv[sys.argv.index('--out') + 1]; SRC = sys.argv[sys.argv.index('--src') + 1]
VIEW = sys.argv[sys.argv.index('--view') + 1] if '--view' in sys.argv else 'seat'
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
s = 3.52
cx, cz = 10 * s - 0.25, 6 * s
side, end = 1.3 / 2 + 0.42, 5.4 / 2 + 0.42
PULL = 0.3
def B(x, y, z): return (x, -z, y)
def mat(name, c, rough=0.5, metal=0.0):
    m = bpy.data.materials.new(name); m.use_nodes = True
    b = m.node_tree.nodes['Principled BSDF']; b.inputs['Base Color'].default_value = (*c, 1)
    b.inputs['Roughness'].default_value = rough; b.inputs['Metallic'].default_value = metal
    return m
def box(loc, size, m, rotz=0.0, parent=None):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc); o = bpy.context.object; o.scale = size; o.rotation_euler.z = rotz
    o.data.materials.append(m)
    if parent: o.parent = parent; o.matrix_parent_inverse = parent.matrix_world.inverted()
    return o
WALL = mat('wall', (0.55, 0.53, 0.48)); FLOOR = mat('floor', (0.25, 0.22, 0.2)); WALNUT = mat('walnut', (0.27, 0.15, 0.09), 0.18)
LEATHER = mat('leather', (0.16, 0.1, 0.08), 0.55); STEEL = mat('steel', (0.25, 0.25, 0.25), 0.4, 0.6)
box(B(33.44, 0.025, 21.12), (7.04, 10.56, 0.05), FLOOR)
box(B(33.44, 1.5, 15.84 - 0.05), (7.04, 0.1, 3), WALL); box(B(33.44, 1.5, 26.4 + 0.05), (7.04, 0.1, 3), WALL)
box(B(29.92 - 0.05, 1.5, 21.12), (0.1, 10.56, 3), WALL); box(B(36.96 + 0.05, 1.5, 21.12), (0.1, 10.56, 3), WALL)
box(B(33.44, 3.0, 21.12), (7.04, 10.56, 0.05), WALL)
box(B(cx, 0.775, cz), (1.3, 5.4, 0.05), WALNUT)
for dz in (-1.5, 1.5): box(B(cx, 0.4, cz + dz), (0.46, 0.62, 0.65), STEEL)
def chair_at(x, z, yaw, visitor=False):
    e = bpy.data.objects.new('chair', None); sc.collection.objects.link(e); e.location = B(x, 0.05, z); e.rotation_euler.z = yaw
    bpy.context.view_layer.update()
    if visitor:
        box(e.matrix_world @ Vector((0, 0, 0.47)), (0.46, 0.44, 0.06), LEATHER, yaw, e)
        box(e.matrix_world @ Vector((0, 0.19, 0.86)), (0.44, 0.03, 0.12), WALNUT, yaw, e)
        for xx in (-0.2, 0.2):
            for yy in (-0.19, 0.19):
                box(e.matrix_world @ Vector((xx, yy, 0.225)), (0.04, 0.04, 0.45), WALNUT, yaw, e)
            box(e.matrix_world @ Vector((xx, 0.19, 0.69)), (0.04, 0.04, 0.48), WALNUT, yaw, e)
        return
    box(e.matrix_world @ Vector((0, 0, 0.47)), (0.52, 0.5, 0.09), LEATHER, yaw, e)
    box(e.matrix_world @ Vector((0, 0.25, 0.86)), (0.5, 0.08, 0.62), LEATHER, yaw, e)   # back: local -Z (scn) = +Y (bl)
    box(e.matrix_world @ Vector((0, 0, 0.26)), (0.05, 0.05, 0.36), STEEL, yaw, e)
def place(name, x, y, z, yaw, scale=1.0):
    before = set(bpy.data.objects)
    bpy.ops.wm.usd_import(filepath=os.path.join(SRC, name + '.usdz'))
    for t in [o for o in bpy.data.objects if o not in before and o.parent is None]:
        t.location = B(x, y, z); t.rotation_euler.z += yaw; t.scale = (scale, scale, scale)
W, E = math.pi / 2, -math.pi / 2
swivel = {0: 0.61, 1: 0.61, 2: 0.79, 3: 0.79, 4: 0.96, 5: 0.96}
def chair_pose(i):
    dz = (-1.75, 0, 1.75)[i // 2]
    x = cx - side - PULL if i % 2 == 0 else cx + side + PULL
    yaw = (W - swivel[i]) if i % 2 == 0 else (E + swivel[i])
    return x, cz + dz, yaw
ROUND = sys.argv[sys.argv.index('--round') + 1] if '--round' in sys.argv else '3'
S3 = '/tmp/claude-0/hw/out3'; S4 = '/tmp/claude-0/hw/out4'
def placeFrom(src, name, x, y, z, yaw, scale=1.0):
    global SRC
    old = SRC; SRC = src; place(name, x, y, z, yaw, scale); SRC = old
if ROUND == '3':
    cast = {0: (S3, 'AuditionViewMaster', 1.45, 0.06, True), 1: (SRC, 'AuditionStove', 1.3, 0.13, False), 2: (S3, 'AuditionRolodex', 1.55, 0.06, True),
            3: (SRC, 'AuditionMailbox', 1.45, 0.08, False), 4: (S3, 'AuditionFlashcube', 1.6, 0.06, True), 5: (S3, 'AuditionTelevision', 1.25, 0.05, False)}
    headc = (S3, 'AuditionTelephone', 1.7)
elif ROUND == '5':
    S5 = '/tmp/claude-0/hw/out5'
    cast = {0: (S5, 'AuditionRolodex2', 1.45, 0.06, True), 1: (SRC, 'AuditionStove', 1.3, 0.13, False), 2: (S5, 'AuditionCamera', 1.25, 0.06, True),
            3: (SRC, 'AuditionMailbox', 1.45, 0.08, False), 4: (S5, 'AuditionViewMaster2', 1.25, 0.06, True), 5: (S3, 'AuditionTelevision', 1.25, 0.05, False)}
    headc = (S3, 'AuditionTelephone', 2.1)
else:
    cast = {0: 'juanita', 1: (S4, 'AuditionRoadMap', 1.5, 0.08, True), 2: (S4, 'AuditionVacuum2', 1.6, 0.06, False),
            3: (SRC, 'AuditionAccordion', 1.5, 0.05, False), 4: (S4, 'AuditionDymo', 1.5, 0.06, True), 5: 'tinky'}
    headc = (S4, 'AuditionLP', 1.6)
for i in range(6):
    x, z, yaw = chair_pose(i)
    if cast[i] == 'juanita':
        place('Juanita', x + 0.12, 0.05, z, yaw); continue
    chair_at(x, z, yaw, visitor=True)
    if cast[i] == 'tinky':
        fx, fz = math.sin(yaw) * 0.05, math.cos(yaw) * 0.05
        box(B(x + fx, 0.535 + 0.12, z + fz), (0.36, 0.28, 0.24), mat('books', (0.6, 0.45, 0.15)), yaw)
        placeFrom(S4, 'MrTinkyCanister' if '--canister' in sys.argv else 'MrTinky', x + fx, 0.535 + 0.24, z + fz, yaw + math.pi, 2.0) if '--canister' in sys.argv else place('MrTinky', x + fx, 0.535 + 0.24, z + fz, yaw + math.pi, 2.0)
        continue
    src, name, sc_, fwd, booster = cast[i]
    fx, fz = math.sin(yaw) * fwd, math.cos(yaw) * fwd
    lift = 0
    if booster:
        box(B(x + fx, 0.535 + 0.12, z + fz), (0.36, 0.28, 0.24), mat('books', (0.6, 0.45, 0.15)), yaw); lift = 0.24
    placeFrom(src, name, x + fx, 0.535 + lift, z + fz, yaw, sc_)
placeFrom(headc[0], headc[1], cx, 0.80, cz - 2.2, 0.0, headc[2])
# rest poses as the game sets them
def card_angle(d):
    if d >= 1: return max(-1.35, -(0.22 + 0.1 * d))
    if d >= 0: return -0.05 - 0.27 * d
    if d > -1: return -0.05 + 1.35 * (-d)
    return min(1.55, 1.3 + 0.02 * (-d))
for i in range(18):
    o = bpy.data.objects.get(f'rolCard{i}')
    if o:
        d = i % 18
        if d > 9: d -= 18
        o.rotation_euler.x = card_angle(d)
for i in range(8):
    o = bpy.data.objects.get(f'rol2Card{i}')
    if o: o.rotation_euler.x = 0.0 if i == 0 else -0.45
for k in range(1, 6):
    o = bpy.data.objects.get(f'mapPanel{k}')
    if o: o.rotation_euler.y = (1 if k % 2 else -1) * (math.pi - 0.06)
for m in bpy.data.materials:
    if not m.node_tree: continue
    b = [nd for nd in m.node_tree.nodes if nd.type == 'BSDF_PRINCIPLED']
    if not b: continue
    if 'tvGlow' in m.name: b[0].inputs['Emission Color'].default_value = (0.85, 0.95, 0.9, 1); b[0].inputs['Emission Strength'].default_value = 2.5
    if 'stoveCoals' in m.name: b[0].inputs['Emission Color'].default_value = (1, 0.42, 0.08, 1); b[0].inputs['Emission Strength'].default_value = 1.2
    if 'Glass' in m.name:
        b[0].inputs['Alpha'].default_value = 0.22
        if hasattr(m, 'blend_method'): m.blend_method = 'BLEND'
seat = (cx, cz + end + 0.55)
chair_at(seat[0], seat[1], math.pi)
cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); sc.collection.objects.link(cam); sc.camera = cam
cam.data.sensor_fit = 'VERTICAL'; cam.data.angle_y = math.radians(float(sys.argv[sys.argv.index('--fov') + 1]) if '--fov' in sys.argv else 75)
if VIEW == 'seat':
    eye = Vector(B(seat[0], 1.22, seat[1] - 0.0)); look_yaw = 0.0; pitch = -0.02
else:
    eye = Vector(B(seat[0], 1.22, seat[1])); look_yaw = float(VIEW); pitch = -0.04
cam.location = eye
# SceneKit yaw 0 looks -Z (scn) = +Y (bl); camera looks along its -Z: rotate X by 90 deg, then yaw about Z
cam.rotation_euler = (math.pi / 2 + pitch, 0, look_yaw)
for (lx, lz) in ((35.2, 17.6), (35.2, 24.64), (31.68, 21.12)):
    d = bpy.data.lights.new('l', 'AREA'); d.energy = 260; d.size = 1.2
    o = bpy.data.objects.new('l', d); sc.collection.objects.link(o); o.location = B(lx, 2.9, lz)
w = bpy.data.worlds.new('w'); sc.world = w; w.use_nodes = True
w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.5, 0.48, 0.45, 1); w.node_tree.nodes['Background'].inputs['Strength'].default_value = 0.35
sc.render.engine = 'CYCLES'; sc.cycles.device = 'CPU'; sc.cycles.samples = 20
sc.view_settings.view_transform = 'Standard'
sc.render.resolution_x, sc.render.resolution_y = 390, 844
sc.render.filepath = os.path.join(OUT, f'iphone_r{ROUND}_{VIEW}.png'); bpy.ops.render.render(write_still=True)
