# Bake a vampire bat (the vampire's familiar in themes/engine.lua: it hangs about upside down,
# drops and flies off):
#
#   blender -b -P tools/bake/bat.py -- bat <out_dir> [size]
#
# <out_dir>/bat/: "hang" (loop: upside down, the wings wrapped round it like a cloak, a slight
# sway, an ear twitch, a blink), "unfold" (the hang let go: it drops, turns and opens its wings into
# the first frame of "fly"; played backwards it folds up and hangs again), "fly" (loop: the wing
# beat, the wings half folded on the upstroke). Seen from the side, turned a little to the viewer,
# facing right; same look and world unit as bird.py / frog.py (size is the height of a 2.6 unit
# frame; the bat's frame is cut smaller at the same scale). The size of the crow.
#
# The origin (clips.json origin_px) is the hang point: the top of the feet when hanging, on the
# frame's top edge. "hang" and the first frame of "unfold" hang from it; the last of "unfold" and
# all of "fly" have the body FLY_AT below and ahead of it (the bat drops before it flies), so
# hang -> unfold -> fly plays on without a jump with the sprite kept in place.

import bpy, bmesh, json, math, os, sys
from mathutils import Matrix, Quaternion, Vector

argv = sys.argv[sys.argv.index("--") + 1:]
KIND = argv[0]                       # "bat"
OUT = os.path.abspath(argv[1])
SIZE = int(argv[2]) if len(argv) > 2 else 384
PX = SIZE / 2.6                      # pixels per world unit, as the others
FRAME_H = 1.0
X_LO, X_HI = -0.55, 0.6
TOP = 0.03                           # the hang point this far under the frame's top edge
FLY_AT = (0.06, 0, -0.46)            # the body centre when flying, from the hang point

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def mat(name, rgb, rough=0.6, emit=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    col = (*[(v / 255) ** 2.2 for v in rgb], 1)
    b.inputs["Base Color"].default_value = col
    b.inputs["Roughness"].default_value = rough
    if emit:
        b.inputs["Emission Color"].default_value = col
        b.inputs["Emission Strength"].default_value = emit
    return m


FUR, MEMBRANE, BONE = mat("fur", (44, 30, 28), 0.8), mat("membrane", (78, 50, 46), 0.55), mat("bone", (24, 16, 15))
EAR_IN, WHITE, RED = mat("earin", (128, 72, 70)), mat("white", (245, 242, 232)), mat("red", (215, 40, 30), 0.4, 1.5)
SNOUT, BLACK = mat("snout", (70, 46, 44)), mat("black", (8, 6, 6))

rig = bpy.data.objects.new("rig", None)          # at the hang point; the turn to the viewer
scene.collection.objects.link(rig)
rig.location = (0, 0, FRAME_H - TOP)
rig.rotation_euler = (0, 0, math.radians(-20))   # turned a little to the viewer
parts = []


def link(o, material, parent, at=(0, 0, 0), scale=(1, 1, 1), rot=(0, 0, 0), outline=True):
    o.data.materials.append(material)
    scene.collection.objects.link(o)
    o.parent = parent
    o.location = at
    o.scale = scale
    o.rotation_euler = rot
    if outline:
        parts.append(o)
    return o


def blob(name, material, r, at, scale=(1, 1, 1), parent=rig, rot=(0, 0, 0), outline=True):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=20, v_segments=10, radius=r)
    bm.to_mesh(me)
    bm.free()
    return link(bpy.data.objects.new(name, me), material, parent, at, scale, rot, outline)


def cone(name, material, r, length, at, parent, rot, scale=(1, 1, 1)):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=12, radius1=r, radius2=0, depth=length)
    bmesh.ops.translate(bm, verts=bm.verts, vec=(0, 0, length / 2))     # base at the origin, tip up z
    bm.to_mesh(me)
    bm.free()
    return link(bpy.data.objects.new(name, me), material, parent, at, scale, rot)


def pivot(name, at, parent=rig):
    e = bpy.data.objects.new(name, None)
    scene.collection.objects.link(e)
    e.parent = parent
    e.location = at
    return e


def line(name, material, n, width, parent):
    """a tube along n points (bones, legs, the wing's edge), moved each frame"""
    c = bpy.data.curves.new(name, "CURVE")
    c.dimensions = "3D"
    c.bevel_depth = width
    c.bevel_resolution = 2
    c.use_fill_caps = True
    s = c.splines.new("POLY")
    s.points.add(n - 1)
    o = bpy.data.objects.new(name, c)
    o.data.materials.append(material)
    scene.collection.objects.link(o)
    o.parent = parent
    return o


def set_line(o, pts):
    for p, v in zip(o.data.splines[0].points, pts):
        p.co = (v[0], v[1], v[2], 1)


# ---- body (body_p's frame: x to the head, z the back, -z the belly) ----
body_p = pivot("body_p", (0, 0, 0))
body_p.rotation_mode = "QUATERNION"
body = blob("body", FUR, 0.075, (0, 0, 0), (1.45, 0.95, 0.9), body_p)
head_p = pivot("head_p", (0.12, 0, 0.025), body_p)
head = blob("head", FUR, 0.06, (0, 0, 0), (1.05, 1.0, 0.95), head_p)
snout = blob("snout", SNOUT, 0.032, (0.055, 0, -0.012), (1.1, 0.9, 0.8), head_p)
nose = blob("nose", BLACK, 0.012, (0.088, 0, -0.004), (0.8, 1.2, 0.7), head_p)
fangs = [cone(f"fang{k}", WHITE, 0.007, 0.022, (0.07, y, -0.03), head_p, (math.radians(180), 0, 0))
         for k, y in enumerate((-0.012, 0.012))]
eyes, lids, ears = [], [], []
for k, y in enumerate((-0.03, 0.03)):
    eyes.append(blob(f"eye{k}", RED, 0.016, (0.045, y, 0.02), (0.8, 1, 1), head_p, outline=False))
    lids.append(blob(f"lid{k}", FUR, 0.019, (0.043, y, 0.02), (0.8, 1, 1), head_p, outline=False))
    ep = pivot(f"ear{k}", (-0.005, y * 1.15, 0.04), head_p)
    ep.rotation_euler = (math.radians(-22 if y < 0 else 22), math.radians(-18), 0)
    ear = cone(f"earo{k}", FUR, 0.034, 0.1, (0, 0, 0), ep, (0, 0, 0), (0.55, 1, 1))
    earin = cone(f"eari{k}", EAR_IN, 0.024, 0.075, (0.008, 0, 0.004), ep, (0, 0, 0), (0.35, 1, 1))
    ears.append(ep)

# legs back from the hips; the feet (claws) together at FEET: the hang point
HIP_X, FEET = -0.08, Vector((-0.2, 0, 0))
legs = []
for k, y in enumerate((-0.03, 0.03)):
    leg = line(f"leg{k}", BONE, 4, 0.008, body_p)
    set_line(leg, [(HIP_X, y, -0.01), (-0.15, y * 1.1, 0.0), (-0.19, y * 0.6, 0.0), (FEET.x - 0.004, y * 0.4, 0.0)])
    claw = line(f"claw{k}", BONE, 4, 0.005, body_p)
    set_line(claw, [(FEET.x, y * 0.4, 0), (FEET.x - 0.016, y * 0.4, 0.004), (FEET.x - 0.02, y * 0.4, -0.01),
                    (FEET.x - 0.012, y * 0.4, -0.018)])

# ---- wings: drawn flat as (u, v) (u along the body from the shoulder, v out along the span),
# then laid round the shoulder: the span starts at angle phi (0 out level, + up) and bends
# down and in by curl (1/radius: wrapped round the belly when hanging) ----
SH = Vector((0.04, 0.045, 0.03))
KEYS = ["S", "E", "W", "T", "K2", "F2", "K3", "F3", "K4", "F4", "K5", "F5", "A", "B"]
SPREAD = dict(S=(0, 0), E=(-0.07, 0.12), W=(0.03, 0.26), T=(0.07, 0.28),
              K2=(0.06, 0.37), F2=(0.06, 0.5), K3=(0.0, 0.38), F3=(-0.06, 0.5),
              K4=(-0.05, 0.34), F4=(-0.17, 0.41), K5=(-0.06, 0.29), F5=(-0.21, 0.27),
              A=(-0.19, 0.06), B=(-0.12, 0.0))
WRAP = dict(S=(0, 0), E=(-0.11, 0.08), W=(0.05, 0.1), T=(0.085, 0.105),
            K2=(-0.05, 0.2), F2=(-0.19, 0.25), K3=(-0.06, 0.17), F3=(-0.215, 0.205),
            K4=(-0.07, 0.13), F4=(-0.225, 0.16), K5=(-0.07, 0.09), F5=(-0.22, 0.11),
            A=(-0.21, 0.04), B=(-0.12, 0.0))
FINGERS = [("K2", "F2"), ("K3", "F3"), ("K4", "F4"), ("K5", "F5")]
EDGE = ["F2", "F3", "F4", "F5", "A"]             # the trailing edge, scalloped between the tips


def shape(t_arm, t_fing):
    """the flat wing between wrapped (0) and spread (1): the arm opens first, the fingers after"""
    out = {}
    for k in KEYS:
        t = t_arm if k in ("E", "W", "T", "B") else t_fing
        out[k] = Vector(WRAP[k]).lerp(Vector(SPREAD[k]), t)
    return out


def scallop(a, b, w, n):
    """points along the trailing edge from a to b, sagging in towards the wrist w"""
    pts = []
    for i in range(n):
        s = i / n
        p = a.lerp(b, s)
        pts.append(p.lerp(w, 0.22 * math.sin(math.pi * s)))
    return pts


def lay(p, side, phi, curl, dy):
    u, v = p.x, p.y
    if abs(curl) < 1e-4:
        Y, Z = v * math.cos(phi), v * math.sin(phi)
    else:
        Y = (math.sin(phi) - math.sin(phi - curl * v)) / curl
        Z = (math.cos(phi - curl * v) - math.cos(phi)) / curl
    return Vector((SH.x + u, side * (SH.y + dy + Y), SH.z + Z))


wings = []
for side in (1, -1):
    me = bpy.data.meshes.new(f"membrane{side}")
    o = bpy.data.objects.new(f"membrane{side}", me)
    o.data.materials.append(MEMBRANE)
    scene.collection.objects.link(o)
    o.parent = body_p
    sol = o.modifiers.new("thick", "SOLIDIFY")
    sol.thickness = 0.006
    sol.offset = 0
    bones = dict(arm=line(f"arm{side}", BONE, 9, 0.0085, body_p), thumb=line(f"thumb{side}", BONE, 3, 0.006, body_p))
    for k, (kn, tip) in enumerate(FINGERS):
        bones[tip] = line(f"finger{side}{k}", BONE, 9, 0.0055, body_p)
    edge = line(f"edge{side}", BLACK, 4 * 6 + 1, 0.0035, body_p)
    wings.append(dict(side=side, mesh=me, bones=bones, edge=edge))


def seg(pts, n):
    """n points evenly along a polyline (by index) through pts"""
    out = []
    m = len(pts) - 1
    for i in range(n):
        s = i / (n - 1) * m
        j = min(int(s), m - 1)
        out.append(pts[j].lerp(pts[j + 1], s - j))
    return out


def build_wing(w, P, phi, curl, dy):
    side = w["side"]
    L = lambda p: lay(p, side, phi, curl, dy)
    # membrane: flat triangles (u, v), subdivided, then laid round
    sc = {}
    for a, b in zip(EDGE, EDGE[1:]):
        sc[a + b] = P[a].lerp(P[b], 0.5).lerp(P["W"] if b != "A" else P["E"], 0.22)
    tri = []
    for a, b in zip(EDGE[:-2], EDGE[1:-1]):
        tri += [("W", a, a + b), ("W", a + b, b)]
    tri += [("W", "F5", "F5A"), ("W", "F5A", "E"), ("E", "F5A", "A"), ("E", "A", "B"), ("E", "B", "S"),
            ("S", "W", "E"), ("W", "T", "F2")]
    pts = dict(P)
    pts.update(sc)
    bm = bmesh.new()
    vs = {k: bm.verts.new((p.x, p.y, 0)) for k, p in pts.items()}
    for t in tri:
        try:
            bm.faces.new([vs[k] for k in t])
        except ValueError:
            pass
    bmesh.ops.subdivide_edges(bm, edges=bm.edges[:], cuts=3, use_grid_fill=True)
    for v in bm.verts:
        v.co = L(Vector((v.co.x, v.co.y)))
    bm.to_mesh(w["mesh"])
    bm.free()
    w["mesh"].update()
    b = w["bones"]
    set_line(b["arm"], [L(p) for p in seg([P["S"], P["E"], P["W"]], 9)])
    set_line(b["thumb"], [L(P["W"]), L(P["W"].lerp(P["T"], 0.6)), L(P["T"])])
    for kn, tip in FINGERS:
        set_line(b[tip], [L(p) for p in seg([P["W"], P[kn], P[tip]], 9)])
    e = []
    for a, bb in zip(EDGE, EDGE[1:]):
        e += scallop(P[a], P[bb], P["W"] if bb != "A" else P["E"], 6)
    e.append(P["A"])
    set_line(w["edge"], [L(p) for p in e])


# ---- look: as bird.py / frog.py ----
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
    sol.thickness = -0.006 * 2.6 / max(max(o.scale), 0.3)
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

# body orientations: hanging head down, the belly (and the face) to the viewer; flying level
Q_HANG = Matrix(((0, -1, 0), (0, 0, 1), (-1, 0, 0))).to_quaternion()
Q_FLY = Quaternion((0, 1, 0), math.radians(-8))
T_HANG = -(Q_HANG @ FEET)                         # the feet on the hang point (the rig's origin)
T_FLY = Vector(FLY_AT)
# wing lay: wrapped (down round the belly) / flying
LAY_WRAP = (math.radians(-35), 1 / 0.075, 0.035)
FLY_PHI = 52                                     # the beat, up/down degrees


def pose(open_=1.0, t_arm=None, t_fing=None, phi=0.0, curl=0.0, dy=0.0, q=Q_FLY, at=T_FLY, sway=0.0,
         blink=False, ear=0.0, head_up=0.0):
    """open_ 0 (wrapped) .. 1 (spread): the flat wing shape (t_arm / t_fing to stagger it); phi,
    curl, dy: how the wing lies round the shoulder; q, at: the body (from the hang point);
    sway: degrees about the hang point, to and fro; ear: one ear's twitch (degrees)."""
    P = shape(open_ if t_arm is None else t_arm, open_ if t_fing is None else t_fing)
    for w in wings:
        build_wing(w, P, phi, curl, dy)
    s = Quaternion((0, 1, 0), math.radians(sway))
    body_p.rotation_quaternion = s @ q
    body_p.location = s @ Vector(at)
    head_p.rotation_euler = (0, math.radians(-head_up), 0)
    for lid in lids:
        lid.hide_render = not blink
    ears[1].rotation_euler.y = math.radians(-18 - ear)


def clamp01(v):
    return max(0.0, min(1.0, v))


def smooth(v):
    v = clamp01(v)
    return v * v * (3 - 2 * v)


def lay_mix(t, phi_fly):
    return (LAY_WRAP[0] + (math.radians(phi_fly) - LAY_WRAP[0]) * t, LAY_WRAP[1] * (1 - t) ** 1.5,
            LAY_WRAP[2] * (1 - t))


def f_hang(i, n):
    p = i / n
    phi, curl, dy = lay_mix(0, 0)
    ear = 30 * math.sin(math.pi * clamp01((p - 0.15) / 0.12)) + 20 * math.sin(math.pi * clamp01((p - 0.3) / 0.1))
    pose(open_=0.0, phi=phi, curl=curl, dy=dy, q=Q_HANG, at=T_HANG, sway=4 * math.sin(2 * math.pi * p),
         blink=(i in (n - 5, n - 4)), ear=ear, head_up=-75)


def f_fly(i, n):
    a = math.cos(2 * math.pi * i / n)              # 1 up .. -1 down
    up = clamp01(-math.sin(2 * math.pi * i / n))   # on the way up: the wings half folded
    bob = -0.03 * a
    pose(open_=1 - 0.3 * up, phi=math.radians(FLY_PHI * a), at=T_FLY + Vector((0, 0, bob)))


def f_unfold(i, n):
    p = i / (n - 1)
    t = smooth(p * 1.15)                           # the body: let go, swung up level
    phi, curl, dy = lay_mix(smooth((p - 0.1) / 0.75), FLY_PHI)
    drop = 0.12 * math.sin(math.pi * clamp01(p / 0.9)) ** 1.5   # it falls a little before the wings catch it
    at = T_HANG.lerp(T_FLY + Vector((0, 0, -0.03)), t) + Vector((0, 0, -drop))
    pose(t_arm=smooth((p - 0.05) / 0.6), t_fing=smooth((p - 0.25) / 0.65), phi=phi, curl=curl, dy=dy,
         q=Q_HANG.slerp(Q_FLY, t), at=at, head_up=-75 * (1 - smooth(p / 0.6)))


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
    json.dump({"view": "front", "model": "bat.py", "clips": meta,
               "unit_px": PX, "origin_px": [PX * -X_LO, PX * TOP]},
              open(os.path.join(d, "clips.json"), "w"), indent=1)


bake({"hang": (24, 8, True, f_hang), "unfold": (14, 12, False, f_unfold), "fly": (8, 16, True, f_fly)})
print("BAKED", KIND, OUT, RES)
