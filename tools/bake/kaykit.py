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
#   per clip "speed": 0.6  play slower (or faster): fps, and so the walking speed, scaled
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
meshes = [o for o in meshes if not o.hide_render]

# Turntable parent so yaw does not fight the imported rig transform.
pivot = bpy.data.objects.new("pivot", None)
scene.collection.objects.link(pivot)
for o in scene.objects:
    if o.parent is None and o is not pivot:
        o.parent = pivot

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


def clip_frames(c):
    """[(action_frame, yaw_deg)] for one clip."""
    a = held(c)
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
    low = min((o.evaluated_get(dg).matrix_world @ v.co).z for o in meshes for v in o.evaluated_get(dg).to_mesh().vertices)
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
    for o in meshes:
        o.data.materials.append(ink)
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
for name, (a, fr) in clips.items():
    c = R["clips"][name]
    for i, (f, yaw) in enumerate(fr):
        pose(a, f, yaw)
        scene.render.filepath = os.path.join(OUT, f"{name}_{i:04d}.png")
        bpy.ops.render.render(write_still=True)
    meta[name] = {"files": f"{name}_*.png", "count": len(fr), "fps": FPS / c.get("step", 1) * c.get("speed", 1),
                  "loop": bool(c.get("loop", False)),
                  "stride": stride(a, fr) if c.get("stride") == "auto" else float(c.get("stride", 0))}
json.dump({"view": "front", "model": R["model"], "clips": meta,
           "unit_px": RES[1] / frame_h, "origin_px": [RES[0] * -x_lo / frame_w, RES[1]]},
          open(os.path.join(OUT, "clips.json"), "w"), indent=1)
print("BAKED", OUT, {n: m["count"] for n, m in meta.items()}, {n: round(m["stride"], 3) for n, m in meta.items()})
