import bpy, math, sys, os
from mathutils import Vector
args = sys.argv[sys.argv.index('--')+1:]
blend, out = args[0], args[1]
views = args[2:] if len(args) > 2 else ['front', 'three', 'side']
bpy.ops.wm.open_mainfile(filepath=blend)
sc = bpy.context.scene
sc.render.engine = 'CYCLES'
sc.cycles.device = 'CPU'
sc.cycles.samples = 48
sc.cycles.use_denoising = False
sc.view_settings.view_transform = 'Standard'
sc.render.resolution_x, sc.render.resolution_y = 520, 780
w = bpy.data.worlds.new('w'); sc.world = w; w.use_nodes = True
w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.35, 0.30, 0.26, 1)
w.node_tree.nodes['Background'].inputs['Strength'].default_value = 0.45
# floor
bpy.ops.mesh.primitive_plane_add(size=8); fl = bpy.context.object
m = bpy.data.materials.new('floor'); m.use_nodes=True; m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value=(0.32,0.29,0.27,1)
fl.data.materials.append(m)
def light(name, loc, energy, size=1.5):
    d = bpy.data.lights.new(name, 'AREA'); d.energy = energy; d.size = size
    o = bpy.data.objects.new(name, d); sc.collection.objects.link(o); o.location = loc
    o.rotation_euler = (Vector((0, 0, 1.2)) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
light('key', (-1.8, -2.6, 3.0), 260)
light('fill', (2.2, -2.0, 1.8), 90)
light('rim', (0.5, 2.5, 2.8), 150)
cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); sc.collection.objects.link(cam); sc.camera = cam
cam.data.lens = 50
poses = {'front': (0, -5.2, 1.1), 'three': (2.4, -4.6, 1.3), 'side': (5.2, 0, 1.1), 'face': (0.6, -2.2, 1.6), 'back': (0.5, 5.2, 1.2)}
for v in views:
    cam.location = poses[v]
    tgt = Vector((0, 0, 1.45 if v == 'face' else 0.98))
    cam.rotation_euler = (tgt - cam.location).to_track_quat('-Z', 'Y').to_euler()
    sc.render.filepath = os.path.join(out, f'{v}.png')
    bpy.ops.render.render(write_still=True)
