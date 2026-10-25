import bpy, math, sys, os
from mathutils import Vector
OUT = sys.argv[sys.argv.index('--out') + 1]; SRC = sys.argv[sys.argv.index('--src') + 1]
CAM = sys.argv[sys.argv.index('--cam') + 1] if '--cam' in sys.argv else 'front'
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
order = [('Juanita', -3.0, 0), ('AuditionCommodore', -1.95, 0), ('AuditionCrane', -1.15, 0), ('AuditionProscenium', -0.35, 0),
         ('AuditionCloche', 0.4, 0), ('AuditionAspic', 1.05, 0), ('MrTinky', 1.7, math.pi)]
for name, x, turn in order:
    before = set(bpy.data.objects)
    bpy.ops.wm.usd_import(filepath=os.path.join(SRC, name + '.usdz'))
    new = [o for o in bpy.data.objects if o not in before]
    for t in [o for o in new if o.parent is None]:
        t.location.x += x; t.rotation_euler.z += turn
        if name == 'MrTinky': t.scale = (2, 2, 2)
for m in bpy.data.materials:
    if m.node_tree and ('Glass' in m.name or 'Jelly' in m.name):
        b = [n for n in m.node_tree.nodes if n.type == 'BSDF_PRINCIPLED']
        if b:
            b[0].inputs['Alpha'].default_value = 0.25 if 'Glass' in m.name else 0.8
            m.blend_method = 'BLEND' if hasattr(m, 'blend_method') else None
    if m.node_tree and m.node_tree.nodes.get('UsdPreviewSurface'): pass
bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 4, 0)); fl = bpy.context.object
m = bpy.data.materials.new('floor'); m.use_nodes = True; m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.30, 0.27, 0.24, 1); fl.data.materials.append(m)
bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 2.2, 10), rotation=(math.pi / 2, 0, 0)); wl = bpy.context.object
m2 = bpy.data.materials.new('wall'); m2.use_nodes = True; m2.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.33, 0.33, 0.30, 1); wl.data.materials.append(m2)
cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); sc.collection.objects.link(cam); sc.camera = cam
if CAM == 'front':
    cam.data.type = 'ORTHO'; cam.data.ortho_scale = 7.0; cam.location = (-0.65, -12, 1.0); cam.rotation_euler = (math.radians(88), 0, 0)
    resx, resy = 2400, 900
else:
    tx = float(CAM); cam.data.lens = 85
    cam.location = (tx + 0.25, -1.6, 0.45); cam.rotation_euler = (Vector((tx, 0, 0.32)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
    resx, resy = 900, 900
def light(loc, energy, size, color=(1, 0.95, 0.88)):
    d = bpy.data.lights.new('l', 'AREA'); d.energy = energy; d.size = size; d.color = color
    o = bpy.data.objects.new('l', d); sc.collection.objects.link(o); o.location = loc
    o.rotation_euler = (Vector((0, 0, 0.6)) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
light((-4, -6, 6), 1300, 5); light((5, -5, 3), 380, 4, (0.85, 0.9, 1.0)); light((0, 3, 5), 500, 6)
w = bpy.data.worlds.new('w'); sc.world = w; w.use_nodes = True
w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.4, 0.37, 0.33, 1); w.node_tree.nodes['Background'].inputs['Strength'].default_value = 0.25
sc.render.engine = 'CYCLES'; sc.cycles.device = 'CPU'; sc.cycles.samples = 24
sc.view_settings.view_transform = 'Standard'
sc.render.resolution_x = resx; sc.render.resolution_y = resy
sc.render.filepath = os.path.join(OUT, f'lineup_{CAM}.png'); bpy.ops.render.render(write_still=True)
