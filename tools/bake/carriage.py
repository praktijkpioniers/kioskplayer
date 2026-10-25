# Bake a pumpkin carriage pulled by two mice for the witch scene in themes/engine.lua (a pumpkin
# jumps into her cauldron, in a puff the carriage stands there; it drives off over the screens,
# stops, someone steps out, and in the end it's a pumpkin again):
#
#   blender -b -P tools/bake/carriage.py -- <out_dir> [size]
#
# <out_dir>/carriage/: "drive" (loop: the wheels turn, the mice trot, the coach rocks), "stand"
# (loop: the mice breathe, twitch their tails), "door" (the door swings open: played backwards it
# shuts). Seen from the side, turned a little to the viewer, facing right. Same look and world
# unit as cauldron.py / kaykit.py (size is the height of a 2.6 unit frame); the coach's door is
# world x = 0 (origin_px).

import bpy, bmesh, json, math, os, sys

argv = sys.argv[sys.argv.index("--") + 1:]
OUT = os.path.abspath(argv[0])
SIZE = int(argv[1]) if len(argv) > 1 else 384
FRAME_H = 2.6
X_LO, X_HI = -1.25, 2.75
PX = SIZE / 2.6                     # pixels per world unit, as the others
WR = 0.36                           # wheel radius
SPOKES = 8
TURN = 4 * 2 * math.pi / SPOKES     # the wheels' turn per drive loop (seamless: whole spokes)
STRIDE = TURN * WR                  # world units driven per loop

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def mat(name, rgb, rough=0.6):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*[(v / 255) ** 2.2 for v in rgb], 1)
    b.inputs["Roughness"].default_value = rough
    return m


ORANGE, ORANGE2 = mat("orange", (240, 128, 28)), mat("orange2", (222, 104, 20))
GOLD, GREEN = mat("gold", (236, 192, 64), 0.35), mat("green", (70, 130, 40))
GLASS, DARK = mat("glass", (60, 50, 90), 0.2), mat("dark", (40, 26, 20))
GREY, GREY2 = mat("grey", (160, 158, 170)), mat("grey2", (196, 194, 204))
PINK, BLACK, WHITE = mat("pink", (240, 150, 165)), mat("black", (16, 16, 20)), mat("white", (250, 250, 240))
RED = mat("red", (190, 40, 50))

rig = bpy.data.objects.new("rig", None)          # everything hangs off this (the turn to the viewer)
scene.collection.objects.link(rig)
parts, no_ink = [], []


def obj(name, me, material, at, parent, scale=(1, 1, 1), rot=(0, 0, 0)):
    o = bpy.data.objects.new(name, me)
    o.data.materials.append(material)
    scene.collection.objects.link(o)
    o.parent = parent
    o.location = at
    o.scale = scale
    o.rotation_euler = rot
    parts.append(o)
    return o


def blob(name, material, r, at, scale=(1, 1, 1), parent=rig, rot=(0, 0, 0), seg=20):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=seg // 2, radius=r)
    bm.to_mesh(me)
    bm.free()
    return obj(name, me, material, at, parent, scale, rot)


def rod(name, material, r, length, at, rot, parent=rig):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=10, radius1=r, radius2=r, depth=length)
    bm.to_mesh(me)
    bm.free()
    return obj(name, me, material, at, parent, rot=rot)


def torus(name, material, R, r, at, parent):
    bpy.ops.mesh.primitive_torus_add(major_radius=R, minor_radius=r, major_segments=32, minor_segments=8)
    o = bpy.context.active_object
    bpy.context.collection.objects.unlink(o)
    o.data.materials.append(material)
    scene.collection.objects.link(o)
    o.parent = parent
    o.location = at
    o.rotation_euler = (math.pi / 2, 0, 0)        # (its axis along y: a wheel)
    parts.append(o)
    return o


def pivot(name, at, parent=rig):
    e = bpy.data.objects.new(name, None)
    scene.collection.objects.link(e)
    e.parent = parent
    e.location = at
    return e


# ---- the coach: a pumpkin of lobes on a gold frame, a door on the near side ----
coach = pivot("coach", (0, 0, 0))
BODY_Z, BR = 1.12, 0.74
lobes = 10
for k in range(lobes):
    a = 2 * math.pi * k / lobes
    blob(f"lobe{k}", ORANGE if k % 2 else ORANGE2, BR * 0.62,
         (math.cos(a) * BR * 0.4, math.sin(a) * BR * 0.32, BODY_Z),
         (1.1, 1.0, 1.05), coach)
blob("core", ORANGE, BR * 0.9, (0, 0, BODY_Z), (1.15, 0.92, 0.9), coach)
rod("stem", GREEN, 0.06, 0.3, (0.05, 0, BODY_Z + BR * 0.82 + 0.1), (0, math.radians(15), 0), coach)
blob("curl", GREEN, 0.07, (0.16, 0, BODY_Z + BR * 0.82 + 0.22), (1.6, 0.6, 0.6), coach)
blob("crown", GOLD, 0.09, (-0.02, 0, BODY_Z + BR * 0.84), (1.3, 1.3, 0.5), coach)
# frame: a gold bar under it, a seat for the coachman (empty) at the front, lamps
rod("bar", GOLD, 0.04, 1.6, (0, -0.0, WR + 0.12), (0, math.pi / 2, 0), coach)
for k, x in enumerate((-0.55, 0.55)):
    rod(f"strut{k}", GOLD, 0.035, 0.42, (x * 0.8, -0.0, WR + 0.32), (0, math.radians(-25 if x < 0 else 25), 0), coach)
blob("lamp", GOLD, 0.06, (0.72, -0.5, BODY_Z + 0.25), (1, 1, 1.4), coach)
blob("lamp_glow", mat("glow", (255, 230, 120)), 0.045, (0.72, -0.55, BODY_Z + 0.25), (1, 1, 1.2), coach)
# the door: a frame (fixed), the door itself on a hinge at its front edge, a round window
door_y = -BR * 0.84
for k, (x, z, sx, sz) in enumerate([(0, BODY_Z + 0.42, 0.4, 0.05), (0, BODY_Z - 0.42, 0.4, 0.05),
                                    (-0.22, BODY_Z, 0.05, 0.45), (0.22, BODY_Z, 0.05, 0.45)]):
    blob(f"doorframe{k}", GOLD, 0.5, (x, door_y - 0.03, z), (sx, 0.08, sz), coach, seg=12)
blob("doorway", DARK, 0.5, (0, door_y + 0.02, BODY_Z), (0.4, 0.06, 0.82), coach, seg=12)
hinge = pivot("hinge", (0.2, door_y - 0.06, BODY_Z), coach)
blob("door", ORANGE2, 0.5, (-0.2, 0, 0), (0.4, 0.07, 0.8), hinge, seg=16)
blob("window", GLASS, 0.12, (-0.2, -0.04, 0.12), (1, 0.3, 1.15), hinge)
blob("handle", GOLD, 0.03, (-0.33, -0.05, -0.08), (1, 1, 1), hinge)
blob("step", GOLD, 0.5, (0, door_y - 0.08, WR + 0.22), (0.22, 0.12, 0.03), coach, seg=10)

# wheels: gold rims and spokes, the near pair in front of the coach, the far pair behind
wheels = []
for k, (x, y) in enumerate([(-0.5, -0.62), (0.5, -0.62), (-0.5, 0.62), (0.5, 0.62)]):
    w = pivot(f"wheel{k}", (x, y, WR), coach)
    torus(f"rim{k}", GOLD, WR, 0.035, (0, 0, 0), w)
    blob(f"hub{k}", GOLD, 0.07, (0, 0, 0), (1, 0.6, 1), w)
    for s in range(SPOKES):
        a = math.pi * 2 * s / SPOKES
        rod(f"spoke{k}_{s}", GOLD, 0.016, WR, (math.cos(a) * WR / 2, 0, math.sin(a) * WR / 2),
            (0, math.pi / 2 - a, 0), w)
    wheels.append(w)

# ---- the mice: two (one behind the other, side by side in depth), on a gold shaft ----
rod("shaft", GOLD, 0.025, 1.1, (1.2, -0.05, 0.62), (0, math.pi / 2 + 0.25, 0), coach)
mice = []
for k, (mx, my) in enumerate([(1.85, -0.28), (2.0, 0.3)]):
    m = pivot(f"mouse{k}", (mx, my, 0), rig)
    body_p = pivot(f"mbody{k}", (0, 0, 0.42), m)
    blob(f"mb{k}", GREY, 0.24, (0, 0, 0), (1.4, 0.9, 0.95), body_p)
    blob(f"mbelly{k}", GREY2, 0.18, (0.08, -0.06, -0.06), (1.2, 0.8, 0.7), body_p)
    head = pivot(f"mhead{k}", (0.34, 0, 0.1), body_p)
    blob(f"mh{k}", GREY, 0.15, (0.05, 0, 0), (1.35, 0.95, 0.95), head)
    blob(f"mnose{k}", PINK, 0.04, (0.25, 0, 0.01), (1, 1, 1), head)
    for j, ey in enumerate((-0.075, 0.075)):
        ear = blob(f"mear{k}{j}", GREY, 0.1, (-0.04, ey * 1.6, 0.14), (0.45, 1, 1), head)
        blob(f"mearin{k}{j}", PINK, 0.07, (-0.0, ey * 1.6 - 0.01, 0.14), (0.3, 1, 1), head)
        blob(f"meye{k}{j}", BLACK, 0.03, (0.12, ey, 0.06), (1, 1, 1.2), head)
        no_ink.append(parts[-1])
    blob(f"collar{k}", RED, 0.17, (0.25, 0, 0.0), (0.4, 0.95, 1.0), body_p)
    tail_p = pivot(f"mtail{k}", (-0.32, 0, 0.0), body_p)
    for s in range(7):                            # a curve of small beads, up and back
        t = s / 6
        blob(f"mt{k}_{s}", PINK, 0.03 - 0.012 * t, (-0.1 - 0.42 * t, 0, 0.25 * math.sin(math.pi * t * 0.9)), (1, 1, 1), tail_p, seg=10)
    legs = []
    for j, (lx, ly) in enumerate([(0.2, -0.12), (0.2, 0.12), (-0.18, -0.12), (-0.18, 0.12)]):
        hip = pivot(f"mhip{k}{j}", (lx, ly, -0.12), body_p)
        rod(f"mleg{k}{j}", GREY, 0.035, 0.26, (0, 0, -0.13), (0, 0, 0), hip)
        blob(f"mfoot{k}{j}", PINK, 0.04, (0.03, 0, -0.27), (1.6, 1, 0.6), hip)
        legs.append(hip)
    mice.append((m, body_p, head, tail_p, legs))

rig.rotation_euler = (0, 0, math.radians(-18))   # turned a little to the viewer

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
    if o in no_ink or "spoke" in o.name or o.name.startswith("mt"):
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


def pose(wheel=0.0, trot=None, rock=0.0, door=0.0, breathe=0.0, tail=0.0):
    """wheel: turn (radians); trot: phase 0..1 of the mice's stride (None: standing);
    rock: the coach's sway; door: 0 shut .. 1 open."""
    coach.rotation_euler = (0, rock, 0)
    coach.location.z = abs(rock) * 0.3
    for w in wheels:
        w.rotation_euler = (0, wheel, 0)
    hinge.rotation_euler = (0, 0, math.radians(-105) * door)
    for k, (m, body_p, head, tail_p, legs) in enumerate(mice):
        ph = (trot + 0.27 * k) if trot is not None else 0
        if trot is not None:
            body_p.location.z = 0.42 + 0.04 * abs(math.sin(2 * math.pi * ph))
            body_p.rotation_euler = (0, 0.08 * math.sin(2 * math.pi * ph), 0)
            for j, hip in enumerate(legs):
                o = 0.5 if j in (1, 2) else 0.0       # (diagonal pairs together: a trot)
                hip.rotation_euler = (0, 0.6 * math.sin(2 * math.pi * (ph + o)), 0)
            head.rotation_euler = (0, 0.06 * math.sin(4 * math.pi * ph), 0)
            tail_p.rotation_euler = (0, 0.25 * math.sin(2 * math.pi * ph), 0.2)
        else:
            body_p.location.z = 0.42
            body_p.rotation_euler = (0, 0, 0)
            body_p.scale = (1, 1 + 0.03 * breathe, 1 + 0.04 * breathe)
            for hip in legs:
                hip.rotation_euler = (0, 0, 0)
            head.rotation_euler = (0, -0.05 * breathe, 0.1 * tail * (1 if k else -1))
            tail_p.rotation_euler = (0, 0.15 * breathe, 0.5 * tail)


def bake(clips):
    d = os.path.join(OUT, "carriage")
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        if f.endswith(".png"):
            os.remove(os.path.join(d, f))
    meta = {}
    for name, (n, fps, loop, frame, stride) in clips.items():
        for i in range(n):
            frame(i, n)
            scene.render.filepath = os.path.join(d, f"{name}_{i:04d}.png")
            bpy.ops.render.render(write_still=True)
        meta[name] = {"files": f"{name}_*.png", "count": n, "fps": fps, "loop": loop, "stride": stride}
    json.dump({"view": "front", "model": "carriage.py", "clips": meta,
               "unit_px": PX, "origin_px": [PX * -X_LO, RES[1]]},
              open(os.path.join(d, "clips.json"), "w"), indent=1)


def f_drive(i, n):
    p = i / n
    pose(wheel=TURN * p, trot=2 * p, rock=0.025 * math.sin(4 * math.pi * p))


def f_stand(i, n):
    p = i / n
    pose(breathe=math.sin(2 * math.pi * p), tail=math.sin(4 * math.pi * p))


def f_door(i, n):
    p = i / (n - 1)
    pose(door=(1 - math.cos(math.pi * p)) / 2)


bake({"drive": (12, 12, True, f_drive, STRIDE / frame_w),
      "stand": (12, 8, True, f_stand, 0),
      "door": (8, 10, False, f_door, 0)})
print("BAKED carriage", OUT, RES)
