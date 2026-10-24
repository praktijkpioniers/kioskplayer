# Bake an upright cartoon sarcophagus (Egyptian, standing, front to the viewer) for the mummy
# scene in themes/engine.lua:
#
#   blender -b -P tools/bake/sarcophagus.py -- <out_dir> [size] [frame_h]
#
# Two sprites, so the engine can put the mummy between them:
#   <out_dir>/sarcophagus_box/  the case: rim, dark inside (drawn behind the mummy)
#   <out_dir>/sarcophagus_lid/  the lid swinging open on its left edge, towards the viewer
#                               (drawn in front: closed, it hides the mummy)
# Same look as kaykit.py and coffin.py (level orthographic camera, flat colours, dark outline) and
# the same frame height in world units as the mummy recipes, so one "unit" in theme.json fits all.
# The case's centre is world x = 0; clips.json gives "origin_px" for it.

import bpy, bmesh, json, math, os, sys

argv = sys.argv[sys.argv.index("--") + 1:]
OUT = os.path.abspath(argv[0])
SIZE = int(argv[1]) if len(argv) > 1 else 384
FRAME_H = float(argv[2]) if len(argv) > 2 else 2.8

HT, D = 2.6, 0.7                  # height (z), depth (y)
LID_T, LID_N = 0.1, 12            # lid thickness, opening frames
X_LO, X_HI = -1.6, 0.9            # room for the open lid on the left

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def mat(name, rgb):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*[(c / 255) ** 2.2 for c in rgb], 1)
    b.inputs["Roughness"].default_value = 0.8
    return m


STONE, STONE_LID, DARK, GOLD, INSIDE, FACE, EYE = (
    mat("stone", (34, 78, 96)), mat("stone_lid", (40, 92, 112)), mat("dark", (20, 44, 56)),
    mat("gold", (214, 172, 74)), mat("inside", (26, 18, 14)), mat("face", (236, 206, 160)), mat("eye", (20, 20, 26)))


def outline(grow=0.0):
    """Front view (x, z): a rounded head, wide shoulders, narrowing to the feet."""
    pts = [(-0.38, 0.0), (0.38, 0.0), (0.5, 1.55), (0.56, 1.95)]
    for k in range(9):                               # the head: half a rounded arch
        a = math.pi * k / 8
        pts.append((0.46 * math.cos(a), 2.05 + 0.5 * math.sin(a) * 1.1))
    pts += [(-0.56, 1.95), (-0.5, 1.55)]
    # grow outwards from the middle
    out = []
    for x, z in pts:
        cx, cz = 0.0, 1.3
        dx, dz = x - cx, z - cz
        n = math.hypot(dx, dz) or 1
        out.append((x + grow * dx / n, max(0.0, z + grow * dz / n) if z > 0 else 0.0))
    return out


def slab(name, pts, y0, y1, material, parent=None, offset=(0, 0, 0)):
    """The outline (x, z) extruded along y from y0 to y1."""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    ox, oy, oz = offset
    front = [bm.verts.new((x + ox, y0 + oy, z + oz)) for x, z in pts]
    back = [bm.verts.new((x + ox, y1 + oy, z + oz)) for x, z in pts]
    bm.faces.new(front)
    bm.faces.new(back[::-1])
    n = len(pts)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((front[j], front[i], back[i], back[j]))
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    o.data.materials.append(material)
    scene.collection.objects.link(o)
    if parent:
        o.parent = parent
    return o


def box(name, cx, cy, cz, sx, sy, sz, material, parent=None):
    pts = [(cx - sx, cz - sz), (cx + sx, cz - sz), (cx + sx, cz + sz), (cx - sx, cz + sz)]
    return slab(name, pts, cy - sy, cy + sy, material, parent)


def scaled(pts, f, cz=1.3):
    return [(x * f, cz + (z - cz) * f if z > 0 else 0.0) for x, z in pts]


# the case: a back, a dark inside, a rim all round (the inside shows when the lid is open)
OUTER = outline()
parts_box = [
    slab("back", OUTER, 0.15, D, STONE),
    slab("inside", scaled(OUTER, 0.86), 0.12, 0.16, INSIDE),
    slab("plinth", outline(0.05)[:2] + [(0.45, 0.1), (-0.45, 0.1)], -0.05, D + 0.05, DARK),
]
# the rim: thin slabs along the outline's edges, in front of the inside
for i in range(len(OUTER)):
    (x0, z0), (x1, z1) = OUTER[i], OUTER[(i + 1) % len(OUTER)]
    if z0 == 0 and z1 == 0:
        continue
    nx, nz = -(z1 - z0), (x1 - x0)
    n = math.hypot(nx, nz) or 1
    nx, nz = nx / n * 0.09, nz / n * 0.09
    quad = [(x0, z0), (x1, z1), (x1 + nx, z1 + nz), (x0 + nx, z0 + nz)]
    parts_box.append(slab(f"rim{i}", quad, 0.0, 0.16, DARK))

# the lid on a hinge along its left edge
hinge = bpy.data.objects.new("hinge", None)
scene.collection.objects.link(hinge)
xl = min(x for x, _ in OUTER) - 0.02
hinge.location = (xl, -LID_T, 0)
lid_pts = [(x - xl, z) for x, z in outline(0.02)]
parts_lid = [slab("lid", lid_pts, 0, LID_T, STONE_LID, hinge)]
parts_lid.append(slab("lid_inner", [(x * 0.94 + 0.03, 1.3 + (z - 1.3) * 0.92 if z > 0 else 0.05) for x, z in lid_pts],
                      LID_T, LID_T + 0.02, INSIDE, hinge))            # shows when open
cx = -xl                                                              # the lid's middle in hinge space
# a golden face, a headdress, gold bands over the body, crossed arms
parts_lid.append(slab("headdress", [(cx + x * 0.98, z) for x, z in OUTER if z > 1.55] + [(cx - 0.5, 1.5), (cx + 0.5, 1.5)],
                      -0.03, 0, GOLD, hinge))
face = [(cx + 0.24 * math.cos(2 * math.pi * k / 16), 2.05 + 0.3 * math.sin(2 * math.pi * k / 16)) for k in range(16)]
parts_lid.append(slab("face", face, -0.06, -0.02, FACE, hinge))
for ex in (-0.1, 0.1):
    parts_lid.append(box(f"eye{ex}", cx + ex, -0.07, 2.1, 0.05, 0.015, 0.025, EYE, hinge))
parts_lid.append(box("beard", cx, -0.05, 1.68, 0.05, 0.02, 0.12, GOLD, hinge))
for z in (0.35, 0.7, 1.05):
    w = 0.38 + (0.5 - 0.38) * z / 1.55
    parts_lid.append(box(f"band{z}", cx, -0.02, z, w * 0.96, 0.02, 0.045, GOLD, hinge))
for name, y, z, k in (("arm_l", -0.04, 1.3, 1), ("arm_r", -0.05, 1.22, -1)):     # crossed arms, slanted
    parts_lid.append(slab(name, [(cx - 0.3, z - 0.05 - 0.06 * k), (cx + 0.3, z - 0.05 + 0.06 * k),
                                 (cx + 0.3, z + 0.05 + 0.06 * k), (cx - 0.3, z + 0.05 - 0.06 * k)],
                          y - 0.02, y + 0.02, GOLD, hinge))

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
        hinge.rotation_euler = (0, 0, math.radians(-angle))     # swings towards the viewer
        scene.render.filepath = os.path.join(d, f"{clip}_{i:04d}.png")
        bpy.ops.render.render(write_still=True)
    json.dump({"view": "front", "model": "sarcophagus.py",
               "clips": {clip: {"files": f"{clip}_*.png", "count": len(frames), "fps": fps, "loop": False, "stride": 0}},
               "unit_px": RES[1] / FRAME_H, "origin_px": [RES[0] * -X_LO / frame_w, RES[1]]},
              open(os.path.join(d, "clips.json"), "w"), indent=1)


bake("sarcophagus_box", "box", [0], parts_box, 1)
angles = [110 * (0.5 - 0.5 * math.cos(math.pi * i / (LID_N - 1))) for i in range(LID_N)]
bake("sarcophagus_lid", "open", angles, parts_lid, 12)
print("BAKED sarcophagus", OUT, RES)
