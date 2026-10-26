# Bake a creep - a small octopus-like thing - that crawls past outside a window in the video room
# (themes/engine.lua):
#
#   blender -b -P tools/bake/creep.py -- <out_dir> [size]
#
# <out_dir>/creep/: "crawl" (loop: seen from the side, turned a little to the viewer, going right; the
# arms reach forward, grip and pull, the head bobs; the body stays put: the engine moves the sprite
# by "stride" per loop), "peek" (stops, turns its eyes to the viewer, blinks, taps the glass three
# times with an arm and goes on: starts and ends in the crawl's first pose), "climb" (loop: seen from
# the front, arms splayed on the glass, going up; "stride" is then upwards, same scale).
# Same world unit as frog.py / kaykit.py (size is the height of a 2.6 unit frame; this frame is cut
# smaller at the same scale): about the size of a cat. World x = 0 on the ground is origin_px.

import bpy, bmesh, json, math, os, sys
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index("--") + 1:]
OUT = os.path.abspath(argv[0])
SIZE = int(argv[1]) if len(argv) > 1 else 384
FRAME_H = 1.0
X_LO, X_HI = -0.85, 0.95
PX = SIZE / 2.6                     # pixels per world unit, as the others

CRAWL_N, CRAWL_FPS = 16, 12
STRIDE = 0.3                        # world units crawled per crawl loop (0.225 / s at 12 fps)
CLIMB_N, CLIMB_FPS = 16, 12
CLIMB_STRIDE = 0.24                 # world units climbed per climb loop
TURN = math.radians(-20)            # side view: turned a little to the viewer

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def srgb(rgb):
    return (*[(v / 255) ** 2.2 for v in rgb], 1)


def mat(name, rgb, rough=0.5, emit=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = srgb(rgb)
    b.inputs["Roughness"].default_value = rough
    if emit:
        b.inputs["Emission Color"].default_value = srgb(rgb)
        b.inputs["Emission Strength"].default_value = emit
    return m


def skin(name, core, rim):
    """Dark and wet: purple facing the viewer, going green at the edges, with a glossy coat."""
    m = mat(name, core, 0.3)
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    lw = nt.nodes.new("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = 0.45
    mix = nt.nodes.new("ShaderNodeMixRGB")
    mix.inputs[1].default_value = srgb(core)
    mix.inputs[2].default_value = srgb(rim)
    nt.links.new(lw.outputs["Facing"], mix.inputs["Fac"])
    nt.links.new(mix.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Coat Weight"].default_value = 0.3
    b.inputs["Specular IOR Level"].default_value = 0.35
    b.inputs["Coat Roughness"].default_value = 0.08
    return m


SKIN = skin("skin", (46, 18, 54), (26, 70, 40))
ARM = skin("arm", (40, 18, 46), (24, 64, 36))
SUCKER = mat("sucker", (196, 150, 186), 0.35)
IRIS = mat("iris", (226, 214, 70), 0.2, emit=0.6)
PUPIL = mat("pupil", (10, 8, 12), 0.15)
LID = skin("lid", (66, 30, 74), (36, 84, 52))
ink = bpy.data.materials.new("ink")
ink.use_nodes = True
ink.use_backface_culling = True
ink.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.015, 0.01, 0.02, 1)

rig = bpy.data.objects.new("rig", None)          # everything hangs off this (the turn to the viewer)
scene.collection.objects.link(rig)
outlined = []


def blob(name, material, r, at, scale=(1, 1, 1), parent=rig, seg=24, outline=True):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=seg // 2, radius=r)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    o = bpy.data.objects.new(name, me)
    o.data.materials.append(material)
    scene.collection.objects.link(o)
    o.parent = parent
    o.location = at
    o.scale = scale
    if outline:
        outlined.append(o)
    return o


def pivot(name, at, parent=rig):
    e = bpy.data.objects.new(name, None)
    scene.collection.objects.link(e)
    e.parent = parent
    e.location = at
    return e


# ── head: the arms' crown at the pivot, the eyes on top of it, the mantle a bag behind and up ────────
CROWN = Vector((0.1, 0, 0.17))
head_p = pivot("head_p", CROWN)
mantle_p = pivot("mantle_p", (-0.02, 0, 0.1), head_p)
mantle = blob("mantle", SKIN, 0.2, (-0.17, 0, 0.14), (1.45, 1.05, 1.15), mantle_p)
mantle.rotation_euler = (0, math.radians(-28), 0)
warts = [blob(f"wart{i}", SKIN, 0.035, at, (1, 1, 0.6), mantle_p, 12)
         for i, at in enumerate([(-0.12, -0.17, 0.33), (-0.3, -0.12, 0.27), (-0.2, -0.19, 0.18)])]
for w in warts:
    w.rotation_euler = (math.radians(70), 0, 0)
crown = blob("crown", SKIN, 0.13, (0.02, 0, 0.02), (1.15, 1.1, 0.8), head_p)
EYE_R = 0.065
eyes, pupils, lids = [], [], []
for k, y in enumerate((-0.085, 0.085)):
    socket = blob(f"socket{k}", SKIN, 0.075, (0.06, y, 0.12), (1, 1, 1), head_p)
    e = blob(f"eye{k}", IRIS, EYE_R, (0.08, y * 1.15, 0.14), (1, 1, 1), head_p, outline=False)
    p = blob(f"pupil{k}", PUPIL, 0.04, (0, 0, 0), (1, 1, 1), head_p, 16, outline=False)
    lid = blob(f"lid{k}", LID, EYE_R * 1.1, e.location, (1, 1, 1), head_p)
    eyes.append(e); pupils.append(p); lids.append(lid)


# ── arms: bevelled poly curves, posed per frame from root, tip and a curl ────────────────────────────
NPTS, NCURL, NSUCK = 18, 7, 7
R0, R1 = 0.055, 0.006


def arm_obj(name):
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = 1.0
    cu.bevel_resolution = 3
    cu.use_fill_caps = True
    sp = cu.splines.new("POLY")
    sp.points.add(NPTS + NCURL - 1)
    sp.use_smooth = True
    o = bpy.data.objects.new(name, cu)
    o.data.materials.append(ARM)
    scene.collection.objects.link(o)
    o.parent = rig
    outlined.append(o)
    return o


ARMS = []
for s in (-1, 1):                     # -1: the near side (to the camera), +1 far
    for i in range(4):                # 0 front .. 3 back
        ARMS.append({"s": s, "i": i, "obj": arm_obj(f"arm{s}{i}"),
                     "suckers": [blob(f"suck{s}{i}{k}", SUCKER, 1.0, (0, 0, 0), (1, 1, 1), rig, 10, False)
                                 for k in range(NSUCK)]})


def bez(p0, p1, p2, p3, t):
    u = 1 - t
    return p0 * u ** 3 + p1 * 3 * u * u * t + p2 * 3 * u * t * t + p3 * t ** 3


def rot(v, axis, a):
    return v * math.cos(a) + axis.cross(v) * math.sin(a) + axis * axis.dot(v) * (1 - math.cos(a))


def pose_arm(arm, root, c1, c2, tip, curl, curl_len, axis, ground=True):
    """Centreline: a bezier root -> tip, then a curl of curl_len turning about axis by curl radians."""
    pts = [bez(root, c1, c2, tip, k / (NPTS - 1)) for k in range(NPTS)]
    t = (pts[-1] - pts[-2]).normalized()
    p = pts[-1]
    step = curl_len / NCURL
    for k in range(NCURL):
        t = rot(t, axis, curl / NCURL * (1 + 0.6 * k / NCURL))
        p = p + t * step
        pts.append(p)
    n = len(pts)
    rad = [R0 + (R1 - R0) * (k / (n - 1)) ** 0.65 for k in range(n)]
    if ground:      # lie on the sill, not in it
        pts = [Vector((q.x, q.y, max(q.z, r))) for q, r in zip(pts, rad)]
    sp = arm["obj"].data.splines[0]
    for k, (q, r) in enumerate(zip(pts, rad)):
        sp.points[k].co = (q.x, q.y, q.z, 1)
        sp.points[k].radius = r
    # suckers along the underside (away from the curl), half sticking out: a bumpy edge
    for k, sk in enumerate(arm["suckers"]):
        j = round(4 + (n - 6) * k / (NSUCK - 1))
        tg = (pts[min(j + 1, n - 1)] - pts[j - 1]).normalized()
        under = -axis.cross(tg).normalized()
        sk.location = pts[j] + under * rad[j] * 0.7
        sk.scale = (rad[j] * 0.6,) * 3


# ── look: as kaykit.py / frog.py, a little more shine ───────────────────────────────────────────────
world = bpy.data.worlds.new("w"); scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (1, 1, 1, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.9
sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
sun.data.energy = 2.5
sun.data.angle = math.radians(3)
sun.rotation_euler = (math.radians(50), math.radians(-25), math.radians(-30))
scene.collection.objects.link(sun)
rim = bpy.data.objects.new("rim", bpy.data.lights.new("rim", "SUN"))
rim.data.energy = 1.0
rim.data.color = (0.6, 1.0, 0.7)
rim.rotation_euler = (math.radians(-55), math.radians(30), math.radians(200))
scene.collection.objects.link(rim)
for o in outlined:
    o.data.materials.append(ink)
    sol = o.modifiers.new("outline", "SOLIDIFY")
    sol.thickness = -0.008 * 2.6 / (max(o.scale) if o.type == "MESH" else 1.0)
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


# ── posing ───────────────────────────────────────────────────────────────────────────────────────────
def head(at=(0, 0, 0), yaw=0.0, pitch=0.0, squash=0.0, mantle_tilt=0.0, gaze=None, blink=False, turn=TURN):
    """at: offset of the crown; yaw: the head turned (radians, - to the viewer), pitch (+ nose up);
    squash: + flatter and longer; gaze: world direction the pupils look in (None: straight ahead)."""
    rig.rotation_euler = (0, 0, turn)
    head_p.location = CROWN + Vector(at)
    head_p.rotation_euler = (0, -pitch, yaw)
    mantle_p.rotation_euler = (0, -mantle_tilt, 0)
    mantle_p.scale = (1 + 0.12 * squash, 1 + 0.04 * squash, 1 - 0.12 * squash)
    to_local = (Matrix.Rotation(turn, 3, "Z") @ Matrix.Rotation(yaw, 3, "Z") @ Matrix.Rotation(-pitch, 3, "Y")).inverted()
    for e, p, lid in zip(eyes, pupils, lids):
        out = (e.location - Vector((0.02, 0, 0.1))).normalized()          # the eye's own forward
        g = (to_local @ Vector(gaze)).normalized() if gaze else Vector((1, 0, 0.1)).normalized()
        d = (out * 0.35 + g).normalized()
        p.location = e.location + d * EYE_R * 0.9
        # the pupil a flat bar across the eye (an octopus' slit), facing out along d
        p.rotation_mode = "QUATERNION"
        ax = Vector((0, 0, 1)).cross(d).normalized()          # the bar lies level across the eye
        p.rotation_quaternion = Matrix((ax, d.cross(ax), d)).transposed().to_quaternion()
        p.scale = (1.15, 0.5, 0.35)
        lid.hide_render = not blink
        p.hide_render = blink


def crawl_tip(arm, ph):
    """Where arm's tip is at crawl phase ph (rig coords), how high it is lifted (0..1) and its curl."""
    s, i = arm["s"], arm["i"]
    rest = Vector(([0.66, 0.32, -0.12, -0.5][i], s * [0.1, 0.24, 0.26, 0.14][i], 0))
    off = 0.0 if (i + (s > 0)) % 2 == 0 else 0.5
    p = (ph + off + 0.13 * i) % 1.0
    duty = 0.62
    if p < duty:                     # gripping: slides back at the crawl speed (still in the world)
        x = STRIDE / 2 - STRIDE * p / duty
        lift = 0.0
    else:                            # reaching forward again, lifted, the tip curled up more
        q = (p - duty) / (1 - duty)
        x = -STRIDE / 2 + STRIDE * q * q * (3 - 2 * q)
        lift = math.sin(math.pi * q)
    hump = math.sin(math.pi * p / duty) if p < duty else 0.0
    return rest + Vector((x, 0, 0)), lift, hump


def arm_from_tip(arm, root, tip, lift, extra_curl=0.0, reach=1.0, hump=0.0):
    i = arm["i"]
    d = Vector((tip.x - root.x, tip.y - root.y, 0))
    dist = d.length
    d = d.normalized()
    hi = (0.22 if i == 0 else 0.13) * lift * reach
    tip = tip + Vector((0, 0, hi))
    c1 = root + d * 0.12 * dist + Vector((0, 0, -0.16 + 0.05 * lift))
    c2 = tip - d * 0.4 * dist + Vector((0, 0, 0.05 * lift + 0.11 * hump))
    axis = d.cross(Vector((0, 0, 1))).normalized()      # curls up and back
    curl = math.radians(110 + 140 * lift + extra_curl)
    pose_arm(arm, root, c1, c2, tip, curl, 0.12 + 0.03 * (1 - lift), axis)


def arm_root(arm, at=Vector()):
    s, i = arm["s"], arm["i"]
    a = math.radians([35, 80, 115, 150][i])
    return CROWN + Vector(at) + Vector((0.07 * math.cos(a), s * 0.06 * math.sin(a) + 0.0, -0.06))


def crawl_pose(ph, settle=0.0):
    """settle 0..1: every arm put down where it is (no lift), for the stop in peek."""
    bob = math.sin(4 * math.pi * ph)
    at = (0.025 * math.sin(4 * math.pi * ph + 0.6), 0, 0.025 * bob * (1 - settle))
    head(at=at, pitch=0.06 * bob * (1 - settle), squash=0.5 * bob * (1 - settle),
         mantle_tilt=0.08 * math.sin(4 * math.pi * ph - 1.0) * (1 - settle))
    for arm in ARMS:
        tip, lift, hump = crawl_tip(arm, ph)
        arm_from_tip(arm, arm_root(arm, at), tip, lift * (1 - settle), hump=hump * (1 - settle))
    return at


def f_crawl(i, n):
    crawl_pose(i / n)


def smooth(a, b, u):
    u = min(1.0, max(0.0, (u - a) / (b - a)))
    return u * u * (3 - 2 * u)


def f_peek(i, n):
    u = i / (n - 1)
    settle = smooth(0.0, 0.12, u) * (1 - smooth(0.88, 1.0, u))
    look = smooth(0.1, 0.25, u) * (1 - smooth(0.8, 0.93, u))
    at = crawl_pose(0.0, settle)
    yaw = math.radians(-62) * look
    blink = i in (round(0.3 * (n - 1)), round(0.31 * (n - 1)) + 1, round(0.72 * (n - 1)), round(0.76 * (n - 1)))
    head(at=(at[0], 0, at[2] + 0.03 * look), yaw=yaw, pitch=0.12 * look, squash=-0.25 * look,
         gaze=(0.3 * (1 - look), -1, 0.05), blink=blink)
    # the front near arm goes up and taps the glass three times (towards the viewer, -y)
    arm = ARMS[0]
    up = smooth(0.34, 0.44, u) * (1 - smooth(0.66, 0.78, u))
    tap = 0.0
    if 0.44 < u < 0.66:
        tap = abs(math.sin(math.pi * 3 * (u - 0.44) / 0.22))
    if up > 0:
        root = arm_root(arm, at)
        tip = Vector((0.55, -0.32 - 0.07 * tap, 0.46 - 0.09 * tap))
        c1 = root + Vector((0.14, -0.05, -0.12))
        c2 = tip + Vector((-0.02, 0.06, -0.24))
        rest_tip, _, _ = crawl_tip(arm, 0.0)
        tip = rest_tip.lerp(tip, up)
        c2 = (rest_tip - Vector((0.2, 0, 0))).lerp(c2, up)
        c1 = (root + Vector((0.05, 0, -0.16))).lerp(c1, up)
        lie = Vector((rest_tip.x - root.x, rest_tip.y - root.y, 0)).normalized().cross(Vector((0, 0, 1)))
        axis = lie.lerp(Vector((0, 1, 0)), up).normalized()
        pose_arm(arm, root, c1, c2, tip, math.radians(70 + 80 * (1 - up) - 50 * tap), 0.12, axis.normalized())


# climb: seen from the front (no turn), on the glass at y = WALL; the eyes look out, the mantle above
WALL = 0.12
CLIMB_C = Vector((0.05, 0, 0.42))
CLIMB_ARMS = [(-1, 0, 62), (-1, 1, 25), (-1, 2, -30), (-1, 3, -70), (1, 0, 118), (1, 1, 155), (1, 2, 210), (1, 3, 250)]


def f_climb(i, n):
    ph = i / n
    bob = math.sin(4 * math.pi * ph)
    at = Vector((0, 0, 0.03 * bob))
    rig.rotation_euler = (0, 0, 0)
    head(at=(CLIMB_C - CROWN) + at + Vector((0, -0.05, 0)), yaw=math.radians(-90), pitch=math.radians(10),
         squash=0.4 * bob, mantle_tilt=math.radians(-35) + 0.08 * math.sin(4 * math.pi * ph - 1.0),
         gaze=(0, -1, -0.15), turn=0.0, blink=(i == n - 3))
    c = CLIMB_C + at
    for arm, (s, k, ang) in zip(ARMS, CLIMB_ARMS):
        a = math.radians(ang)
        out = Vector((math.cos(a), 0, math.sin(a)))
        reach = 0.42 if abs(ang - 90) < 60 else (0.36 if math.sin(a) > -0.3 else 0.34)
        rest = Vector((c.x, WALL, CLIMB_C.z)) + out * reach
        off = 0.0 if (k + (s > 0)) % 2 == 0 else 0.5
        p = (ph + off) % 1.0
        duty = 0.62
        if p < duty:
            z = CLIMB_STRIDE / 2 - CLIMB_STRIDE * p / duty
            lift = 0.0
        else:
            q = (p - duty) / (1 - duty)
            z = -CLIMB_STRIDE / 2 + CLIMB_STRIDE * q * q * (3 - 2 * q)
            lift = math.sin(math.pi * q)
        tip = rest + Vector((0, -0.12 * lift, z))
        root = c + Vector((0.05 * math.cos(a), WALL * 0.4, 0.05 * math.sin(a) - 0.05))
        dv = tip - root
        side = Vector((0, 1, 0)).cross(dv).normalized()
        c1 = root + dv * 0.3 + side * 0.04 + Vector((0, 0.06, 0))
        c2 = root + dv * 0.75 - side * 0.04 * (1 - lift)
        axis = Vector((0, -s, 0))
        pose_arm(arm, root, c1, c2, tip, math.radians(100 + 120 * lift), 0.1, axis, ground=False)


def bake(clips):
    d = os.path.join(OUT, "creep")
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        if f.endswith(".png"):
            os.remove(os.path.join(d, f))
    only = os.environ.get("CREEP_ONLY")
    meta = {}
    for name, (n, fps, loop, frame, stride) in clips.items():
        if not only or name in only.split(","):
            for i in range(n):
                frame(i, n)
                scene.render.filepath = os.path.join(d, f"{name}_{i:04d}.png")
                bpy.ops.render.render(write_still=True)
        # stride: world units per loop as a fraction of the full render width (themes.py)
        meta[name] = {"files": f"{name}_*.png", "count": n, "fps": fps, "loop": loop, "stride": stride / frame_w}
    json.dump({"view": "front", "model": "creep.py", "clips": meta,
               "unit_px": PX, "origin_px": [PX * -X_LO, RES[1]]},
              open(os.path.join(d, "clips.json"), "w"), indent=1)


bake({"crawl": (CRAWL_N, CRAWL_FPS, True, f_crawl, STRIDE),
      "peek": (48, 12, False, f_peek, 0.0),
      "climb": (CLIMB_N, CLIMB_FPS, True, f_climb, CLIMB_STRIDE)})
print("BAKED creep", OUT, RES)
