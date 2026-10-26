# Bake rigged glTF characters (e.g. KayKit, CC0) into sprite clips for themes/engine.lua.
#
#   PYTHONPATH=<dir with numpy> blender -b -P tools/bake/kaykit.py -- <recipe.json> <out_dir> [size]
#
# Blender's glTF importer needs numpy; Ubuntu's blender has none, so e.g.
#   python3 -m pip install --target ~/assets-src/pylib "numpy<2.1"
#
# Recipe (paths relative to the recipe file):
#   {"model": "Skeleton_Minion.glb", "hide": ["Icosphere"], "outline": 0.012,
#    "clips": {
#      "walk":  {"action": "Walking_D_Skeletons", "yaw": 90, "loop": true, "stride": "auto"},
#      "turn":  {"action": "Idle", "yaw": [90, 15], "frames": 8, "loop": false},
#      "cheer": {"action": "Cheer", "yaw": 15, "loop": false, "step": 1}}}
#
# More recipe keys:
#   "parts":   [{"model": "Knight.glb", "meshes": ["Knight_Head"]}]  meshes from another model on the
#              same rig (KayKit Rig_Medium), e.g. a different head
#   "recolor": {"mage_texture": {"0,1": "#26232b", ...}}  repaint KayKit palette swatches (column,row
#              of the 8×4 texture grid), keeping each swatch's shading
#   "frame":   {"x": [lo, hi], "h": units}  fixed framing (world units) instead of the union of all
#              poses; bakes with the same "h" share a scale (see "unit" in theme.json)
#   "bone_scale": {"head": 0.8, "upperleg.l": [1, 1.3, 1]}  scale bones in every pose (a smaller
#              head, longer legs: less of a toy); the feet are put back on the ground
#   per clip "hold": {"from": "Interact", "frame": 10, "bones": ["upperarm.r", ...]}  freeze those
#              bones in the pose of another action (e.g. arms forward while walking = pushing);
#              a list of such holds combines several
#   per clip "turn": {"upperarm.l": [x, y, z]}  turn bones further (degrees, the bone's own axes) on
#              top of the animation (and holds): arms straight out, a tilted head
#   per clip "ramp": [0, 1]  the "turn"s faded in (or out) over the clip, eased: a pose taken up
#              gradually (down on all fours over a second)
#   per clip "lift": -0.15  or [from, to]: the figure lower (higher) by that many units, e.g. its
#              knees bent: the feet back on the ground
#   per clip "speed": 0.6  play slower (or faster): fps, and so the walking speed, scaled
#   "shell":   {"meshes": [...], "thickness": 0.05, "color": "#e6dfc8", "stripe": "#a99d82"}  a
#              bandage wrapping over those meshes (a mummy); per clip "wrap": 1 wrapped (default),
#              0 bare, [from, to] (un)wrapping during the clip: the bandage shows below a level
#              that rises from the feet to the head (with a spiral edge)
#   per clip "only": ["Knight_Head", "prop"]  render only the meshes whose names contain one of these
#   per clip "show": ["2H_Staff"]  show meshes "hide" hides everywhere else (a stick for stirring)
#   per clip "drop": ["prop"]  hide these meshes in this clip (a pumpkin-head without its head)
#   per clip "track": {"hand.r": [0, 0, 0]}  where these bones (plus a world offset) are in each
#              frame, in render pixels: clips.json "track" (the engine carries something along)
#   per clip "spin": true  turn what shows about its own middle, a full turn over the clip's frames
#              (in the picture plane): pieces flying off
#   "props":   [{"bone": "head", "at": [0.3, 0, 0.1], "size": [0.05, 0.2], "axis": "x", "color": "#999"}]
#              simple shapes riding on a bone (neck bolts), see below
#   "heap":    {"color": "#e6dfc8"}  a pile of bandage at the feet; per clip "heap": 0 (default),
#              1 or [from, to] (its size)
#
# yaw 0 = facing the viewer, 90 = walking to the right. A [from, to] yaw turns during the clip.
# The camera is orthographic, level, and identical for all clips (framed on the union of all
# poses) with its bottom edge on the ground plane, so "rising from the ground" clips are cut at
# ground level, and the sprite's bottom edge is where the feet stand.
# Writes <out_dir>/<clip>_NNNN.png and clips.json (same format as spider.py, plus "unit_px": render
# pixels per world unit and "origin_px": where world x=0 on the ground is in the render).

import bpy, json, math, os, sys
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
RECIPE = os.path.abspath(argv[0])
OUT = os.path.abspath(argv[1])
SIZE = int(argv[2]) if len(argv) > 2 else 384
R = json.load(open(RECIPE))
BASE = os.path.dirname(RECIPE)
FPS = 24

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=os.path.join(BASE, R["model"]))
scene = bpy.context.scene

rig = next(o for o in scene.objects if o.type == "ARMATURE")

for part in R.get("parts", []):
    before = set(scene.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(BASE, part["model"]))
    for o in [o for o in scene.objects if o not in before]:
        if o.type == "MESH" and o.name.split(".")[0] in part["meshes"]:
            mw = o.matrix_world.copy()
            o.parent = rig
            o.matrix_world = mw
            for m in o.modifiers:
                if m.type == "ARMATURE":
                    m.object = rig
        else:
            bpy.data.objects.remove(o, do_unlink=True)

if R.get("recolor"):
    import numpy as np

    def recolor(img, cells):
        w, h = img.size
        px = np.empty(w * h * 4, np.float32)
        img.pixels.foreach_get(px)
        px = px.reshape(h, w, 4)
        for cr, col in cells.items():
            c, r = (int(v) for v in cr.split(","))
            y0, y1, x0, x1 = h - (r + 1) * h // 4, h - r * h // 4, c * w // 8, (c + 1) * w // 8
            lum = px[y0:y1, x0:x1, :3] @ np.array([0.299, 0.587, 0.114], np.float32)
            tgt = np.array([int(col[i:i + 2], 16) / 255 for i in (1, 3, 5)], np.float32)
            px[y0:y1, x0:x1, :3] = np.clip(tgt * (lum / max(1e-3, lum.mean()))[..., None], 0, 1)
        img.pixels.foreach_set(px.ravel())
        img.update()

    for key, cells in R["recolor"].items():
        for img in bpy.data.images:
            if key in img.name:
                recolor(img, cells)

meshes = [o for o in scene.objects if o.type == "MESH"]
for o in meshes:
    if any(h in o.name for h in R.get("hide", [])):
        o.hide_render = True
showable = {n for c in R["clips"].values() for n in c.get("show", [])}
meshes = [o for o in meshes if not o.hide_render or any(n in o.name for n in showable)]

def hexrgb(h):
    return [(int(h[i:i + 2], 16) / 255) ** 2.2 for i in (1, 3, 5)]


SHELL, HEAP = R.get("shell"), R.get("heap")
level_nodes, shell_objs = [], []


def bandage_mat(name, base, stripe=None, clip=True):
    """Flat cloth; with stripe: diagonal bands. clip: only below the level (world z), whose edge
    climbs around the body (a spiral as the level moves)."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt, N = m.node_tree, m.node_tree.nodes
    bsdf = N["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 1
    if stripe:
        tc, wave, ramp = N.new("ShaderNodeTexCoord"), N.new("ShaderNodeTexWave"), N.new("ShaderNodeValToRGB")
        wave.wave_type, wave.bands_direction = "BANDS", "DIAGONAL"
        wave.inputs["Scale"].default_value = SHELL.get("stripes", 5)
        wave.inputs["Distortion"].default_value = 1.5
        nt.links.new(tc.outputs["Object"], wave.inputs["Vector"])
        ramp.color_ramp.elements[0].color = (*hexrgb(stripe), 1)
        ramp.color_ramp.elements[1].color = (*hexrgb(base), 1)
        ramp.color_ramp.elements[0].position, ramp.color_ramp.elements[1].position = 0.2, 0.45
        nt.links.new(wave.outputs["Fac"], ramp.inputs["Fac"])
        nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    else:
        bsdf.inputs["Base Color"].default_value = (*hexrgb(base), 1)
    if clip:
        m.blend_method, m.shadow_method = "CLIP", "CLIP"
        geo, sep = N.new("ShaderNodeNewGeometry"), N.new("ShaderNodeSeparateXYZ")
        nt.links.new(geo.outputs["Position"], sep.inputs[0])
        neg = N.new("ShaderNodeMath"); neg.operation = "MULTIPLY"; neg.inputs[1].default_value = -1
        nt.links.new(sep.outputs["Y"], neg.inputs[0])
        ang = N.new("ShaderNodeMath"); ang.operation = "ARCTAN2"    # the seam at the back
        nt.links.new(sep.outputs["X"], ang.inputs[0]); nt.links.new(neg.outputs[0], ang.inputs[1])
        wig = N.new("ShaderNodeMath"); wig.operation = "MULTIPLY"; wig.inputs[1].default_value = SHELL.get("edge", 0.04)
        nt.links.new(ang.outputs[0], wig.inputs[0])
        lvl = N.new("ShaderNodeValue"); lvl.outputs[0].default_value = 100.0
        add = N.new("ShaderNodeMath"); add.operation = "ADD"
        nt.links.new(lvl.outputs[0], add.inputs[0]); nt.links.new(wig.outputs[0], add.inputs[1])
        lt = N.new("ShaderNodeMath"); lt.operation = "LESS_THAN"
        nt.links.new(sep.outputs["Z"], lt.inputs[0]); nt.links.new(add.outputs[0], lt.inputs[1])
        nt.links.new(lt.outputs[0], bsdf.inputs["Alpha"])
        level_nodes.append(lvl)
    return m


if SHELL:
    import bmesh
    cloth = bandage_mat("bandage", SHELL.get("color", "#e6dfc8"), SHELL.get("stripe", "#a99d82"))
    for o in list(meshes):
        if o.name.split(".")[0] in SHELL["meshes"]:
            c = o.copy()
            c.data = o.data.copy()
            c.name = o.name + "_shell"
            scene.collection.objects.link(c)
            bm = bmesh.new()
            bm.from_mesh(c.data)
            bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-4)   # one skin: no gaps when inflated
            bm.to_mesh(c.data)
            bm.free()
            c.data.materials.clear()
            c.data.materials.append(cloth)
            for poly in c.data.polygons:
                poly.material_index = 0
                poly.use_smooth = True
            d = c.modifiers.new("inflate", "DISPLACE")   # after the armature: along the posed normals
            d.direction, d.strength, d.mid_level = "NORMAL", SHELL.get("thickness", 0.05), 0.0
            shell_objs.append(c)
    meshes += shell_objs
    body_top = max((o.matrix_world @ v.co).z for o in meshes for v in o.data.vertices)

# props: simple shapes riding on a bone (neck bolts), placed in the rest pose relative to the
# bone's head: {"bone": "head", "at": [x, y, z], "shape": "cylinder", "size": [radius, length],
# "axis": "x", "color": "#..."}  (or "shape": "cube", "size": [sx, sy, sz]; "shape": "sphere",
# "size": [rx, ry, rz]; "shape": "cone", "size": [radius, length], pointing up; both turned by
# "rot": [x, y, z] degrees)
for i, pr in enumerate(R.get("props", [])):
    b = rig.data.bones[pr["bone"]]
    at = rig.matrix_world @ b.head_local + Vector(pr.get("at", [0, 0, 0]))
    if pr.get("shape", "cylinder") == "cube":
        bpy.ops.mesh.primitive_cube_add(size=1, location=at)
        o = bpy.context.object
        o.scale = pr["size"]
    elif pr["shape"] in ("cone", "sphere"):
        if pr["shape"] == "cone":
            r, ln = pr["size"]
            bpy.ops.mesh.primitive_cone_add(radius1=r, radius2=0, depth=ln, vertices=12, location=at)
        else:
            bpy.ops.mesh.primitive_uv_sphere_add(radius=1, segments=20, ring_count=10, location=at)
            bpy.context.object.scale = pr["size"]
        o = bpy.context.object
        o.rotation_euler = [math.radians(v) for v in pr.get("rot", [0, 0, 0])]
    else:
        r, ln = pr["size"]
        bpy.ops.mesh.primitive_cylinder_add(radius=r, depth=ln, vertices=16, location=at)
        o = bpy.context.object
        o.rotation_euler = {"x": (0, math.pi / 2, 0), "y": (math.pi / 2, 0, 0), "z": (0, 0, 0)}[pr.get("axis", "x")]
    o.name = f"prop{i}"
    bpy.context.view_layer.update()
    m = bpy.data.materials.new(o.name)
    m.use_nodes = True
    m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*hexrgb(pr.get("color", "#808080")), 1)
    m.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.6
    o.data.materials.append(m)
    mw = o.matrix_world.copy()
    o.parent, o.parent_type, o.parent_bone = rig, "BONE", pr["bone"]
    bpy.context.view_layer.update()
    o.matrix_world = mw
    meshes.append(o)

# Turntable parent so yaw does not fight the imported rig transform.
pivot = bpy.data.objects.new("pivot", None)
scene.collection.objects.link(pivot)
for o in scene.objects:
    if o.parent is None and o is not pivot:
        o.parent = pivot

heap = None
if HEAP:
    pile = bandage_mat("heap", HEAP.get("color", "#e6dfc8"), clip=False)
    rings = []
    for k, (r, x, y, z) in enumerate([(0.42, 0, 0, 0.05), (0.34, 0.08, -0.04, 0.13), (0.26, -0.06, 0.02, 0.2),
                                      (0.2, 0.1, 0.05, 0.27), (0.3, -0.1, -0.05, 0.09)]):
        bpy.ops.mesh.primitive_torus_add(major_radius=r, minor_radius=0.075, location=(x, y - 0.15, z),
                                         rotation=(math.radians(8 * (k % 3 - 1)), math.radians(6 * (k % 2)), 0))
        rings.append(bpy.context.active_object)
    for o in rings:
        o.select_set(True)
    bpy.context.view_layer.objects.active = rings[0]
    bpy.ops.object.join()
    heap = rings[0]
    heap.name = "heap"
    heap.data.materials.append(pile)
    heap.hide_render = True
    meshes.append(heap)

actions = {a.name: a for a in bpy.data.actions}

# bone_scale: drop the bones' scale keys everywhere, then the pose scale stays put
for bone, sc in R.get("bone_scale", {}).items():
    paths = (f'pose.bones["{bone}"].scale',)
    for a in actions.values():
        for fc in [fc for fc in a.fcurves if fc.data_path in paths]:
            a.fcurves.remove(fc)
    rig.pose.bones[bone].scale = (sc, sc, sc) if isinstance(sc, (int, float)) else sc


def action(name):
    return actions.get(name) or actions.get(name + "_Rig") or next(a for n, a in actions.items() if n.startswith(name))


def held(c):
    """The clip's action, or a copy with some bones frozen in the pose of another action."""
    a = action(c["action"])
    holds = c.get("hold")
    if not holds:
        return a
    b = a.copy()
    for h in holds if isinstance(holds, list) else [holds]:
        src, f = action(h["from"]), h.get("frame", 0)
        paths = [f'pose.bones["{n}"].{k}' for n in h["bones"] for k in ("rotation_quaternion", "location", "scale")]
        for fc in [fc for fc in b.fcurves if fc.data_path in paths]:
            b.fcurves.remove(fc)
        for fc in src.fcurves:
            if fc.data_path in paths:
                nf = b.fcurves.new(fc.data_path, index=fc.array_index)
                nf.keyframe_points.insert(a.frame_range[0], fc.evaluate(f))
    return b


def turned(a, c):
    """The action with some bones turned further (per clip "turn": {bone: [x, y, z] degrees}, on
    top of the animation, in the bone's own axes), keyed on every frame."""
    turns = c.get("turn")
    if not turns:
        return a
    from mathutils import Euler, Quaternion
    b = a.copy()
    f0, f1 = (int(round(x)) for x in a.frame_range)
    r0, r1 = c.get("ramp", [1, 1])
    for bone, deg in turns.items():
        path = f'pose.bones["{bone}"].rotation_quaternion'
        old = {fc.array_index: fc for fc in b.fcurves if fc.data_path == path}
        qs = []
        for f in range(f0, f1 + 1):
            q = Quaternion([old[i].evaluate(f) if i in old else (1, 0, 0, 0)[i] for i in range(4)])
            k = r0 + (r1 - r0) * (0.5 - 0.5 * math.cos(math.pi * (f - f0) / max(1, f1 - f0)))
            qs.append(q @ Euler([math.radians(v * k) for v in deg]).to_quaternion())
        for fc in old.values():
            b.fcurves.remove(fc)
        for i in range(4):
            nf = b.fcurves.new(path, index=i, action_group=bone)
            for k, q in enumerate(qs):
                nf.keyframe_points.insert(f0 + k, q[i])
    return b


def clip_frames(c):
    """[(action_frame, yaw_deg)] for one clip."""
    a = turned(held(c), c)
    f0, f1 = (int(round(x)) for x in a.frame_range)
    step = c.get("step", 1)
    n = c.get("frames")
    if n:  # fixed length: sample the action (looping) n times
        src = [f0 + (i * step) % max(1, f1 - f0) for i in range(n)]
    else:  # whole action; a loop drops the last frame (== first)
        src = list(range(f0, f1 if c.get("loop") else f1 + 1, step))
    yaw = c.get("yaw", 0)
    y0, y1 = (yaw, yaw) if not isinstance(yaw, list) else yaw
    k = max(1, len(src) - 1)
    return a, [(f, y0 + (y1 - y0) * (0.5 - 0.5 * math.cos(math.pi * i / k))) for i, f in enumerate(src)]


def pose(a, f, yaw):
    rig.animation_data_create()
    rig.animation_data.action = a
    pivot.rotation_euler = (0, 0, math.radians(yaw))
    scene.frame_set(f)


clips = {n: clip_frames(c) for n, c in R["clips"].items()}

if R.get("bone_scale"):
    # longer legs lift the body: put the feet back on the ground (lowest point standing idle)
    pose(action("Idle"), int(action("Idle").frame_range[0]), 0)
    dg = bpy.context.evaluated_depsgraph_get()
    low = min((o.evaluated_get(dg).matrix_world @ v.co).z for o in meshes if not o.hide_render
              for v in o.evaluated_get(dg).to_mesh().vertices)
    pivot.location.z -= low
    print("GROUND lift %.3f" % -low)

# ---- framing: union bbox over every pose, as seen by a camera looking along +Y ----
dg = bpy.context.evaluated_depsgraph_get()
lo = Vector((1e9, 1e9)); hi = Vector((-1e9, -1e9))
for a, fr in clips.values():
    for f, yaw in fr[::2] + fr[-1:]:
        pose(a, f, yaw)
        dg = bpy.context.evaluated_depsgraph_get()
        for o in meshes:
            if o.hide_render and not any(n in o.name for n in showable):
                continue
            ev = o.evaluated_get(dg)
            m = ev.to_mesh()
            mw = ev.matrix_world
            for v in m.vertices:
                p = mw @ v.co
                lo.x = min(lo.x, p.x); hi.x = max(hi.x, p.x)
                lo.y = min(lo.y, p.z); hi.y = max(hi.y, p.z)
            ev.to_mesh_clear()
pad = 0.04 * max(hi.x - lo.x, hi.y)
ground = 0.0
top = hi.y + pad
half_w = max(abs(lo.x), abs(hi.x)) + pad   # keep the character centred → no horizontal drift
x_lo, x_hi = -half_w, half_w
if R.get("frame"):
    x_lo, x_hi = R["frame"].get("x", [x_lo, x_hi])
    top = R["frame"].get("h", top)
frame_w, frame_h = x_hi - x_lo, top - ground
print("FRAME union x %.3f..%.3f top %.3f, used x %.3f..%.3f h %.3f" % (lo.x, hi.x, hi.y, x_lo, x_hi, frame_h))
span = max(frame_w, frame_h)          # ortho_scale covers the longer side of the render
RES = (max(1, round(SIZE * frame_w / frame_h)), SIZE)   # SIZE = render height in px

cam_data = bpy.data.cameras.new("cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = span
cam = bpy.data.objects.new("cam", cam_data)
scene.collection.objects.link(cam)
cam.location = ((x_lo + x_hi) / 2, -20, ground + frame_h / 2)
cam.rotation_euler = (math.radians(90), 0, 0)
scene.camera = cam

# ---- look: flat KayKit colours, soft key light, dark inverted-hull outline ----
world = bpy.data.worlds.new("w"); scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (1, 1, 1, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.9
sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
sun.data.energy = 2.5
sun.rotation_euler = (math.radians(50), math.radians(-25), math.radians(-30))
scene.collection.objects.link(sun)

if R.get("outline", 0.012):
    ink = bpy.data.materials.new("ink")
    ink.use_nodes = True
    ink.use_backface_culling = True
    bsdf = ink.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0.02, 0.02, 0.03, 1)
    bsdf.inputs["Roughness"].default_value = 1
    ink_clip = None
    if shell_objs:
        ink_clip = bandage_mat("ink_shell", "#050508")
        ink_clip.use_backface_culling = True
    for o in meshes:
        o.data.materials.append(ink_clip if o in shell_objs else ink)
        sol = o.modifiers.new("outline", "SOLIDIFY")
        sol.thickness = -R.get("outline", 0.012) * frame_h
        sol.use_flip_normals = True
        sol.use_rim = False
        sol.material_offset = len(o.data.materials) - 1

scene.render.engine = "BLENDER_EEVEE"
scene.eevee.taa_render_samples = 16
scene.view_settings.view_transform = "Standard"
scene.render.film_transparent = True
scene.render.resolution_x, scene.render.resolution_y = RES
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.render.fps = FPS


def stride(a, fr):
    """Distance per clip the body would travel: speed of the lowest (planted) foot, backwards."""
    feet = [b for b in rig.pose.bones if "foot" in b.name.lower()] or \
           [b for b in rig.pose.bones if "leg" in b.name.lower() and "low" in b.name.lower()]
    v = []
    prev = None
    for f, yaw in fr + fr[:1]:
        pose(a, f, yaw)
        pts = [(rig.matrix_world @ b.head) for b in feet]
        low = min(range(len(pts)), key=lambda i: pts[i].z)
        if prev and prev[0] == low:
            v.append(prev[1].x - pts[low].x)   # planted foot slides backwards (-x) as we walk +x
        prev = (low, pts[low])
    per_frame = sorted(v)[len(v) // 2] if v else 0.0  # median: robust to foot swaps
    return abs(per_frame * len(fr)) / frame_w         # fraction of render width per cycle (also backwards)


os.makedirs(OUT, exist_ok=True)
for f in os.listdir(OUT):
    if f.endswith(".png"):
        os.remove(os.path.join(OUT, f))
meta = {}
def along(v, i, n):
    """A clip value: a number, or [from, to] eased over the clip."""
    if isinstance(v, list):
        q = 0.5 - 0.5 * math.cos(math.pi * i / max(1, n - 1))
        return v[0] + (v[1] - v[0]) * q
    return v


def wrap_state(c, i, n):
    if SHELL:
        w = along(c.get("wrap", 1), i, n)
        level = -0.3 + w * (body_top + 0.6)      # 0: below the feet (with the edge), 1: over the head
        for node in level_nodes:
            node.outputs[0].default_value = level
    if heap:
        s = along(c.get("heap", 0), i, n)
        heap.hide_render = s < 0.03
        heap.scale = (s, s, max(0.05, s))


from mathutils import Matrix
shown = {o: o.hide_render for o in meshes}
for name, (a, fr) in clips.items():
    c = R["clips"][name]
    only = c.get("only")
    for o in meshes:
        o.hide_render = ((shown[o] and not any(n in o.name for n in c.get("show", [])))
                         or bool(only and not any(n in o.name for n in only))
                         or any(n in o.name for n in c.get("drop", [])))
    track = {b: [] for b in c.get("track", {})}
    for i, (f, yaw) in enumerate(fr):
        pose(a, f, yaw)
        lz = along(c.get("lift", 0), i, len(fr))
        pivot.location.z += lz
        wrap_state(c, i, len(fr))
        if track:
            bpy.context.view_layer.update()
            for b, off in c["track"].items():
                p = rig.matrix_world @ rig.pose.bones[b].head + Vector(off)
                track[b].append([round((p.x - x_lo) / frame_w * RES[0], 1),
                                 round(RES[1] - (p.z - ground) / frame_h * RES[1], 1)])
        loc, rot = pivot.location.copy(), pivot.rotation_euler.copy()
        if c.get("spin"):
            # turn what shows about its own middle, in the picture plane: a piece flying off
            dg = bpy.context.evaluated_depsgraph_get()
            pts = [ev.matrix_world @ v.co for o in meshes if not o.hide_render
                   for ev in [o.evaluated_get(dg)] for v in ev.to_mesh().vertices]
            mid = sum(pts, Vector()) / max(1, len(pts))
            ang = 2 * math.pi * i / len(fr)
            pivot.matrix_world = (Matrix.Translation(mid) @ Matrix.Rotation(ang, 4, "Y")
                                  @ Matrix.Translation(-mid) @ pivot.matrix_world)
        scene.render.filepath = os.path.join(OUT, f"{name}_{i:04d}.png")
        bpy.ops.render.render(write_still=True)
        pivot.location, pivot.rotation_euler = loc, rot
        pivot.location.z -= lz
    for o in meshes:
        o.hide_render = shown[o]
    meta[name] = {"files": f"{name}_*.png", "count": len(fr), "fps": FPS / c.get("step", 1) * c.get("speed", 1),
                  "loop": bool(c.get("loop", False)),
                  "stride": stride(a, fr) if c.get("stride") == "auto" else float(c.get("stride", 0))}
    if track:
        meta[name]["track"] = track
json.dump({"view": "front", "model": R["model"], "clips": meta,
           "unit_px": RES[1] / frame_h, "origin_px": [RES[0] * -x_lo / frame_w, RES[1]]},
          open(os.path.join(OUT, "clips.json"), "w"), indent=1)
print("BAKED", OUT, {n: m["count"] for n, m in meta.items()}, {n: round(m["stride"], 3) for n, m in meta.items()})
