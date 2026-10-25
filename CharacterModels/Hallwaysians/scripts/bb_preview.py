"""Black Box expression sheet: the exported USDZ re-imported, with the face
sprites placed exactly as BlackBox.swift places them (SceneKit -> Blender:
(x, y, z) -> (x, -z, y))."""
import bpy, math, sys, os
from mathutils import Vector
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bb_face import sprite, AMBER, BLUSH

SRC = '/tmp/claude-0/hw/out_bb'
OUT = sys.argv[sys.argv.index('--out') + 1] if '--out' in sys.argv else SRC
MODE = sys.argv[sys.argv.index('--mode') + 1] if '--mode' in sys.argv else 'sheet'

# Face layout (SceneKit, metres; must match BlackBoxFace in Swift).
VISOR_Y = 0.166
FACE_Z = 0.1375
EYE_X, EYE_Y = 0.046, 0.010
EYE_W, EYE_H = 0.030, 0.050
BROW_Y, BROW_W, BROW_H = 0.050, 0.030, 0.007
MOUTH_Y = -0.040
SMILE_W, SMILE_H = 0.056, 0.021
MOUTH_W, MOUTH_H = 0.032, 0.024
BLUSH_X, BLUSH_Y, BLUSH_W, BLUSH_H = 0.074, -0.022, 0.034, 0.018

TEX = {}


def tex(kind):
    if kind not in TEX:
        p = os.path.join(SRC, 'face', kind + '.png')
        im = sprite(kind, color=BLUSH if kind == 'blush' else AMBER)
        im.save(p)
        TEX[kind] = (bpy.data.images.load(p), im.size)
    return TEX[kind]


def B(x, y, z):
    return Vector((x, -z, y))


def glow_mat(kind, strength=3.0, opacity=1.0):
    img, _ = tex(kind)
    m = bpy.data.materials.new(kind)
    m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    ti = nt.nodes.new('ShaderNodeTexImage'); ti.image = img
    em = nt.nodes.new('ShaderNodeEmission'); em.inputs['Strength'].default_value = strength
    tr = nt.nodes.new('ShaderNodeBsdfTransparent')
    mix = nt.nodes.new('ShaderNodeMixShader')
    mul = nt.nodes.new('ShaderNodeMath'); mul.operation = 'MULTIPLY'; mul.inputs[1].default_value = opacity
    nt.links.new(ti.outputs['Color'], em.inputs['Color'])
    nt.links.new(ti.outputs['Alpha'], mul.inputs[0])
    nt.links.new(mul.outputs[0], mix.inputs['Fac'])
    nt.links.new(tr.outputs[0], mix.inputs[1])
    nt.links.new(em.outputs[0], mix.inputs[2])
    nt.links.new(mix.outputs[0], out.inputs['Surface'])
    m.blend_method = 'BLEND' if hasattr(m, 'blend_method') else None
    return m


def pad_frac(kind):
    _, (w, h) = tex(kind)
    p = int(min(w, h) * 0.22)
    return (w / (w - 2 * p), h / (h - 2 * p))


def face_plane(parent, kind, cx, cy, w, h, layer, rot=0.0, opacity=1.0, strength=3.0):
    fx, fy = pad_frac(kind) if kind not in ('smile', 'happy', 'ring') else (1.0, 1.0)
    bpy.ops.mesh.primitive_plane_add(size=1)
    o = bpy.context.object
    o.scale = (w * fx, h * fy, 1)
    o.rotation_euler = (math.pi / 2, 0, 0)
    o.rotation_euler.rotate_axis('Z', 0)
    o.location = B(cx, VISOR_Y + cy, FACE_Z + 0.0004 * layer)
    if rot:
        o.rotation_euler = (math.pi / 2, rot, 0)
    o.data.materials.append(glow_mat(kind, strength, opacity))
    o.parent = parent
    return o


EXPR = {
    'idle':        dict(eyes=('eye', 0.0, 0.0, 1.0), brows=None, mouth=('smile', 0.7), blush=0),
    'look-left':   dict(eyes=('eye', -0.012, 0.002, 0.95), brows=None, mouth=('smile', 0.5), blush=0),
    'concentrate': dict(eyes=('eye', 0.006, 0.006, 0.42), brows=(0.0, 0.32, 1.0), mouth=('mouth', 0.25), blush=0),
    'bright':      dict(eyes=('eye', 0.0, 0.004, 1.12), brows=(0.008, -0.18, 1.0), mouth=('mouth', 1.0), blush=0),
    'bliss':       dict(eyes=('happy', 0.0, 0.0, 1.0), brows=None, mouth=('mouth', 0.7), blush=0.5),
    'pleased':     dict(eyes=('happy', 0.0, 0.0, 1.0), brows=None, mouth=('smile', 1.0), blush=0.9),
    'embarrassed': dict(eyes=('eye', -0.014, -0.010, 0.55), brows=(0.002, -0.25, 1.0), mouth=('smile', 0.35), blush=1.0),
    'sleepy':      dict(eyes=('eye', 0.0, -0.012, 0.16), brows=None, mouth=None, blush=0),
}


def build_face(root, e):
    kind, dx, dy, sy = e['eyes']
    for side in (-1, 1):
        if kind == 'eye':
            face_plane(root, 'eye', side * EYE_X + dx, EYE_Y + dy - EYE_H * (1 - sy) * 0.25, EYE_W, EYE_H * sy, 1)
        else:
            face_plane(root, 'happy', side * EYE_X + dx, EYE_Y + dy + 0.004, 0.050, 0.028, 1)
    if e['brows']:
        by, ang, op = e['brows']
        for side in (-1, 1):
            face_plane(root, 'brow', side * EYE_X + dx * 0.5, BROW_Y + by, BROW_W, BROW_H, 1, rot=-side * ang, opacity=op)
    if e['mouth']:
        k, amt = e['mouth']
        if k == 'smile':
            face_plane(root, 'smile', dx * 0.4, MOUTH_Y + 0.004, SMILE_W * (0.6 + 0.4 * amt), SMILE_H * (0.5 + 0.5 * amt), 1)
        else:
            face_plane(root, 'mouth', dx * 0.4, MOUTH_Y, MOUTH_W * (0.8 + 0.25 * amt), MOUTH_H * max(0.2, amt), 1)
    if e['blush']:
        for side in (-1, 1):
            face_plane(root, 'blush', side * BLUSH_X, BLUSH_Y, BLUSH_W, BLUSH_H, 0, opacity=e['blush'], strength=1.4)


def scene_base():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'; sc.cycles.device = 'CPU'; sc.cycles.samples = 32
    sc.view_settings.view_transform = 'Standard'
    w = bpy.data.worlds.new('w'); sc.world = w; w.use_nodes = True
    w.node_tree.nodes['Background'].inputs['Color'].default_value = (0.42, 0.40, 0.37, 1)
    w.node_tree.nodes['Background'].inputs['Strength'].default_value = 0.5
    return sc


def import_box(loc=(0, 0, 0), yaw=0.0):
    before = set(bpy.data.objects)
    bpy.ops.wm.usd_import(filepath=os.path.join(SRC, 'BlackBox.usdz'))
    new = [o for o in bpy.data.objects if o not in before]
    tops = [o for o in new if o.parent is None]
    for t in tops:
        t.location = Vector(loc); t.rotation_euler.z += yaw
    return tops[0]


def light(sc, loc, target, e, size):
    d = bpy.data.lights.new('l', 'AREA'); d.energy = e; d.size = size
    o = bpy.data.objects.new('l', d); sc.collection.objects.link(o); o.location = loc
    o.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()


def sheet():
    sc = scene_base()
    sc.render.resolution_x, sc.render.resolution_y = 520, 520
    bpy.ops.mesh.primitive_plane_add(size=30)
    fl = bpy.context.object
    m = bpy.data.materials.new('desk'); m.use_nodes = True
    m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.42, 0.30, 0.19, 1)
    m.node_tree.nodes['Principled BSDF'].inputs['Roughness'].default_value = 0.45
    fl.data.materials.append(m)
    light(sc, (-0.6, -0.9, 1.0), (0, 0, 0.15), 60, 0.8)
    light(sc, (0.8, -0.4, 0.5), (0, 0, 0.15), 18, 0.6)
    light(sc, (0.0, 0.9, 0.8), (0, 0, 0.15), 30, 1.0)
    cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); sc.collection.objects.link(cam); sc.camera = cam
    cam.data.lens = 50
    shots = []
    names = list(EXPR) if MODE == 'sheet' else [MODE]
    for name in names:
        # fresh box each time
        for o in [o for o in bpy.data.objects if o.name.startswith('bb') or o.type == 'MESH' and o != fl]:
            bpy.data.objects.remove(o, do_unlink=True)
        root = import_box()
        build_face(root, EXPR[name])
        ang = math.radians(-22 if name != 'look-left' else -10)
        r = 0.95
        cam.location = (math.sin(ang) * r, -math.cos(ang) * r, 0.42)
        cam.rotation_euler = (Vector((0, 0, 0.15)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
        sc.render.filepath = os.path.join(OUT, f'expr-{name}.png')
        bpy.ops.render.render(write_still=True)
        shots.append((name, sc.render.filepath))
    from PIL import Image, ImageDraw
    ims = [Image.open(p) for _, p in shots]
    cols = 4
    rows = (len(ims) + cols - 1) // cols
    W, H = ims[0].size
    out = Image.new('RGB', (W * cols, H * rows), (30, 30, 30))
    for i, (im, (name, _)) in enumerate(zip(ims, shots)):
        out.paste(im, ((i % cols) * W, (i // cols) * H))
        ImageDraw.Draw(out).text(((i % cols) * W + 10, (i // cols) * H + 8), name, fill=(255, 255, 255))
    out.save(os.path.join(OUT, 'blackbox-expressions.png'))


if __name__ == '__main__':
    os.makedirs(os.path.join(SRC, 'face'), exist_ok=True)
    sheet()
