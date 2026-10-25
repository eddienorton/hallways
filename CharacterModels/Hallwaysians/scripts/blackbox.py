"""The Black Box -- body only (the face is light, drawn by the game behind
the glass). Blender frame: Z up, front = -Y (SceneKit +Z after export).
Origin = centre of the underside. About 0.28 m on a side.

Run: blender-python blackbox.py <out_dir>
"""
import sys, math, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy, bmesh
import hallwaysian_kit as K

OUT = sys.argv[-1] if len(sys.argv) > 1 and not sys.argv[-1].endswith('.py') else '/tmp/claude-0/hw/out_bb'

W = 0.28            # body width / depth
PLINTH_H = 0.012    # the shadow-gap foot
SEAM_Z = 0.05       # the casting seam, low on the sides
TOP_Z = 0.29
VISOR_W, VISOR_H, VISOR_R, VISOR_D = 0.206, 0.152, 0.034, 0.006
VISOR_Z = 0.166
GRILLE_R = 0.082


def mats():
    return dict(
        body=K.mat('bbMagnesium', (0.018, 0.018, 0.021), metal=0.25, rough=0.52),
        gap=K.mat('bbGap', (0.004, 0.004, 0.005), rough=0.9),
        glass=K.mat('bbGlass', (0.003, 0.003, 0.005), rough=0.06, coat=1.0),
        grille=K.mat('bbGrille', (0.014, 0.014, 0.016), metal=0.2, rough=0.75),
        foot=K.mat('bbFoot', (0.010, 0.010, 0.011), rough=0.85),
    )


def rounded_slab(name, w, h, depth, r, segs=8):
    """A slab w (x) by h (z), `depth` along y, rounded only in the x-z plane."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co.x *= w; v.co.y *= depth; v.co.z *= h
    edges = [e for e in bm.edges if abs(e.verts[0].co.y - e.verts[1].co.y) > 1e-6]
    bmesh.ops.bevel(bm, geom=edges, offset=r, segments=segs, affect='EDGES', profile=0.5)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(o)
    return o


def apply_all(o):
    bpy.context.view_layer.objects.active = o
    for m in list(o.modifiers):
        bpy.ops.object.modifier_apply(modifier=m.name)


def cut(target, cutter):
    bm = target.modifiers.new('cut', 'BOOLEAN')
    bm.operation = 'DIFFERENCE'; bm.solver = 'EXACT'; bm.object = cutter
    apply_all(target)
    bpy.data.objects.remove(cutter)


def build():
    K.reset()
    M = mats()
    root = K.joint('bbModel')

    # The foot: a slightly inset dark block, so the cube seems to float a hair
    # above the desk on a line of shadow.
    K.box((0, 0, PLINTH_H / 2 + 0.001), (W - 0.04, W - 0.04, PLINTH_H), M['foot'], bevel=0.002, parent=root, name='bbFoot')

    # The core that shows in the seam.
    K.box((0, 0, SEAM_Z), (W - 0.008, W - 0.008, 0.03), M['gap'], bevel=0.0, parent=root, name='bbSeamCore')

    # Lower casting.
    low = K.box((0, 0, (PLINTH_H + SEAM_Z - 0.001) / 2), (W, W, SEAM_Z - 0.001 - PLINTH_H), M['body'], bevel=0.0)
    bv = low.modifiers.new('bv', 'BEVEL'); bv.width = 0.006; bv.segments = 3
    apply_all(low)
    K.own(low, root, 'bbLower')

    # Upper casting (most of the body), with the face recess and the top grille.
    up_h = TOP_Z - (SEAM_Z + 0.001)
    up = K.box((0, 0, SEAM_Z + 0.001 + up_h / 2), (W, W, up_h), M['body'], bevel=0.0)
    bv = up.modifiers.new('bv', 'BEVEL'); bv.width = 0.008; bv.segments = 3
    apply_all(up)
    visor_cut = rounded_slab('visorCut', VISOR_W, VISOR_H, 0.04, VISOR_R)
    visor_cut.location = (0, -W / 2 - 0.02 + VISOR_D, VISOR_Z)
    cut(up, visor_cut)
    bpy.ops.mesh.primitive_cylinder_add(radius=GRILLE_R, depth=0.02, vertices=64, location=(0, 0.0, TOP_Z + 0.01 - 0.004))
    gc = bpy.context.object
    cut(up, gc)
    # Three small vent slots on the back.
    for k in range(3):
        bpy.ops.mesh.primitive_cube_add(size=1, location=(-0.05 + 0.05 * k, W / 2, 0.12))
        s = bpy.context.object; s.scale = (0.012, 0.012, 0.09)
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        cut(up, s)
    up.data.materials.append(M['body'])
    for p in up.data.polygons:
        p.use_smooth = False
    K.own(up, root, 'bbShell')
    # Vent slot backs.
    for k in range(3):
        K.box((-0.05 + 0.05 * k, W / 2 - 0.005, 0.12), (0.011, 0.002, 0.089), M['gap'], bevel=0.0, parent=root, name=f'bbVent{k}')

    # The glass the face lives behind: the floor of the recess.
    glass = rounded_slab('bbVisor', VISOR_W - 0.002, VISOR_H - 0.002, 0.002, VISOR_R - 0.001)
    glass.location = (0, -W / 2 + VISOR_D - 0.001, VISOR_Z)
    glass.data.materials.append(M['glass'])
    for p in glass.data.polygons:
        p.use_smooth = False
    K.own(glass, root, 'bbVisor')

    # The top grille: a dark disc with three fine rings.
    bpy.ops.mesh.primitive_cylinder_add(radius=GRILLE_R - 0.0005, depth=0.002, vertices=64, location=(0, 0, TOP_Z - 0.004 + 0.001))
    g = bpy.context.object
    K._finish(g, M['grille'], smooth=False, parent=root, name='bbGrille')
    for R in (0.026, 0.048, 0.068):
        K.torus((0, 0, TOP_Z - 0.0028), R, 0.0016, M['body'], maj=64, mino=6, parent=root, name=f'bbRing{int(R*1000)}')
    return root


if __name__ == '__main__':
    build()
    K.export('BlackBox', OUT, face='+Z')
