# Procedural spider, rendered as transparent PNG frame sequences for the theme engine.
#
#   blender -b -P tools/bake/spider.py -- <out_dir> [view] [size]
#
# view: "below" (camera under the glass, spider walking on it) or "side" (walking along the bottom edge).
# Clips: walk (seamless cycle, body stays put: the engine moves the sprite by "stride" per cycle),
#        wave (stops, lifts and waves its front legs), idle (small twitches).
# Writes <out_dir>/<clip>_NNNN.png and <out_dir>/clips.json with fps + stride metadata.

import bpy, math, json, os, sys
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = os.path.abspath(argv[0] if argv else "spider_out")
VIEW = argv[1] if len(argv) > 1 else "below"
SIZE = int(argv[2]) if len(argv) > 2 else 512
FPS = 24
CYCLE = 16            # frames per walk cycle
STRIDE = 0.9          # body-lengths travelled per cycle (in scene units: body ~1.6 long)

# ── scene ─────────────────────────────────────────────────────────────────────
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
sc.render.engine = "CYCLES"
sc.cycles.samples = 64
sc.cycles.use_denoising = False
sc.render.film_transparent = True
sc.render.resolution_x = sc.render.resolution_y = SIZE
sc.render.image_settings.file_format = "PNG"
sc.render.image_settings.color_mode = "RGBA"
sc.render.fps = FPS
sc.view_settings.view_transform = "Standard"

def mat(name, rgb, rough=0.45, emit=None):
    m = bpy.data.materials.new(name); m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*rgb, 1)
    b.inputs["Roughness"].default_value = rough
    if emit:
        b.inputs["Emission Color"].default_value = (*emit, 1)
        b.inputs["Emission Strength"].default_value = 4.0
    return m

M_BODY = mat("body", (0.035, 0.025, 0.03), 0.35)
M_LEG = mat("leg", (0.05, 0.035, 0.035), 0.5)
M_MARK = mat("mark", (0.9, 0.35, 0.03), 0.4)
M_EYE = mat("eye", (0.6, 0.02, 0.02), 0.15, emit=(1.0, 0.05, 0.02))

def sphere(name, loc, scale, m, seg=32):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=seg, ring_count=seg // 2, location=loc)
    o = bpy.context.object; o.name = name; o.scale = scale
    o.data.materials.append(m)
    bpy.ops.object.shade_smooth()
    return o

root = bpy.data.objects.new("root", None); sc.collection.objects.link(root)

# body: +X is forward, Z up, ground at z=0
parts = [
    sphere("abdomen", (-0.55, 0, 0.55), (0.62, 0.48, 0.42), M_BODY),
    sphere("thorax", (0.25, 0, 0.5), (0.34, 0.3, 0.24), M_BODY),
    sphere("head", (0.55, 0, 0.47), (0.17, 0.17, 0.14), M_BODY),
    sphere("mark", (-0.5, 0, 0.93), (0.22, 0.12, 0.05), M_MARK),     # orange hourglass-ish mark on top
    sphere("belly", (-0.55, 0, 0.17), (0.3, 0.18, 0.06), M_MARK),    # and one underneath, for the view from below
]
for s in (-1, 1):
    parts.append(sphere(f"eye{s}", (0.68, 0.07 * s, 0.53), (0.045,) * 3, M_EYE, 16))
    parts.append(sphere(f"eye2{s}", (0.66, 0.13 * s, 0.5), (0.03,) * 3, M_EYE, 16))
    parts.append(sphere(f"fang{s}", (0.7, 0.05 * s, 0.36), (0.04, 0.03, 0.08), M_LEG, 16))
for p in parts:
    p.parent = root

# ── legs: 3 segments each, positioned per frame from 2-bone IK ────────────────
LEGS = []   # (side, index) ; index 0 = front
HIP_X = [0.42, 0.3, 0.18, 0.06]
REST_FOOT = [(1.35, 1.0), (0.55, 1.35), (-0.25, 1.35), (-1.05, 1.0)]   # (x, |y|) foot rest positions
FEMUR, TIBIA = 0.95, 0.85

def segment(name, r):
    bpy.ops.mesh.primitive_cylinder_add(vertices=12, radius=r, depth=1.0)
    o = bpy.context.object; o.name = name
    o.data.materials.append(M_LEG)
    bpy.ops.object.shade_smooth()
    # pivot at bottom so scale.z = length
    for v in o.data.vertices: v.co.z += 0.5
    o.parent = root
    return o

for s in (-1, 1):
    for i in range(4):
        LEGS.append({
            "side": s, "i": i,
            "hip": Vector((HIP_X[i], 0.2 * s, 0.5)),
            "rest": Vector((REST_FOOT[i][0], REST_FOOT[i][1] * s, 0.0)),
            "segs": [segment(f"femur{s}{i}", 0.045), segment(f"tibia{s}{i}", 0.035), segment(f"tarsus{s}{i}", 0.025)],
            "knuckles": [sphere(f"kn{s}{i}{k}", (0, 0, 0), (0.05,) * 3, M_LEG, 12) for k in range(2)],
        })

def place(o, a, b):
    d = b - a
    o.location = a
    o.rotation_mode = "QUATERNION"
    o.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(d.normalized())
    o.scale = (1, 1, d.length)

def ik_knee(hip, foot, side):
    """Knee high above the hip–foot line, bending outwards like a spider's."""
    d = foot - hip
    L = min(d.length, FEMUR + TIBIA - 1e-3)
    a = (FEMUR ** 2 - TIBIA ** 2 + L ** 2) / (2 * L)
    h = math.sqrt(max(0.0, FEMUR ** 2 - a ** 2))
    dn = d.normalized()
    up = Vector((0, 0, 1))
    perp = (up - dn * up.dot(dn)).normalized()
    return hip + dn * a + perp * h

def pose_leg(leg, foot):
    hip = leg["hip"]
    tarsus_top = foot + Vector((0, 0, 0.18)) + Vector((foot.x - hip.x, foot.y - hip.y, 0)).normalized() * -0.05
    knee = ik_knee(hip, tarsus_top, leg["side"])
    f, t, ta = leg["segs"]
    place(f, hip, knee); place(t, knee, tarsus_top); place(ta, tarsus_top, foot)
    leg["knuckles"][0].location = knee; leg["knuckles"][1].location = tarsus_top

def key_all(frame):
    for leg in LEGS:
        for o in leg["segs"]:
            o.keyframe_insert("location", frame=frame); o.keyframe_insert("rotation_quaternion", frame=frame)
            o.keyframe_insert("scale", frame=frame)
        for o in leg["knuckles"]:
            o.keyframe_insert("location", frame=frame)
    for p in parts:
        p.keyframe_insert("location", frame=frame); p.keyframe_insert("rotation_euler", frame=frame)

BASE = {p.name: (p.location.copy(), p.rotation_euler.copy()) for p in parts}

def body(dz=0.0, pitch=0.0, yaw=0.0):
    rot = Matrix.Rotation(yaw, 3, "Z") @ Matrix.Rotation(pitch, 3, "Y")
    pivot = Vector((0.1, 0, 0.5))
    for p in parts:
        loc0, r0 = BASE[p.name]
        p.location = pivot + rot @ (loc0 - pivot) + Vector((0, 0, dz))
        p.rotation_euler = (r0.x, r0.y + pitch, r0.z + yaw)
    for leg in LEGS:
        h0 = Vector((HIP_X[leg["i"]], 0.2 * leg["side"], 0.5))
        leg["hip"] = pivot + rot @ (h0 - pivot) + Vector((0, 0, dz))

# Alternating tetrapod gait: L0,R1,L2,R3 vs R0,L1,R2,L3, half a cycle apart.
def gait_offset(leg):
    return 0.0 if ((leg["i"] + (leg["side"] > 0)) % 2 == 0) else 0.5

def walk_foot(leg, phase):
    """phase 0..1. Stance 0..0.6: foot slides back at body speed. Swing 0.6..1: lifts and returns."""
    p = (phase + gait_offset(leg)) % 1.0
    half = STRIDE / 2
    duty = 0.6
    rest = leg["rest"]
    if p < duty:
        x = half - STRIDE * (p / duty)
        z = 0.0
    else:
        q = (p - duty) / (1 - duty)
        x = -half + STRIDE * (q * q * (3 - 2 * q))
        z = 0.32 * math.sin(math.pi * q)
    return rest + Vector((x, 0, z))

clips = {}

def bake_walk(start):
    for k in range(CYCLE):
        ph = k / CYCLE
        body(dz=0.03 * math.sin(4 * math.pi * ph), yaw=0.03 * math.sin(2 * math.pi * ph))
        for leg in LEGS:
            pose_leg(leg, walk_foot(leg, ph))
        key_all(start + k)
    clips["walk"] = {"start": start, "count": CYCLE, "fps": FPS, "stride": STRIDE, "loop": True}
    return start + CYCLE

def bake_wave(start, n=56):
    # settle all feet to rest, rear up, wave the two front legs at the viewer, settle back
    for k in range(n):
        u = k / (n - 1)
        rear = math.sin(math.pi * u) ** 0.6           # 0 → 1 → 0
        body(dz=0.12 * rear, pitch=-0.35 * rear)
        for leg in LEGS:
            foot = leg["rest"].copy()
            if leg["i"] == 0:
                w = math.sin(2 * math.pi * 3 * u + (0 if leg["side"] > 0 else math.pi))
                if VIEW == "below":
                    # seen through the glass: lift the front legs a little and sweep them sideways
                    target = Vector((1.55 + 0.15 * w, (0.55 + 0.5 * w) * leg["side"], 0.35))
                else:
                    target = Vector((1.25, 0.75 * leg["side"], 1.45 + 0.25 * w))
                foot = foot.lerp(target, rear)
            pose_leg(leg, foot)
        key_all(start + k)
    clips["wave"] = {"start": start, "count": n, "fps": FPS, "stride": 0, "loop": False}
    return start + n

def bake_idle(start, n=32):
    for k in range(n):
        u = k / n
        body(dz=0.015 * math.sin(2 * math.pi * u))
        for leg in LEGS:
            foot = leg["rest"].copy()
            if leg["i"] == 0:   # tap a front foot
                foot.z += 0.12 * max(0.0, math.sin(2 * math.pi * (2 * u + (0.25 if leg["side"] > 0 else 0.0))))
            pose_leg(leg, foot)
        key_all(start + k)
    clips["idle"] = {"start": start, "count": n, "fps": FPS, "stride": 0, "loop": True}
    return start + n

f = 1
f = bake_walk(f)
f = bake_wave(f)
f = bake_idle(f)
for fc in (o.animation_data.action.fcurves for o in bpy.data.objects if o.animation_data):
    for c in fc:
        for kp in c.keyframe_points: kp.interpolation = "LINEAR"

# ── camera + light ────────────────────────────────────────────────────────────
cam_data = bpy.data.cameras.new("cam"); cam_data.type = "ORTHO"; cam_data.ortho_scale = 3.9
cam = bpy.data.objects.new("cam", cam_data); sc.collection.objects.link(cam); sc.camera = cam
if VIEW == "below":
    # looking straight up through the glass; spider walks towards screen-right (+X)
    cam.location = (0.0, 0.0, -6.0); cam.rotation_euler = (math.pi, 0, 0)
else:
    # side view, slightly from below eye level
    cam_data.ortho_scale = 4.0
    cam.location = (0.0, -8.0, 0.9); cam.rotation_euler = (math.radians(88), 0, 0)

def light(name, kind, loc, energy, rot=(0, 0, 0)):
    l = bpy.data.lights.new(name, kind); l.energy = energy
    o = bpy.data.objects.new(name, l); o.location = loc; o.rotation_euler = rot
    sc.collection.objects.link(o)
light("key", "SUN", (0, 0, 0), 3.0, (math.radians(150 if VIEW == "below" else 40), math.radians(20), 0))
light("rim", "SUN", (0, 0, 0), 2.0, (math.radians(-60), math.radians(-30), math.radians(180)))
light("warm", "POINT", (2, 0, -2 if VIEW == "below" else 2), 150)
bpy.data.lights["warm"].color = (1.0, 0.55, 0.2)
world = bpy.data.worlds.new("w"); sc.world = world; world.use_nodes = True
world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.35

# ── render ────────────────────────────────────────────────────────────────────
os.makedirs(OUT, exist_ok=True)
for name, c in clips.items():
    for k in range(c["count"]):
        sc.frame_set(c["start"] + k)
        sc.render.filepath = os.path.join(OUT, f"{name}_{k:04d}.png")
        bpy.ops.render.render(write_still=True)
# stride as a fraction of the full render width (themes.py converts to pixels after cropping)
meta = {n: {"files": f"{n}_*.png", "count": c["count"], "fps": c["fps"], "loop": c["loop"],
            "stride": c["stride"] / cam_data.ortho_scale} for n, c in clips.items()}
json.dump({"view": VIEW, "clips": meta}, open(os.path.join(OUT, "clips.json"), "w"), indent=1)
print("BAKED", OUT, {n: c["count"] for n, c in clips.items()})
