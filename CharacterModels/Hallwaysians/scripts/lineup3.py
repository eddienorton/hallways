"""Round-three lineup and close-ups. Imports the exported USDZ and puts the
characters in their REST pose as the game does (the Rolodex's cards fanned;
the television's face glowing)."""
import bpy, math, sys, os
from mathutils import Vector
OUT = sys.argv[sys.argv.index('--out') + 1]
CAM = sys.argv[sys.argv.index('--cam') + 1] if '--cam' in sys.argv else 'front'
ORDER = sys.argv[sys.argv.index('--order') + 1] if '--order' in sys.argv else 'r3'
POSE = sys.argv[sys.argv.index('--pose') + 1] if '--pose' in sys.argv else 'rest'
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
S3 = '/tmp/claude-0/hw/out3'; S2 = '/tmp/claude-0/hw/out'; S4 = '/tmp/claude-0/hw/out4'
S5 = '/tmp/claude-0/hw/out5'
ORDERS = {
    'r5': [(S3, 'AuditionTelephone', -2.4, 1.6), (S2, 'AuditionStove', -1.55, 1.0), (S5, 'AuditionViewMaster2', -0.8, 1.0),
           (S5, 'AuditionRolodex2', -0.05, 1.0), (S2, 'AuditionMailbox', 0.7, 1.1), (S5, 'AuditionCamera', 1.45, 1.0),
           (S3, 'AuditionTelevision', 2.3, 1.2)],
    'r3': [(S3, 'AuditionTelephone', -2.4, 1.6), (S2, 'AuditionStove', -1.55, 1.0), (S3, 'AuditionViewMaster', -0.8, 1.3),
           (S3, 'AuditionRolodex', -0.05, 1.5), (S2, 'AuditionMailbox', 0.7, 1.1), (S3, 'AuditionFlashcube', 1.45, 1.5),
           (S3, 'AuditionTelevision', 2.3, 1.2)],
    'r4': [(S4, 'AuditionLP', -2.3, 1.5), (S4, 'AuditionRoadMap', -1.45, 1.4), (S4, 'AuditionDymo', -0.7, 1.4),
           (S4, 'AuditionVacuum2', 0.1, 1.25), (S2, 'AuditionAccordion', 0.9, 1.2), (S2, 'MrTinky', 1.6, 2.0),
           (S4, 'MrTinkyCanister', 2.3, 2.0)],
}


def card_angle(d):
    """Mirrors ConferenceAudition's Rolodex fan (SceneKit x-rotation; + = toward the viewer)."""
    if d >= 1: return max(-1.35, -(0.22 + 0.1 * d))
    if d >= 0: return -0.05 - 0.27 * d
    if d > -1: return -0.05 + 1.35 * (-d)
    return min(1.55, 1.3 + 0.02 * (-d))


def pose_rolodex(face_index=0, n=18):
    for i in range(n):
        o = bpy.data.objects.get(f'rolCard{i}')
        if not o: continue
        d = (i - face_index) % n
        if d > n / 2: d -= n
        o.rotation_euler.x = card_angle(d)           # Blender +x tips the top toward the viewer (-Y), as SceneKit +x


def glow(name, color, strength):
    for m in bpy.data.materials:
        if name in m.name and m.node_tree:
            b = [nd for nd in m.node_tree.nodes if nd.type == 'BSDF_PRINCIPLED']
            if b:
                b[0].inputs['Emission Color'].default_value = (*color, 1)
                b[0].inputs['Emission Strength'].default_value = strength


cast = ORDERS[ORDER]
for src, name, x, s in cast:
    before = set(bpy.data.objects)
    bpy.ops.wm.usd_import(filepath=os.path.join(src, name + '.usdz'))
    new = [o for o in bpy.data.objects if o not in before]
    for t in [o for o in new if o.parent is None]:
        t.location.x += x
        t.scale = (s, s, s)
        if 'Tinky' in name: t.rotation_euler.z += math.pi
face = {'rest': 0, 'worried': 3, 'happy': 6, 'surprised': 9, 'scowl': 12, 'blink': 15}.get(POSE, 0)
pose_rolodex(face)
f2 = {'rest': 0, 'blink': 1, 'worried': 3, 'happy': 4, 'surprised': 6, 'scowl': 7}.get(POSE, 0)
for i in range(8):
    o = bpy.data.objects.get(f'rol2Card{i}')
    if o:
        o.rotation_euler.x = 0.0 if i == f2 else -0.45
MAPSIGN = float(os.environ.get("MAPSIGN", "1"))
unfold = 0.35 if POSE == 'unfold' else 0.0
for k in range(1, 6):
    o = bpy.data.objects.get(f'mapPanel{k}')
    if o: o.rotation_euler.y = MAPSIGN * (1 if k % 2 else -1) * (math.pi - 0.06) * (1 - unfold)
glow('tvGlow', (0.85, 0.95, 0.9), 2.5)
glow('tvScreenFace', (0.12, 0.2, 0.18), 0.6)
glow('stoveCoals', (1, 0.42, 0.08), 1.2)
if POSE == 'flash':
    glow('flashBulb0', (1, 1, 0.95), 25)
for m in bpy.data.materials:
    if m.node_tree and 'Glass' in m.name:
        b = [nd for nd in m.node_tree.nodes if nd.type == 'BSDF_PRINCIPLED']
        if b:
            b[0].inputs['Alpha'].default_value = 0.22
            if hasattr(m, 'blend_method'): m.blend_method = 'BLEND'
bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 4, 0)); fl = bpy.context.object
m = bpy.data.materials.new('floor'); m.use_nodes = True; m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.30, 0.27, 0.24, 1); fl.data.materials.append(m)
bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 2.2, 10), rotation=(math.pi / 2, 0, 0)); wl = bpy.context.object
m2 = bpy.data.materials.new('wall'); m2.use_nodes = True; m2.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.33, 0.33, 0.30, 1); wl.data.materials.append(m2)
cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); sc.collection.objects.link(cam); sc.camera = cam
if CAM == 'front':
    cam.data.type = 'ORTHO'; cam.data.ortho_scale = 5.6; cam.location = (0, -12, 0.75); cam.rotation_euler = (math.radians(88), 0, 0)
    resx, resy = 2400, 800
else:
    tx = float(CAM); cam.data.lens = 70
    cam.location = (tx + 0.35, -1.6, 0.75); cam.rotation_euler = (Vector((tx, 0, 0.3)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
    resx, resy = 800, 800


def light(loc, energy, size, color=(1, 0.95, 0.88)):
    d = bpy.data.lights.new('l', 'AREA'); d.energy = energy; d.size = size; d.color = color
    o = bpy.data.objects.new('l', d); sc.collection.objects.link(o); o.location = loc
    o.rotation_euler = (Vector((0, 0, 0.6)) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()


light((-4, -6, 6), 1300, 5); light((5, -5, 3), 380, 4, (0.85, 0.9, 1.0)); light((0, 3, 5), 500, 6)
w = bpy.data.worlds.new('w'); sc.world = w; w.use_nodes = True
w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.4, 0.37, 0.33, 1); w.node_tree.nodes['Background'].inputs['Strength'].default_value = 0.25
sc.render.engine = 'CYCLES'; sc.cycles.device = 'CPU'; sc.cycles.samples = 20
sc.view_settings.view_transform = 'Standard'
sc.render.resolution_x = resx; sc.render.resolution_y = resy
sc.render.filepath = os.path.join(OUT, f'{ORDER}_{CAM}_{POSE}.png'); bpy.ops.render.render(write_still=True)
