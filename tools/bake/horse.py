# Bake Sinterklaas's white horse (Ozosnel) for themes/engine.lua, from Quaternius's rigged "White
# Horse" (CC0 1.0, https://poly.pizza/m/bEdE4rmZy9):
#
#   mkdir -p tools/bake/models/quaternius && curl -L -o tools/bake/models/quaternius/White_Horse.glb \
#       https://static.poly.pizza/3edc2bd9-3378-4b43-a50d-d5e1f858562b.glb
#   PYTHONPATH=<dir with numpy> blender -b -P tools/bake/horse.py -- <out_dir> [size] [--plain]
#
# <out_dir>/horse/ (--plain: no saddle cloth, for St Martin: <out_dir>/horse_plain/):
#   walk (loop), trot (loop: the gallop, slowed), idle (loop), graze (Eating: head down, chewing),
#   shake (Idle_2: a toss of the head), headlow (Idle_Headlow).
# Seen from the side, turned a little to the viewer, facing right. Same look and world unit as
# kaykit.py (size = the height of a 2.6 unit frame, so 384 -> 147.7 px per unit); the horse is
# scaled to stand ~1.25 units at the withers next to a KayKit character. Every clip carries
# track.saddle: where the rider's seat is in each frame (render px), for tools/bake/ride.py, which
# puts a rider (a kaykit.py "ride" clip) on it.

import bpy, json, math, os, sys
from mathutils import Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:]
PLAIN = "--plain" in argv
argv = [a for a in argv if not a.startswith("--")]
OUT = os.path.abspath(argv[0])
SIZE = int(argv[1]) if len(argv) > 1 else 384
PX = SIZE / 2.6
HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.path.join(HERE, "models", "quaternius", "White_Horse.glb")
SCALE = 0.6                      # model units -> KayKit units: a big horse next to a chunky KayKit rider
YAW = 75                         # the head (model -Y) turned to +X, a little towards us
FPS = 24
CLIPS = {
    "walk":    {"action": "Walk", "loop": True, "step": 2, "stride": "auto"},
    "trot":    {"action": "Gallop", "loop": True, "step": 2, "stride": "auto", "speed": 0.6},
    "idle":    {"action": "Idle", "loop": True, "step": 2},
    "graze":   {"action": "Eating", "loop": True, "step": 2},
    "shake":   {"action": "Idle_2", "step": 2},
    "headlow": {"action": "Idle_Headlow", "loop": True, "step": 2},
}
COLORS = {"Main": "#f3f1ec", "Main_Light": "#d8d5cf", "Hair": "#eceae4", "Muzzle": "#b9a9a2",
          "Hooves": "#4a423c", "Eye_Black": "#141414", "Eye_White": "#ffffff"}

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=MODEL)
scene = bpy.context.scene
for o in list(scene.objects):
    if o.type in ("CAMERA", "LIGHT") or (o.type == "MESH" and o.name.split(".")[0] in ("Cube", "Icosphere")):
        bpy.data.objects.remove(o, do_unlink=True)
rig = next(o for o in scene.objects if o.type == "ARMATURE")
horse = next(o for o in scene.objects if o.type == "MESH" and o.name.startswith("Horse"))
root = rig.parent or rig


def lin(h):
    return [(int(h[i:i + 2], 16) / 255) ** 2.2 for i in (1, 3, 5)]


for m in horse.data.materials:
    b = m.node_tree.nodes.get("Principled BSDF") if m and m.use_nodes else None
    if b and m.name.split(".")[0] in COLORS:
        b.inputs["Base Color"].default_value = (*lin(COLORS[m.name.split(".")[0]]), 1)
        b.inputs["Roughness"].default_value = 0.6


def mat(name, hexc):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*lin(hexc), 1)
    b.inputs["Roughness"].default_value = 0.55
    return m


# the saddle cloth: red with a gold hem, and a red seat cushion - on the back bone (Torso2), in the
# model's own units (rest pose)
parts = [horse]
bpy.context.view_layer.update()
# the seat, where a rider sits: on the top of the back over Torso2 (rest pose, armature space)
SEAT = rig.matrix_world.inverted() @ Vector((0, 0.05, 3.42 if not PLAIN else 3.25))
if not PLAIN:
    for name, loc, size, color in (
        ("cloth", (0, 0.0, 2.85), (1.42, 1.25, 0.85), "#c8141e"),
        ("hem", (0, 0.0, 2.44), (1.45, 1.28, 0.12), "#e2b23a"),
        ("seat", (0, 0.05, 3.3), (1.0, 0.95, 0.24), "#9e0f17"),
    ):
        bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
        o = bpy.context.object
        o.name = name
        o.scale = size
        bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
        bev = o.modifiers.new("bevel", "BEVEL")
        bev.width, bev.segments = 0.14, 4
        o.data.materials.append(mat(name, color))
        # skinned to the back bone (Torso2): it moves with the walk
        o.parent = rig
        o.matrix_parent_inverse = rig.matrix_world.inverted()
        vg = o.vertex_groups.new(name="Torso2")
        vg.add(list(range(len(o.data.vertices))), 1.0, "REPLACE")
        arm = o.modifiers.new("armature", "ARMATURE")
        arm.object = rig
        parts.append(o)

pivot = bpy.data.objects.new("pivot", None)
scene.collection.objects.link(pivot)
root.parent = pivot
pivot.scale = (SCALE, SCALE, SCALE)
pivot.rotation_euler = (0, 0, math.radians(YAW))
bpy.context.view_layer.update()

actions = {a.name: a for a in bpy.data.actions}


def action(name):
    want = name + "_AnimalArmature"
    return actions.get(want) or next(a for n, a in actions.items() if n.endswith("|" + want))


def frames_of(c):
    a = action(c["action"])
    f0, f1 = (int(round(x)) for x in a.frame_range)
    step = c.get("step", 1)
    return a, list(range(f0, f1 if c.get("loop") else f1 + 1, step))


def pose(a, f):
    rig.animation_data_create()
    rig.animation_data.action = a
    scene.frame_set(f)


def seat():
    """the rider's seat (world): over the Torso2 bone, on the top of the back"""
    pb = rig.pose.bones["Torso2"]
    return rig.matrix_world @ (pb.matrix @ pb.bone.matrix_local.inverted() @ SEAT)


# ---- framing over every pose ----
plan = {n: frames_of(c) for n, c in CLIPS.items()}
lo = Vector((1e9, 1e9)); hi = Vector((-1e9, -1e9))
for a, fr in plan.values():
    for f in fr[::2]:
        pose(a, f)
        dg = bpy.context.evaluated_depsgraph_get()
        for o in parts:
            ev = o.evaluated_get(dg)
            m = ev.to_mesh()
            for v in m.vertices:
                p = ev.matrix_world @ v.co
                lo.x, hi.x, hi.y = min(lo.x, p.x), max(hi.x, p.x), max(hi.y, p.z)
            ev.to_mesh_clear()
pad = 0.06
x_lo, x_hi, top = lo.x - pad, hi.x + pad, hi.y + pad
pose(plan["idle"][0], plan["idle"][1][0])
dg = bpy.context.evaluated_depsgraph_get()
ground = min((horse.evaluated_get(dg).matrix_world @ v.co).z for v in horse.evaluated_get(dg).to_mesh().vertices)
pivot.location.z -= ground
top -= ground
frame_w, frame_h = x_hi - x_lo, top
RES = (round(PX * frame_w), round(PX * frame_h))
print("FRAME x %.2f..%.2f h %.2f -> %s" % (x_lo, x_hi, frame_h, RES))

cam_data = bpy.data.cameras.new("cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = max(frame_w, frame_h)
cam = bpy.data.objects.new("cam", cam_data)
scene.collection.objects.link(cam)
cam.location = ((x_lo + x_hi) / 2, -20, frame_h / 2)
cam.rotation_euler = (math.radians(90), 0, 0)
scene.camera = cam

# ---- look: as kaykit.py ----
world = bpy.data.worlds.new("w"); scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (1, 1, 1, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.9
sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
sun.data.energy = 2.5
sun.rotation_euler = (math.radians(50), math.radians(-25), math.radians(-30))
scene.collection.objects.link(sun)
ink = bpy.data.materials.new("ink")
ink.use_nodes = True
ink.use_backface_culling = True
ink.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.02, 0.02, 0.03, 1)
for o in parts:
    o.data.materials.append(ink)
    sol = o.modifiers.new("outline", "SOLIDIFY")
    sol.thickness = -0.012 * 2.6 / o.matrix_world.to_scale().x     # (as kaykit.py, in world units)
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


def to_px(p):
    return [round((p.x - x_lo) * PX, 1), round((frame_h - p.z) * PX, 1)]


def foot_speed(a, fr):
    """ground speed (world units per action frame) from a front hoof while it is on the ground"""
    xs, zs = [], []
    for f in range(fr[0], fr[-1] + 1):
        pose(a, f)
        p = rig.matrix_world @ rig.pose.bones["FF.L"].head
        xs.append(p.x); zs.append(p.z)
    low = min(zs)
    v = [xs[i] - xs[i + 1] for i in range(len(xs) - 1) if zs[i] < low + 0.03 and zs[i + 1] < low + 0.03]
    return max(0.0, sum(v) / len(v)) if v else 0.0


name = "horse_plain" if PLAIN else "horse"
d = os.path.join(OUT, name)
os.makedirs(d, exist_ok=True)
for f in os.listdir(d):
    if f.endswith(".png"):
        os.remove(os.path.join(d, f))
meta = {}
for n, c in CLIPS.items():
    a, fr = plan[n]
    sp = c.get("speed", 1)
    stride = 0.0
    if c.get("stride") == "auto":
        stride = foot_speed(a, fr) * (fr[-1] + c.get("step", 1) - fr[0])   # world units per loop (as kaykit.py)
    track = []
    for i, f in enumerate(fr):
        pose(a, f)
        track.append(to_px(seat()))
        scene.render.filepath = os.path.join(d, "%s_%04d.png" % (n, i))
        bpy.ops.render.render(write_still=True)
    meta[n] = {"files": n + "_*.png", "count": len(fr), "fps": FPS / c.get("step", 1) * sp,
               "loop": bool(c.get("loop")), "stride": round(stride, 2), "track": {"saddle": track}}
json.dump({"view": "front", "model": "horse.py", "clips": meta, "unit_px": PX,
           "origin_px": [round(-x_lo * PX, 1), RES[1]]}, open(os.path.join(d, "clips.json"), "w"), indent=1)
print("BAKED", name, {n: m["count"] for n, m in meta.items()}, {n: m["stride"] for n, m in meta.items()})
