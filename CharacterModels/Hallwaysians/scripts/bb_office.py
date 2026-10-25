"""Portrait-iPhone views of the Floor 3 office with the Black Box on the desk,
laid out from PlayerOffice.swift (SceneKit -> Blender: (x, y, z) -> (x, -z, y)).
Views: 'door' (just inside, walking in), 'near' (at the desk front),
'seated' (in the desk chair at the computer)."""
import bpy, math, sys, os
from mathutils import Vector, Euler
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bb_preview as P

OUT = sys.argv[sys.argv.index('--out') + 1]
VIEW = sys.argv[sys.argv.index('--view') + 1]
EXPR = sys.argv[sys.argv.index('--expr') + 1] if '--expr' in sys.argv else 'idle'
YAW = float(sys.argv[sys.argv.index('--yaw') + 1]) if '--yaw' in sys.argv else 0.0

s = 3.52
FT = 0.05
deskX, deskZ = 12 * s + 0.25, (9 + 0.5) * s - 0.05 - 1.6
top = FT + 0.774


def B(x, y, z):
    return Vector((x, -z, y))


def mat(name, c, rough=0.5, metal=0.0, emit=None):
    m = bpy.data.materials.new(name); m.use_nodes = True
    b = m.node_tree.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value = (*c, 1)
    b.inputs['Roughness'].default_value = rough; b.inputs['Metallic'].default_value = metal
    if emit:
        b.inputs['Emission Color'].default_value = (*emit, 1); b.inputs['Emission Strength'].default_value = 1.0
    return m


def box(c, size, m, yaw=0.0):
    """c, size in SceneKit terms (centre x,y,z; size w,h,d)."""
    bpy.ops.mesh.primitive_cube_add(size=1, location=B(*c))
    o = bpy.context.object
    o.scale = (size[0], size[2], size[1])
    o.rotation_euler.z = yaw
    o.data.materials.append(m)
    return o


def desk_local(x, y, z):
    # desk yaw pi: local (x, y, z) -> world (deskX - x, FT + y, deskZ - z)
    return (deskX - x, FT + y, deskZ - z)


P.scene_base()
sc = bpy.context.scene
sc.cycles.samples = 48
sc.render.resolution_x, sc.render.resolution_y = 780, 1688
WALL = mat('wall', (0.62, 0.6, 0.55)); FLOOR = mat('floor', (0.33, 0.3, 0.27), 0.7); CEIL = mat('ceil', (0.8, 0.8, 0.78))
OAK = mat('oak', (0.56, 0.42, 0.27), 0.5); OAKD = mat('oakd', (0.42, 0.3, 0.19), 0.45)
STEEL = mat('steel', (0.7, 0.7, 0.7), 0.3, 0.8); BRASS = mat('brass', (0.78, 0.6, 0.3), 0.3, 0.85)
GREEN = mat('green', (0.08, 0.32, 0.18), 0.3); DARK = mat('dark', (0.08, 0.08, 0.08), 0.35); ALU = mat('alu', (0.78, 0.78, 0.78), 0.32, 0.85)
SCREEN = mat('screen', (0.12, 0.16, 0.22), 0.4, emit=(0.15, 0.2, 0.28)); BLOT = mat('blot', (0.16, 0.2, 0.24), 0.7)
LEATHER = mat('leather', (0.12, 0.1, 0.09), 0.55)

x0, x1 = 11.5 * s, 13.5 * s
z0, z1 = 7.5 * s, 9.5 * s
box(((x0 + x1) / 2, FT / 2, (z0 + z1) / 2), (x1 - x0, FT, z1 - z0), FLOOR)
box(((x0 + x1) / 2, 2.8, (z0 + z1) / 2), (x1 - x0, 0.05, z1 - z0), CEIL)
for z in (z0, z1):
    box(((x0 + x1) / 2, 1.4, z), (x1 - x0, 2.8, 0.1), WALL)
for x in (x0, x1):
    box((x, 1.4, (z0 + z1) / 2), (0.1, 2.8, z1 - z0), WALL)
# desk
box(desk_local(0, 0.752, 0), (1.8, 0.04, 0.85), OAKD, math.pi)
box(desk_local(0, 0.37, 0.375), (1.76, 0.71, 0.03), OAK, math.pi)
for side in (-1, 1):
    box(desk_local(side * (0.9 - 0.23), 0.365, -0.02), (0.42, 0.73, 0.75), OAK, math.pi)
box(desk_local(0, 0.775, -0.1), (0.7, 0.006, 0.44), BLOT, math.pi)
# lamp
lx, lz = -0.64, -0.2
box(desk_local(lx, 0.787, lz), (0.18, 0.025, 0.12), BRASS, math.pi)
box(desk_local(lx, 0.944, lz), (0.018, 0.32, 0.018), BRASS, math.pi)
box(desk_local(lx, 1.124, lz + 0.05), (0.28, 0.08, 0.15), GREEN, math.pi)
# tray & phone
box(desk_local(0.62, 0.79, 0.2), (0.3, 0.02, 0.24), STEEL, math.pi)
box(desk_local(0.6, 0.804, -0.18), (0.2, 0.06, 0.2), DARK, math.pi)
# computer (screen toward the occupant, -Z local)
box(desk_local(0.08, 0.78, -0.12), (0.22, 0.012, 0.17), ALU, math.pi)
box(desk_local(0.08, 0.884, -0.15), (0.05, 0.2, 0.02), ALU, math.pi)
box(desk_local(0.08, 1.144, -0.13), (0.6, 0.37, 0.022), ALU, math.pi)
box(desk_local(0.08, 1.144, -0.142), (0.55, 0.32, 0.004), SCREEN, math.pi)
box(desk_local(0.08, 0.78, -0.28), (0.42, 0.012, 0.13), ALU, math.pi)
# portrait frame
box(desk_local(0.3, 0.85, 0.02), (0.13, 0.17, 0.02), OAKD, math.pi)
# chair behind the desk, visitor chair in front
cx, cz = deskX, deskZ + 1.05
box((cx, 0.47 + FT, cz), (0.52, 0.09, 0.5), LEATHER)
box((cx, 0.86 + FT, cz + 0.25), (0.5, 0.62, 0.08), LEATHER)
vx, vz = deskX - 0.8, deskZ - 1.15
box((vx, 0.47 + FT, vz), (0.46, 0.06, 0.44), LEATHER, 0.25)
box((vx, 0.86 + FT, vz - 0.2), (0.44, 0.12, 0.03), OAKD, 0.25)
# cabinet & shelf (east wall)
box((x1 - 0.32, 0.65 + FT, z1 - 0.9), (0.5, 1.3, 0.6), mat('cab', (0.45, 0.47, 0.5), 0.4, 0.4))

# lights: two ceiling panels and the lamp glow (on)
for z in (z0 + 1.8, z1 - 1.8):
    d = bpy.data.lights.new('ceil', 'AREA'); d.energy = 260; d.size = 1.2
    o = bpy.data.objects.new('ceil', d); sc.collection.objects.link(o); o.location = B((x0 + x1) / 2, 2.7, z)
    o.rotation_euler = (0, 0, 0)
d = bpy.data.lights.new('lamp', 'POINT'); d.energy = 6; d.color = (1, 0.8, 0.55)
o = bpy.data.objects.new('lamp', d); sc.collection.objects.link(o); o.location = B(*desk_local(lx, 1.05, lz + 0.06))
sc.world.node_tree.nodes['Background'].inputs['Strength'].default_value = 0.15

# the box
bx = desk_local(-0.62, 0.774, 0.21)
root = P.import_box(B(*bx), math.pi + YAW)
P.build_face(root, P.EXPR[EXPR])

cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); sc.collection.objects.link(cam); sc.camera = cam
cam.data.sensor_fit = 'VERTICAL'
cam.data.angle = math.radians(75 if VIEW != 'seated' else 60)
eye = 1.6 + FT
if VIEW == 'door':
    pos, look = (12 * s, eye, 8 * s - 0.9), (deskX, 0.9, deskZ)
elif VIEW == 'mid':
    pos, look = (12 * s + 0.2, eye, 8 * s + 0.6), (bx[0] - 0.2, 0.75, bx[2])
elif VIEW == 'near':
    pos, look = (bx[0] - 0.35, eye, bx[2] - 1.15), (bx[0] - 0.1, 0.75, bx[2] + 0.1)
else:  # seated at the computer
    pos, look = (deskX, 1.2 + FT, deskZ + 0.75), (deskX, 1.0, deskZ - 0.3)
cam.location = B(*pos)
cam.rotation_euler = (B(*look) - B(*pos)).to_track_quat('-Z', 'Y').to_euler()
sc.render.filepath = os.path.join(OUT, f'office-{VIEW}-{EXPR}.png')
bpy.ops.render.render(write_still=True)
print('RENDERED', sc.render.filepath)
