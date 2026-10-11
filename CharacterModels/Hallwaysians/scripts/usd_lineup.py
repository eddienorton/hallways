# Renders the six EXPORTED .usdz assets (re-imported) -- a check of the pipeline output.
import bpy, math, sys, os
from mathutils import Vector
OUT = sys.argv[sys.argv.index('--out') + 1]; SRC = sys.argv[sys.argv.index('--src') + 1]
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
order = [('Elwood', -3.45, 0.15), ('Juanita', -2.05, -0.18), ('MrTinky', -0.85, 0.85 + math.pi), ('Hum', 0.35, -0.12), ('Dottie', 1.75, -0.35), ('Nan', 3.05, 0.3)]
for name, x, turn in order:
    before = set(bpy.data.objects)
    bpy.ops.wm.usd_import(filepath=os.path.join(SRC, name + '.usdz'))
    new = [o for o in bpy.data.objects if o not in before]
    tops = [o for o in new if o.parent is None]
    for t in tops:
        t.location.x += x
        t.rotation_euler.z += turn
    if name == 'MrTinky':
        for t in tops: t.scale = (2, 2, 2)   # the game shows him at 2x
        for o in new:
            if o.name.startswith('tinCanRatEar') and o.type == 'EMPTY':
                pass
bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 4, 0)); fl = bpy.context.object
m = bpy.data.materials.new('floor'); m.use_nodes = True; m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.30, 0.27, 0.24, 1); fl.data.materials.append(m)
bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 2.2, 10), rotation=(math.pi / 2, 0, 0)); wl = bpy.context.object
m2 = bpy.data.materials.new('wall'); m2.use_nodes = True; m2.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.33, 0.33, 0.30, 1); wl.data.materials.append(m2)
cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); sc.collection.objects.link(cam); sc.camera = cam
cam.data.type = 'ORTHO'; cam.data.ortho_scale = 8.3; cam.location = (-0.2, -12, 2.15); cam.rotation_euler = (math.radians(87), 0, 0)
def light(loc, energy, size, color=(1, 0.95, 0.88)):
    d = bpy.data.lights.new('l', 'AREA'); d.energy = energy; d.size = size; d.color = color
    o = bpy.data.objects.new('l', d); sc.collection.objects.link(o); o.location = loc
    o.rotation_euler = (Vector((0, 0, 1.0)) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
light((-4, -6, 6), 1300, 5); light((5, -5, 3), 380, 4, (0.85, 0.9, 1.0)); light((0, 3, 5), 500, 6)
w = bpy.data.worlds.new('w'); sc.world = w; w.use_nodes = True
w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.4, 0.37, 0.33, 1); w.node_tree.nodes['Background'].inputs['Strength'].default_value = 0.2
sc.render.engine = 'CYCLES'; sc.cycles.device = 'CPU'; sc.cycles.samples = int(sys.argv[sys.argv.index('--samples') + 1])
sc.view_settings.view_transform = 'Standard'
r = float(sys.argv[sys.argv.index('--res') + 1])
sc.render.resolution_x = int(2400 * r); sc.render.resolution_y = int(1000 * r)
sc.render.filepath = os.path.join(OUT, 'usd_lineup.png'); bpy.ops.render.render(write_still=True)
