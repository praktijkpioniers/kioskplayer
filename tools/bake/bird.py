# Bake birds for the scarecrow in themes/engine.lua (they fly in and sit on its arm or hat):
#
#   blender -b -P tools/bake/bird.py -- <crow|vulture> <out_dir> [size]
#
# <out_dir>/<kind>/: "sit" (loop: breathing, a look round, a blink), "fly" (loop: the wing beat,
# legs tucked), "spread" (sitting, the wings opened wide and folded again). Seen from the side,
# turned a little to the viewer, facing right. Same look and world unit as frog.py / kaykit.py
# (size is the height of a 2.6 unit frame; a bird's frame is cut smaller at the same scale). A
# raven is the crow baked once, shown bigger (theme.json "unit").

import bpy, bmesh, json, math, os, sys

argv = sys.argv[sys.argv.index("--") + 1:]
KIND = argv[0]
OUT = os.path.abspath(argv[1])
SIZE = int(argv[2]) if len(argv) > 2 else 384
PX = SIZE / 2.6                     # pixels per world unit, as the others

# kind: frame, colours, body sizes
K = {
    "crow": dict(frame_h=0.95, x=(-0.55, 0.6), body=(0.2, (1.3, 0.8, 0.85)), shoulder_z=0.36, wing=(0.14, 0.3),
                 head=0.11, neck=None, sit_pitch=20, nod=0, plumage=(26, 26, 32), dark=(14, 14, 18), beak=(40, 40, 46),
                 legs=(40, 40, 46), ruff=None, skin=None, tail=(0.2, 0.09)),
    "vulture": dict(frame_h=1.35, x=(-0.75, 0.8), body=(0.26, (1.05, 0.95, 1.25)), sit_pitch=38, nod=50, shoulder_z=0.5, wing=(0.2, 0.48),
                    head=0.085, neck=0.17, plumage=(58, 44, 36), dark=(36, 26, 22), beak=(222, 208, 170),
                    legs=(150, 140, 130), ruff=(205, 200, 190), skin=(196, 112, 100), tail=(0.22, 0.12)),
}[KIND]
FRAME_H = K["frame_h"]
X_LO, X_HI = K["x"]

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def mat(name, rgb, rough=0.6):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*[(v / 255) ** 2.2 for v in rgb], 1)
    b.inputs["Roughness"].default_value = rough
    return m


PLUME, DARK, BEAK = mat("plume", K["plumage"], 0.45), mat("dark", K["dark"]), mat("beak", K["beak"])
LEGS, WHITE, BLACK = mat("legs", K["legs"]), mat("white", (240, 236, 220)), mat("black", (10, 10, 12))
RUFF = K["ruff"] and mat("ruff", K["ruff"], 0.9)
SKIN = K["skin"] and mat("skin", K["skin"])

rig = bpy.data.objects.new("rig", None)          # everything hangs off this (the turn to the viewer)
scene.collection.objects.link(rig)
parts = []


def blob(name, material, r, at, scale=(1, 1, 1), parent=rig, rot=(0, 0, 0)):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=20, v_segments=10, radius=r)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    o.data.materials.append(material)
    scene.collection.objects.link(o)
    o.parent = parent
    o.location = at
    o.scale = scale
    o.rotation_euler = rot
    parts.append(o)
    return o


def cone(name, material, r, length, at, parent, rot):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=12, radius1=r, radius2=0, depth=length)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    o.data.materials.append(material)
    scene.collection.objects.link(o)
    o.parent = parent
    o.location = at
    o.rotation_euler = rot
    parts.append(o)
    return o


def pivot(name, at, parent=rig):
    e = bpy.data.objects.new(name, None)
    scene.collection.objects.link(e)
    e.parent = parent
    e.location = at
    return e


# body: an egg leaning nose-up; the head on a neck pivot (the vulture's long bare neck, a ruff)
br, bs = K["body"]
sz = K["shoulder_z"]
body_p = pivot("body_p", (0, 0, sz - 0.08))
body = blob("body", PLUME, br, (0, 0, 0), bs, body_p)
breast = blob("breast", DARK, br * 0.8, (br * 0.45, 0, -br * 0.15), (1.0, 0.85, 0.85), body_p)
tl, tw = K["tail"]
tail = blob("tail", DARK, 1, (-br * 1.35, 0, -br * 0.35), (tl, tw, 0.03), body_p, (0, math.radians(-25), 0))
neck_p = pivot("neck_p", (br * 0.95, 0, br * 0.45), body_p)
hr = K["head"]
if K["neck"]:
    ruff = blob("ruff", RUFF, br * 0.62, (-0.03, 0, -0.03), (1.15, 1.2, 0.75), neck_p)
    neck = blob("neck", SKIN, 0.05, (0.05, 0, K["neck"] / 2), (1, 1, K["neck"] / 0.1), neck_p,
                (0, math.radians(30), 0))
    head_at = (0.05 + K["neck"] * 0.6, 0, K["neck"])
    head = blob("head", SKIN, hr, head_at, (1.15, 0.95, 0.95), neck_p)
    beak = cone("beak", BEAK, hr * 0.45, hr * 1.5, (head_at[0] + hr * 1.3, 0, head_at[2] - hr * 0.2), neck_p,
                (0, math.radians(110), 0))
    hook = blob("hook", BEAK, hr * 0.3, (head_at[0] + hr * 1.9, 0, head_at[2] - hr * 0.5), (1, 0.8, 1.2), neck_p)
else:
    head_at = (0.06, 0, 0.06)
    head = blob("head", PLUME, hr, head_at, (1.1, 0.95, 1.0), neck_p)
    beak = cone("beak", BEAK, hr * 0.42, hr * 1.5, (head_at[0] + hr * 1.6, 0, head_at[2] - hr * 0.1), neck_p,
                (0, math.radians(95), 0))
eye_y = -hr * 0.75
eye = blob("eye", WHITE if not K["neck"] else mat("eyey", (230, 170, 60)), hr * 0.28,
           (head_at[0] + hr * 0.45, eye_y, head_at[2] + hr * 0.25), (1, 0.6, 1), neck_p)
pupil = blob("pupil", BLACK, hr * 0.15, (head_at[0] + hr * 0.55, eye_y - hr * 0.12, head_at[2] + hr * 0.27),
             (1, 0.6, 1.1), neck_p)
lid = blob("lid", PLUME if not K["neck"] else SKIN, hr * 0.31, (head_at[0] + hr * 0.45, eye_y + 0.005,
           head_at[2] + hr * 0.25), (1, 0.6, 1), neck_p)

# wings on shoulder pivots: the blob reaches out along y (spread); folding turns it back along
# the body; flapping turns it up and down about x
wr, wl = K["wing"]
wings = []
for side in (1, -1):
    p = pivot(f"shoulder{side}", (br * 0.2, side * br * 0.55, br * 0.35), body_p)
    w = blob(f"wing{side}", PLUME, 1, (0, side * wl * 0.55, 0), (wr, wl * 0.62, 0.03), p)
    tip = blob(f"tip{side}", DARK, 1, (-wr * 0.4, side * wl * 1.0, 0), (wr * 0.8, wl * 0.35, 0.025), p)
    wings.append((side, p))

# legs: shank + foot on hip pivots (tucked back in flight)
legs = []
for k, y in enumerate((-0.05, 0.05)):
    hip = pivot(f"hip{k}", (0.02, y, -br * 0.6), body_p)
    shank = blob(f"shank{k}", LEGS, 0.022, (0, 0, -0.1), (1, 1, 5), hip)
    foot = blob(f"foot{k}", LEGS, 0.03, (0.03, 0, -0.2), (2.2, 1.2, 0.5), hip)
    legs.append(hip)

rig.rotation_euler = (0, 0, math.radians(-20))   # turned a little to the viewer

# ---- look: as kaykit.py / frog.py ----
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
    if o in (pupil, eye, lid):
        continue
    o.data.materials.append(ink)
    sol = o.modifiers.new("outline", "SOLIDIFY")
    sol.thickness = -0.008 * 2.6 / max(max(o.scale), 0.3)
    sol.use_flip_normals = True
    sol.use_rim = False
    sol.material_offset = len(o.data.materials) - 1

frame_w = X_HI - X_LO
RES = (round(PX * frame_w), round(PX * FRAME_H))
cam_data = bpy.data.cameras.new("cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = max(frame_w, FRAME_H)
cam = bpy.data.objects.new("cam", cam_data)
scene.collection.objects.link(cam)
cam.location = ((X_LO + X_HI) / 2, -20, FRAME_H / 2)
cam.rotation_euler = (math.radians(90), 0, 0)
scene.camera = cam
scene.render.engine = "BLENDER_EEVEE"
scene.eevee.taa_render_samples = 16
scene.view_settings.view_transform = "Standard"
scene.render.film_transparent = True
scene.render.resolution_x, scene.render.resolution_y = RES
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"


def pose(fold=1.0, flap=0.0, pitch=K["sit_pitch"], breathe=0.0, look=0.0, nod=0.0, blink=False, tuck=0.0, lift=0.0):
    """fold 1 (wings along the body) .. 0 (spread out); flap: wing angle up (+) / down (-) in
    degrees; pitch: body nose up (degrees); look: head turned (degrees, + to the viewer);
    tuck 0..1: legs back (flying); lift: the body raised (flying, the legs no longer on the ground)."""
    body_p.location.z = sz - 0.08 + lift
    body_p.rotation_euler = (0, math.radians(-pitch), 0)
    body.scale = (bs[0] - 0.04 * breathe, bs[1] + 0.03 * breathe, bs[2] + 0.04 * breathe)
    neck_p.rotation_euler = (0, math.radians(pitch * 0.8 + nod + K["nod"] * fold), math.radians(-look))
    lid.hide_render = not blink
    for side, p in wings:
        sweep = 88 * fold + 12 * (1 - fold)
        p.rotation_euler = (math.radians(side * (flap * (1 - fold) + 8 * fold)), math.radians(-10 * fold),
                            math.radians(side * sweep))
    for hip in legs:
        hip.rotation_euler = (0, math.radians(-100 * tuck), 0)


def bake(clips):
    d = os.path.join(OUT, KIND)
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        if f.endswith(".png"):
            os.remove(os.path.join(d, f))
    meta = {}
    for name, (n, fps, loop, frame) in clips.items():
        for i in range(n):
            frame(i, n)
            scene.render.filepath = os.path.join(d, f"{name}_{i:04d}.png")
            bpy.ops.render.render(write_still=True)
        meta[name] = {"files": f"{name}_*.png", "count": n, "fps": fps, "loop": loop, "stride": 0}
    json.dump({"view": "front", "model": "bird.py " + KIND, "clips": meta,
               "unit_px": PX, "origin_px": [PX * -X_LO, RES[1]]},
              open(os.path.join(d, "clips.json"), "w"), indent=1)


def f_sit(i, n):
    p = i / n
    look = 35 * math.sin(math.pi * clamp01((p - 0.35) / 0.4)) if KIND == "crow" else 25 * math.sin(math.pi * clamp01((p - 0.3) / 0.5))
    pose(breathe=math.sin(2 * math.pi * p), look=look, blink=(i == n - 3))


def f_fly(i, n):
    a = math.cos(2 * math.pi * i / n)
    pose(fold=0.0, flap=55 * a, pitch=5, tuck=1.0, lift=0.12, nod=-5)


def f_spread(i, n):
    p = i / (n - 1)
    s = math.sin(math.pi * p) ** 0.6
    pose(fold=1 - s, flap=25 * s, pitch=K["sit_pitch"] - 12 * s, breathe=0.5 * s, nod=-10 * s)


def clamp01(v):
    return max(0.0, min(1.0, v))


bake({"sit": (24, 8, True, f_sit), "fly": (8, 14, True, f_fly), "spread": (14, 10, False, f_spread)})
print("BAKED", KIND, OUT, RES)
