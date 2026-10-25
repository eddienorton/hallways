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
cast = {0: None, 1: ('AuditionStove', 1.3, 0.13), 2: ('AuditionMailbox', 1.45, 0.08), 3: ('AuditionAccordion', 1.5, 0.05), 4: ('AuditionVacuum', 1.6, 0.06), 5: 'tinky'}
for i in range(6):
    x, z, yaw = chair_pose(i)
    if i == 0:
        place('Juanita', x, 0.05, z, yaw); continue
    chair_at(x, z, yaw, visitor=True)
    fwd = 0.05 if cast[i] == 'tinky' else cast[i][2]
    fx, fz = math.sin(yaw) * fwd, math.cos(yaw) * fwd
    if cast[i] == 'tinky':
        box(B(x + fx, 0.535 + 0.12, z + fz), (0.36, 0.28, 0.24), mat('books', (0.6, 0.45, 0.15)), yaw)
        place('MrTinky', x + fx, 0.535 + 0.24, z + fz, yaw + math.pi, 2.0)
    else:
        place(cast[i][0], x + fx, 0.535, z + fz, yaw, cast[i][1])
place('AuditionSafe', cx, 0.80, cz - 2.2, 0.0, 1.3)
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
sc.render.filepath = os.path.join(OUT, f'iphone_{VIEW}.png'); bpy.ops.render.render(write_still=True)
