# Bake a cartoon coffin (lying, long side to the viewer) for the vampire scene in themes/engine.lua:
#
#   blender -b -P tools/bake/coffin.py -- <out_dir> [size] [frame_h]
#
# Two sprites, so the engine can put the vampire between them:
#   <out_dir>/coffin_box/  the box (drawn in front of the vampire: he lies in it, hidden)
#   <out_dir>/coffin_lid/  the lid swinging open on its back edge, closed → upright (drawn behind)
# Same look as kaykit.py (level orthographic camera, flat colours, dark outline) and the same
# frame height in world units, so with the same "unit" in theme.json it matches the vampire's scale.
# The coffin's centre is world x = 0; clips.json gives "origin_px" for it.

import bpy, bmesh, json, math, os, sys

argv = sys.argv[sys.argv.index("--") + 1:]
OUT = os.path.abspath(argv[0])
SIZE = int(argv[1]) if len(argv) > 1 else 384
FRAME_H = float(argv[2]) if len(argv) > 2 else 2.45

L, Wd, H = 2.6, 1.1, 1.12        # length (x), depth (y), box height (z); head end at -x
LID_T, LID_N = 0.12, 12           # lid thickness, opening frames
X_LO, X_HI = -1.5, 1.5

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def mat(name, rgb):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*[(c / 255) ** 2.2 for c in rgb], 1)
    b.inputs["Roughness"].default_value = 0.8
    return m


WOOD, WOOD_LID, DARK, GOLD, IRON = (mat("wood", (74, 44, 30)), mat("lid", (92, 56, 38)),
                                    mat("dark", (40, 24, 16)), mat("gold", (214, 172, 74)), mat("iron", (150, 150, 158)))
SATIN = mat("satin", (118, 14, 28))


def outline(grow=0.0):
    """Top view of the coffin: narrow at the head, widest at the shoulders, narrower at the feet."""
    hw = Wd / 2 + grow
    x0, x1, xs = -L / 2 - grow, L / 2 + grow, -L / 2 + 0.27 * L
    return [(x0, -0.62 * hw), (xs, -hw), (x1, -0.56 * hw), (x1, 0.56 * hw), (xs, hw), (x0, 0.62 * hw)]


def prism(name, pts, z0, z1, material, parent=None):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bot = [bm.verts.new((x, y, z0)) for x, y in pts]
    top = [bm.verts.new((x, y, z1)) for x, y in pts]
    bm.faces.new(bot[::-1])
    bm.faces.new(top)
    n = len(pts)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((bot[i], bot[j], top[j], top[i]))
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    o.data.materials.append(material)
    scene.collection.objects.link(o)
    if parent:
        o.parent = parent
    return o


def box(name, cx, cy, cz, sx, sy, sz, material, parent=None):
    pts = [(cx - sx, cy - sy), (cx + sx, cy - sy), (cx + sx, cy + sy), (cx - sx, cy + sy)]
    return prism(name, pts, cz - sz, cz + sz, material, parent)


# the box: body, a darker plinth and rim, iron handles along the side
parts_box = [
    prism("body", outline(), 0.06, H - 0.05, WOOD),
    prism("plinth", outline(0.04), 0.0, 0.08, DARK),
    prism("rim", outline(0.025), H - 0.07, H, DARK),
]
for x in (-0.75, 0, 0.75):
    parts_box.append(box(f"handle{x}", x, -Wd / 2 - 0.06, H * 0.55, 0.13, 0.03, 0.035, IRON))

# the lid on a hinge along its back edge
hinge = bpy.data.objects.new("hinge", None)
scene.collection.objects.link(hinge)
hinge.location = (0, Wd / 2 + 0.03, H)
lid_pts = [(x, y - (Wd / 2 + 0.03)) for x, y in outline(0.03)]
parts_lid = [prism("lid", lid_pts, 0, LID_T, WOOD_LID, hinge),
             prism("lid_top", [(x * 0.92, y * 0.86 - 0.004) for x, y in lid_pts], LID_T, LID_T + 0.03, DARK, hinge)]
parts_lid.append(prism("lining", [(x * 0.94, y * 0.88 - 0.004) for x, y in lid_pts], -0.02, 0, SATIN, hinge))  # shows when open
cx = -L / 2 + 0.36 * L        # the cross, over the chest
cy = -(Wd / 2 + 0.03)
parts_lid.append(box("cross_v", cx, cy, LID_T + 0.05, 0.45, 0.06, 0.02, GOLD, hinge))
parts_lid.append(box("cross_h", cx - 0.18, cy, LID_T + 0.05, 0.06, 0.26, 0.02, GOLD, hinge))

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
ib = ink.node_tree.nodes["Principled BSDF"]
ib.inputs["Base Color"].default_value = (0.02, 0.02, 0.03, 1)
ib.inputs["Roughness"].default_value = 1
for o in parts_box + parts_lid:
    o.data.materials.append(ink)
    sol = o.modifiers.new("outline", "SOLIDIFY")
    sol.thickness = -0.008 * FRAME_H
    sol.use_flip_normals = True
    sol.use_rim = False
    sol.material_offset = len(o.data.materials) - 1

frame_w = X_HI - X_LO
RES = (round(SIZE * frame_w / FRAME_H), SIZE)
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


def bake(sub, clip, frames, show, fps):
    d = os.path.join(OUT, sub)
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        if f.endswith(".png"):
            os.remove(os.path.join(d, f))
    for o in parts_box + parts_lid:
        o.hide_render = o not in show
    for i, angle in enumerate(frames):
        hinge.rotation_euler = (math.radians(-angle), 0, 0)
        scene.render.filepath = os.path.join(d, f"{clip}_{i:04d}.png")
        bpy.ops.render.render(write_still=True)
    json.dump({"view": "front", "model": "coffin.py",
               "clips": {clip: {"files": f"{clip}_*.png", "count": len(frames), "fps": fps, "loop": False, "stride": 0}},
               "unit_px": RES[1] / FRAME_H, "origin_px": [RES[0] * -X_LO / frame_w, RES[1]]},
              open(os.path.join(d, "clips.json"), "w"), indent=1)


bake("coffin_box", "box", [0], parts_box, 1)
# opening: the front edge rises, the lid swings past upright and leans back a little
angles = [105 * (0.5 - 0.5 * math.cos(math.pi * i / (LID_N - 1))) for i in range(LID_N)]
bake("coffin_lid", "open", angles, parts_lid, 12)
print("BAKED coffin", OUT, RES)
