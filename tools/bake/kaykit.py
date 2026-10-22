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
# yaw 0 = facing the viewer, 90 = walking to the right. A [from, to] yaw turns during the clip.
# The camera is orthographic, level, and identical for all clips (framed on the union of all
# poses) with its bottom edge on the ground plane, so "rising from the ground" clips are cut at
# ground level, and the sprite's bottom edge is where the feet stand.
# Writes <out_dir>/<clip>_NNNN.png and clips.json (same format as spider.py).

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


def action(name):
    return actions.get(name) or actions.get(name + "_Rig") or next(a for n, a in actions.items() if n.startswith(name))


def clip_frames(c):
    """[(action_frame, yaw_deg)] for one clip."""
    a = action(c["action"])
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
frame_w, frame_h = 2 * half_w, top - ground
span = max(frame_w, frame_h)          # ortho_scale covers the longer side of the render
RES = (max(1, round(SIZE * frame_w / frame_h)), SIZE)   # SIZE = render height in px

cam_data = bpy.data.cameras.new("cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = span
cam = bpy.data.objects.new("cam", cam_data)
scene.collection.objects.link(cam)
cam.location = (0, -20, ground + frame_h / 2)
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
    return max(0.0, per_frame * len(fr)) / frame_w    # fraction of render width per cycle


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
    meta[name] = {"files": f"{name}_*.png", "count": len(fr), "fps": FPS / c.get("step", 1),
                  "loop": bool(c.get("loop", False)),
                  "stride": stride(a, fr) if c.get("stride") == "auto" else float(c.get("stride", 0))}
json.dump({"view": "front", "model": R["model"], "clips": meta}, open(os.path.join(OUT, "clips.json"), "w"), indent=1)
print("BAKED", OUT, {n: m["count"] for n, m in meta.items()}, {n: round(m["stride"], 3) for n, m in meta.items()})
