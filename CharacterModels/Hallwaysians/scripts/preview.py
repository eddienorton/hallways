import bpy, math, sys, os
from mathutils import Vector
a = sys.argv[sys.argv.index('--') + 1:]
blend, out, height = a[0], a[1], float(a[2])
face = a[3] if len(a) > 3 else '-Y'          # which Blender direction the character faces
bpy.ops.wm.open_mainfile(filepath=blend)
sc = bpy.context.scene
sc.render.engine = 'CYCLES'; sc.cycles.device = 'CPU'; sc.cycles.samples = 24
sc.view_settings.view_transform = 'Standard'
sc.render.resolution_x, sc.render.resolution_y = 900, 700
w = bpy.data.worlds.new('w'); sc.world = w; w.use_nodes = True
w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.36, 0.34, 0.31, 1)
w.node_tree.nodes['Background'].inputs['Strength'].default_value = 0.4
bpy.ops.mesh.primitive_plane_add(size=20); fl = bpy.context.object
m = bpy.data.materials.new('f'); m.use_nodes = True; m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.3, 0.28, 0.26, 1)
fl.data.materials.append(m)
sgn = -1 if face == '-Y' else 1
def light(loc, e, size):
    d = bpy.data.lights.new('l', 'AREA'); d.energy = e * height ** 2; d.size = size * height
    o = bpy.data.objects.new('l', d); sc.collection.objects.link(o); o.location = loc
    o.rotation_euler = (Vector((0, 0, height * 0.5)) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
light((-1.5 * height, sgn * 2.2 * height, 2.4 * height), 140, 1.4)
light((2 * height, sgn * 1.6 * height, 1.2 * height), 55, 1.2)
light((0, -sgn * 2 * height, 2 * height), 70, 2)
cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); sc.collection.objects.link(cam); sc.camera = cam
cam.data.lens = 60
shots = []
for name, ang in (('front', 0), ('three', 40), ('side', 90)):
    r = height * 3.3
    a_ = math.radians(ang)
    cam.location = (math.sin(a_) * r, sgn * math.cos(a_) * r, height * 0.62)
    cam.rotation_euler = (Vector((0, 0, height * 0.5)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
    sc.render.filepath = os.path.join(out, f'{name}.png'); bpy.ops.render.render(write_still=True)
    shots.append(sc.render.filepath)
from PIL import Image
ims = [Image.open(p) for p in shots]
sheet = Image.new('RGB', (sum(i.width for i in ims), ims[0].height))
x = 0
for i in ims: sheet.paste(i, (x, 0)); x += i.width
sheet.save(os.path.join(out, 'sheet.png'))
