"""Hallwaysian kit -- shared Blender helpers for building living-object
characters and exporting them for SceneKit (Hallways).

Build in Blender's frame (Z up). Every character script:
    import hallwaysian_kit as K
    K.reset()
    root = K.joint('myRoot')                     # the exported default prim
    body = K.joint('myBody', (0, 0, 0.5), root)  # pivots are joints (empties)
    K.cyl(..., parent=body)                      # parts hang off joints
    K.export('Name', out_dir, face='+Z')         # SceneKit: Y up, facing +Z or -Z

Export contract (what the game's animation code relies on):
  * SceneKit frame baked into the data: Y up, metres, the character faces
    +Z (face='+Z', Blender -Y) or -Z (face='-Z', Blender +Y).
  * Every joint is an unrotated, unscaled node at its pivot; parts' rotations
    are baked into their meshes. Game code sets ABSOLUTE eulerAngles/scale.
  * Only constant materials survive (UsdPreviewSurface): stripes, labels and
    trims are geometry, not procedural textures.
"""
import bpy, bmesh, math, os, subprocess, sys
from mathutils import Vector, Matrix

_parents = {}

def reset():
    _parents.clear()
    bpy.ops.wm.read_factory_settings(use_empty=True)

# ---------------------------------------------------------------- materials
def mat(name, color, metal=0.0, rough=0.5, coat=0.0):
    m = bpy.data.materials.get(name)
    if m: return m
    m = bpy.data.materials.new(name); m.use_nodes = True
    b = m.node_tree.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value = (*color, 1)
    b.inputs['Metallic'].default_value = metal
    b.inputs['Roughness'].default_value = rough
    if coat: b.inputs['Coat Weight'].default_value = coat
    return m

def eye_materials():
    return (mat('hwEyeWhite', (0.93, 0.92, 0.88), rough=0.15),
            mat('hwPupil', (0.01, 0.01, 0.012), rough=0.06, coat=1))

# ---------------------------------------------------------------- structure
def joint(name, loc=(0, 0, 0), parent=None):
    o = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(o)
    o.location = loc
    if parent is not None: _parents[o.name] = parent.name
    return o

def own(o, parent, name=None):
    if name: o.name = name
    if parent is not None: _parents[o.name] = parent.name
    return o

def _finish(o, m, smooth=True, bevel=0.0, parent=None, name=None):
    if m: o.data.materials.append(m)
    if smooth and o.type == 'MESH':
        for p in o.data.polygons: p.use_smooth = True
    if bevel:
        bv = o.modifiers.new('bv', 'BEVEL'); bv.width = bevel; bv.segments = 2
    return own(o, parent, name)

# ---------------------------------------------------------------- shapes (world coordinates)
def sphere(loc, r, m, scale=(1, 1, 1), seg=24, ring=14, parent=None, name=None, **kw):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=seg, ring_count=ring, radius=r, location=loc)
    o = bpy.context.object; o.scale = scale
    return _finish(o, m, parent=parent, name=name, **kw)

def cyl(loc, r, depth, m, rot=(0, 0, 0), verts=24, scale=(1, 1, 1), parent=None, name=None, smooth=True, cap=True, **kw):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=depth, location=loc, rotation=rot,
                                        end_fill_type='NGON' if cap else 'NOTHING')
    o = bpy.context.object; o.scale = scale
    if smooth:   # smooth sides, flat caps
        _finish(o, m, smooth=True, parent=parent, name=name, **kw)
        o.data.set_sharp_from_angle(angle=math.radians(40)) if hasattr(o.data, 'set_sharp_from_angle') else None
        return o
    return _finish(o, m, smooth=False, parent=parent, name=name, **kw)

def cone(loc, r1, r2, depth, m, rot=(0, 0, 0), verts=24, parent=None, name=None, **kw):
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r1, radius2=r2, depth=depth, location=loc, rotation=rot)
    o = bpy.context.object
    _finish(o, m, parent=parent, name=name, **kw)
    if hasattr(o.data, 'set_sharp_from_angle'): o.data.set_sharp_from_angle(angle=math.radians(40))
    return o

def box(loc, size, m, rot=(0, 0, 0), bevel=0.004, parent=None, name=None):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    o = bpy.context.object; o.scale = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return _finish(o, m, smooth=False, bevel=bevel, parent=parent, name=name)

def torus(loc, R, r, m, rot=(0, 0, 0), maj=32, mino=10, parent=None, name=None):
    bpy.ops.mesh.primitive_torus_add(major_radius=R, minor_radius=r, location=loc, rotation=rot,
                                     major_segments=maj, minor_segments=mino)
    return _finish(bpy.context.object, m, parent=parent, name=name)

def rod(p0, p1, r, m, verts=12, parent=None, name=None, r1=None, **kw):
    p0, p1 = Vector(p0), Vector(p1); d = p1 - p0
    if r1 is None:
        o = cyl((p0 + p1) / 2, r, d.length, m, verts=verts, parent=parent, name=name, **kw)
    else:
        o = cone((p0 + p1) / 2, r, r1, d.length, m, verts=verts, parent=parent, name=name, **kw)
    o.rotation_mode = 'QUATERNION'; o.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(d.normalized())
    return o

def tube(points, r, m, parent=None, name='tube', res=6):
    """A swept tube through world points (converted to a mesh at export)."""
    cu = bpy.data.curves.new(name, 'CURVE'); cu.dimensions = '3D'
    cu.bevel_depth = r; cu.bevel_resolution = 2; cu.use_fill_caps = True
    sp = cu.splines.new('POLY'); sp.points.add(len(points) - 1)
    for i, p in enumerate(points): sp.points[i].co = (*p, 1)
    o = bpy.data.objects.new(name, cu); bpy.context.scene.collection.objects.link(o); cu.materials.append(m)
    return own(o, parent)

def helix(start, axis, length, radius, turns, wire, m, parent=None, name='spring', taper=0.0):
    a = Vector(axis).normalized(); s = Vector(start)
    u = a.orthogonal().normalized(); v = a.cross(u)
    n = max(8, int(turns * 12)); pts = []
    for i in range(n + 1):
        t = i / n; ang = 2 * math.pi * turns * t; rr = radius * (1 - taper * t)
        pts.append(tuple(s + a * (length * t) + u * (math.cos(ang) * rr) + v * (math.sin(ang) * rr)))
    return tube(pts, wire, m, parent, name)

def lathe(name, profile, m, center=(0, 0, 0), nu=32, parent=None, steps=3, cap_top=False, cap_bottom=False, wobble=None):
    """Surface of revolution. profile: [(z, rx, ry)] bottom->top (world z offsets from center)."""
    pts = []
    for k in range(len(profile) - 1):
        z0, a0, b0 = profile[k]; z1, a1, b1 = profile[k + 1]
        for s in range(steps):
            t = s / steps; e = t * t * (3 - 2 * t)
            pts.append((z0 + (z1 - z0) * t, a0 + (a1 - a0) * e, b0 + (b1 - b0) * e))
    pts.append(profile[-1])
    bm = bmesh.new(); rows = []
    for (z, rx, ry) in pts:
        row = []
        for i in range(nu):
            lon = 2 * math.pi * i / nu
            w = wobble(lon, z) if wobble else 1.0
            row.append(bm.verts.new((rx * w * math.cos(lon), ry * w * math.sin(lon), z)))
        rows.append(row)
    for j in range(len(rows) - 1):
        for i in range(nu):
            bm.faces.new((rows[j][i], rows[j][(i + 1) % nu], rows[j + 1][(i + 1) % nu], rows[j + 1][i]))
    if cap_bottom: bm.faces.new(list(reversed(rows[0])))
    if cap_top: bm.faces.new(rows[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name + 'Mesh'); bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new(name, me); bpy.context.scene.collection.objects.link(o); o.location = center
    return _finish(o, m, parent=parent)

def eye(center, r, lid_m, look=(0, -1, 0.05), lid=0.4, lid_tilt=0.0, pupil=0.55, parent=None, prefix='eye'):
    """Glossy eyeball facing `look`; an upper lid of `lid_m` closing `lid` (0..1), tilted (+ = outer side up)."""
    white, black = eye_materials()
    c = Vector(center); L = Vector(look).normalized()
    sphere(c, r, white, seg=28, ring=18, parent=parent, name=prefix + 'White')
    sphere(c + L * (r * 0.78), r * pupil, black, seg=20, ring=12, parent=parent, name=prefix + 'Pupil')
    if lid > 0:
        bm = bmesh.new(); bmesh.ops.create_uvsphere(bm, u_segments=28, v_segments=18, radius=r * 1.07)
        h = r * (1 - 2 * lid)
        # lid plane normal: mostly up, leaning toward the look direction, tilted sideways
        n = (Vector((0, 0, 1)) * math.cos(lid_tilt) + Vector((1, 0, 0)) * math.sin(lid_tilt) - L * 0.15).normalized()
        bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=n * h, plane_no=n, clear_inner=True)
        me = bpy.data.meshes.new(prefix + 'LidMesh'); bm.to_mesh(me); bm.free()
        o = bpy.data.objects.new(prefix + 'Lid', me); bpy.context.scene.collection.objects.link(o); o.location = c
        _finish(o, lid_m, parent=parent)
        sol = o.modifiers.new('s', 'SOLIDIFY'); sol.thickness = r * 0.07

# ---------------------------------------------------------------- export
def _world(o):
    return o.matrix_world.copy()

def export(name, out_dir, face='+Z', root_name=None):
    """Bake to SceneKit's frame and write <out_dir>/<name>.usdz (+ .usda, .blend)."""
    os.makedirs(out_dir, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out_dir, name + '.blend'))
    sc = bpy.context.scene
    # curves -> meshes
    for o in list(sc.objects):
        if o.type == 'CURVE':
            dg = bpy.context.evaluated_depsgraph_get()
            me = bpy.data.meshes.new_from_object(o.evaluated_get(dg))
            m = bpy.data.objects.new(o.name + 'M', me); sc.collection.objects.link(m)
            m.matrix_world = o.matrix_world
            for mt in o.data.materials: me.materials.append(mt)
            for p in me.polygons: p.use_smooth = True
            if o.name in _parents: _parents[m.name] = _parents.pop(o.name)
            bpy.data.objects.remove(o)
    bpy.context.view_layer.update()
    worlds = {o.name: _world(o) for o in sc.objects}
    # joints must be unrotated/unscaled
    for o in sc.objects:
        if o.type == 'EMPTY':
            q = worlds[o.name].to_quaternion()
            if abs(q.w) < 0.99999:
                raise SystemExit(f'joint {o.name} is rotated')
    # flatten: meshes get their world rotation/scale baked into data
    for o in sc.objects:
        o.parent = None
    for o in sc.objects:
        W = worlds[o.name]
        if o.type == 'MESH':
            o.data.transform(W.to_3x3().to_4x4())
        o.matrix_world = Matrix.Translation(W.to_translation())
    # hierarchy back (pure translations)
    for child, par in _parents.items():
        c = sc.objects.get(child); p = sc.objects.get(par)
        if c is None or p is None: continue
        c.parent = p; c.matrix_parent_inverse = Matrix.Identity(4)
        c.location = worlds[child].to_translation() - worlds[par].to_translation()
    bpy.context.view_layer.update()
    # Blender (x, y, z) -> SceneKit (x, z, -y): Blender -Y becomes SceneKit +Z.
    # A '+Z' character is built facing Blender -Y; a '-Z' one facing Blender +Y.
    M = Matrix(((1, 0, 0, 0), (0, 0, 1, 0), (0, -1, 0, 0), (0, 0, 0, 1)))
    for o in sc.objects:
        if o.type == 'MESH':
            o.data.transform(M); o.data.update()
        o.location = (M @ o.location.to_4d()).to_3d()
    for o in sc.objects: o.select_set(True)
    usda = os.path.join(out_dir, name + '.usda')
    bpy.ops.wm.usd_export(filepath=usda, export_materials=True, generate_preview_surface=True, export_uvmaps=False,
                          convert_orientation=False, export_subdivision='IGNORE', evaluation_mode='RENDER',
                          export_lights=False, export_cameras=False, root_prim_path='')
    dg = bpy.context.evaluated_depsgraph_get(); tris = 0
    for o in sc.objects:
        if o.type == 'MESH':
            me = o.evaluated_get(dg).to_mesh(); me.calc_loop_triangles(); tris += len(me.loop_triangles); o.evaluated_get(dg).to_mesh_clear()
    pkg = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'package.py')
    subprocess.run([sys.executable if 'python' in sys.executable else 'python3', pkg, usda, os.path.join(out_dir, name + '.usdz')], check=True)
    print('EXPORTED', name, 'triangles', tris, 'objects', len(sc.objects))
