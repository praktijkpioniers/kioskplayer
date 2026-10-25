# Bake a cartoon frog for the witch scene in themes/engine.lua (it jumps out of her cauldron and
# hops off):
#
#   blender -b -P tools/bake/frog.py -- <out_dir> [size]
#
# <out_dir>/frog/: "sit" (loop: breathing, a blink), "croak" (the throat swells), "hop" (crouch,
# legs stretched out, tucked in again: the engine moves it along and up). Seen from the side,
# turned a little to the viewer, facing right. Same look and world unit as cauldron.py / kaykit.py
# (size is the height of a 2.6 unit frame; the frog's frame is cut smaller at the same scale).

import bpy, bmesh, json, math, os, sys

argv = sys.argv[sys.argv.index("--") + 1:]
OUT = os.path.abspath(argv[0])
SIZE = int(argv[1]) if len(argv) > 1 else 384
FRAME_H = 0.75
X_LO, X_HI = -0.55, 0.55
PX = SIZE / 2.6                     # pixels per world unit, as the others

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def mat(name, rgb):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*[(v / 255) ** 2.2 for v in rgb], 1)
    b.inputs["Roughness"].default_value = 0.6
    return m


GREEN, BELLY, DARK = mat("green", (92, 176, 62)), mat("belly", (214, 232, 150)), mat("dark", (52, 110, 40))
WHITE, BLACK, PINK = mat("white", (250, 250, 240)), mat("black", (16, 16, 20)), mat("pink", (230, 120, 130))

rig = bpy.data.objects.new("rig", None)          # everything hangs off this (the turn to the viewer)
scene.collection.objects.link(rig)
parts = []


def blob(name, material, r, at, scale=(1, 1, 1), parent=rig):
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
    parts.append(o)
    return o


def pivot(name, at, parent=rig):
    e = bpy.data.objects.new(name, None)
    scene.collection.objects.link(e)
    e.parent = parent
    e.location = at
    return e


# body: a fat drop leaning forward; head in front; belly; throat
body_p = pivot("body_p", (0, 0, 0.12))
body = blob("body", GREEN, 0.2, (0, 0, 0.06), (1.15, 0.95, 0.75), body_p)
belly = blob("belly", BELLY, 0.17, (0.05, -0.05, 0.02), (1.05, 0.85, 0.6), body_p)
head = blob("head", GREEN, 0.15, (0.17, 0, 0.13), (1.1, 1.05, 0.8), body_p)
throat = blob("throat", BELLY, 0.08, (0.22, -0.02, 0.06), (1, 1, 0.8), body_p)
spots = [blob(f"spot{i}", DARK, 0.04, at, (1, 1, 0.5), body_p)
         for i, at in enumerate([(-0.06, -0.12, 0.17), (-0.15, -0.1, 0.1), (0.02, -0.15, 0.13)])]
mouth = blob("mouth", BLACK, 0.12, (0.22, -0.035, 0.105), (1.05, 1.0, 0.07), body_p)
eyes, lids, pupils = [], [], []
for k, y in enumerate((-0.08, 0.08)):
    e = blob(f"eye{k}", WHITE, 0.065, (0.16, y, 0.25), (1, 1, 1), body_p)
    p = blob(f"pupil{k}", BLACK, 0.032, (0.21, y - 0.03, 0.26), (1, 1, 1.3), body_p)
    lid = blob(f"lid{k}", GREEN, 0.07, (0.16, y, 0.25), (1, 1, 1), body_p)
    eyes.append(e); pupils.append(p); lids.append(lid)

# legs: thigh + shin + foot on pivots (back legs fold up beside the body); thin front legs
legs = []
for k, y in enumerate((-0.15, 0.15)):
    hip = pivot(f"hip{k}", (-0.12, y, 0.1), body_p)
    thigh = blob(f"thigh{k}", GREEN, 0.09, (0.04, 0, 0), (1.5, 0.7, 0.8), hip)
    knee = pivot(f"knee{k}", (0.12, 0, -0.02), hip)
    shin = blob(f"shin{k}", GREEN, 0.06, (-0.08, 0, 0), (1.6, 0.6, 0.6), knee)
    ankle = pivot(f"ankle{k}", (-0.17, 0, 0), knee)
    foot = blob(f"foot{k}", DARK, 0.05, (0.06, 0, -0.01), (1.8, 0.9, 0.35), ankle)
    shoulder = pivot(f"shoulder{k}", (0.13, y * 0.7, 0.0), body_p)
    arm = blob(f"arm{k}", GREEN, 0.035, (0.02, 0, -0.06), (0.8, 0.8, 1.8), shoulder)
    hand = blob(f"hand{k}", DARK, 0.04, (0.05, 0, -0.13), (1.5, 1, 0.4), shoulder)
    legs.append((hip, knee, ankle, shoulder))

rig.rotation_euler = (0, 0, math.radians(-25))   # turned a little to the viewer

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
    if o in pupils or o is mouth:
        continue
    o.data.materials.append(ink)
    sol = o.modifiers.new("outline", "SOLIDIFY")
    sol.thickness = -0.008 * 2.6 / max(o.scale)
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


def pose(crouch=0.0, stretch=0.0, lean=0.0, breathe=0.0, throat_s=1.0, blink=False):
    """crouch 0..1 (legs folded tighter, body low), stretch 0..1 (legs kicked out behind),
    lean: body pitch (radians, + nose up)."""
    body_p.location.z = 0.12 - 0.03 * crouch + 0.05 * stretch
    body_p.rotation_euler = (0, -lean, 0)
    body.scale = (1.15 - 0.05 * breathe, 0.95 + 0.04 * breathe, 0.75 + 0.04 * breathe)
    throat.scale = (throat_s, throat_s, 0.8 * throat_s)
    for o in lids:
        o.hide_render = not blink
    for hip, knee, ankle, shoulder in legs:
        # folded: thigh forward, shin back under it, foot flat; stretched: all in a line behind
        hip.rotation_euler = (0, math.radians(-15 + 10 * crouch + 175 * stretch), 0)
        knee.rotation_euler = (0, math.radians(-20 * crouch - 150 * stretch), 0)
        ankle.rotation_euler = (0, math.radians(5 + 140 * stretch), 0)
        shoulder.rotation_euler = (0, math.radians(-10 * crouch + 60 * stretch), 0)


def bake(clips):
    d = os.path.join(OUT, "frog")
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
    json.dump({"view": "front", "model": "frog.py", "clips": meta,
               "unit_px": PX, "origin_px": [PX * -X_LO, RES[1]]},
              open(os.path.join(d, "clips.json"), "w"), indent=1)


def f_sit(i, n):
    pose(breathe=math.sin(2 * math.pi * i / n), blink=(i == n - 2))


def f_croak(i, n):
    p = i / (n - 1)
    pose(lean=0.1 * math.sin(math.pi * p), throat_s=1 + 1.4 * math.sin(math.pi * p) ** 2)


def f_hop(i, n):
    # 0..0.2 crouch, 0.2..0.45 kick out, 0.45..0.85 tuck back in (in the air), 0.85..1 land
    p = i / (n - 1)
    if p < 0.2:
        pose(crouch=p / 0.2, lean=-0.1 * p / 0.2)
    elif p < 0.45:
        q = (p - 0.2) / 0.25
        pose(crouch=1 - q, stretch=q, lean=-0.1 + 0.45 * q)
    elif p < 0.85:
        q = (p - 0.45) / 0.4
        pose(stretch=1 - q, lean=0.35 - 0.45 * q)
    else:
        q = (p - 0.85) / 0.15
        pose(crouch=0.6 * (1 - q), lean=-0.1 * (1 - q))


bake({"sit": (12, 8, True, f_sit), "croak": (10, 10, False, f_croak), "hop": (12, 16, False, f_hop)})
print("BAKED frog", OUT, RES)
