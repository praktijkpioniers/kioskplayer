# Bake a piece of zombie brain for the zombie in themes/engine.lua (it drops off its head and lies
# there; a zombie that finds it eats it up):
#
#   blender -b -P tools/bake/brain.py -- <out_dir> [size]
#
# <out_dir>/brain/: "lie" (one frame), "eat" (bite by bite smaller: the engine stops drawing it after). Seen from the
# side, a little from above. Same look and world unit as cauldron.py / kaykit.py (size is the
# height of a 2.6 unit frame; this frame is cut smaller at the same scale). Its middle at the
# bottom is world x = 0 (origin_px).

import bpy, bmesh, json, math, os, random, sys

argv = sys.argv[sys.argv.index("--") + 1:]
OUT = os.path.abspath(argv[0])
SIZE = int(argv[1]) if len(argv) > 1 else 384
FRAME_H = 0.42
X_LO, X_HI = -0.3, 0.3
PX = SIZE / 2.6

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
rng = random.Random(3)


def mat(name, rgb, rough=0.45):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*[(v / 255) ** 2.2 for v in rgb], 1)
    b.inputs["Roughness"].default_value = rough
    return m


PINK, DEEP = mat("pink", (232, 146, 164)), mat("deep", (178, 82, 104))

rig = bpy.data.objects.new("rig", None)
scene.collection.objects.link(rig)
parts = []

# two lobes (a fissure between), their folds: wiggly tubes laid over them
for k, y in enumerate((-0.075, 0.075)):
    me = bpy.data.meshes.new(f"lobe{k}")
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=32, v_segments=16, radius=0.1)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(f"lobe{k}", me)
    o.data.materials.append(PINK)
    for f in me.polygons:
        f.use_smooth = True
    scene.collection.objects.link(o)
    o.parent = rig
    o.location = (0, y, 0.085)
    o.scale = (1.35, 0.72, 0.85)
    parts.append(o)
    side = -1 if y < 0 else 1
    for g in range(70):                          # a fold: a random walk over the lobe's surface
        th = rng.uniform(0, 2 * math.pi)
        ph = rng.uniform(0.1, 2.3)                # (from the top down to below the middle)
        dth, dph = rng.uniform(-1, 1), rng.uniform(-1, 1)
        pts = []
        for i in range(12):
            dth += rng.uniform(-0.9, 0.9)
            dph += rng.uniform(-0.9, 0.9)
            n = math.hypot(dth, dph) or 1
            th += 0.12 * dth / n
            ph = min(2.4, max(0.05, ph + 0.12 * dph / n))
            r = 1.02
            pts.append((0.1 * 1.35 * r * math.sin(ph) * math.cos(th),
                        y + 0.1 * 0.72 * r * math.sin(ph) * math.sin(th),
                        0.085 + 0.1 * 0.85 * r * math.cos(ph)))
        cu = bpy.data.curves.new(f"fold{k}_{g}", "CURVE")
        cu.dimensions = "3D"
        cu.bevel_depth = 0.016
        cu.bevel_resolution = 4
        cu.use_fill_caps = True
        cu.resolution_u = 6
        sp = cu.splines.new("NURBS")
        sp.order_u = 3
        sp.use_endpoint_u = True
        sp.points.add(len(pts) - 1)
        for i, q in enumerate(pts):
            sp.points[i].co = (*q, 1)
        co = bpy.data.objects.new(f"fold{k}_{g}", cu)
        co.data.materials.append(PINK)
        scene.collection.objects.link(co)
        co.parent = rig
        dg = bpy.context.evaluated_depsgraph_get()
        mesh = bpy.data.meshes.new_from_object(co.evaluated_get(dg))
        for f in mesh.polygons:
            f.use_smooth = True
        mo = bpy.data.objects.new(f"foldm{k}_{g}", mesh)
        scene.collection.objects.link(mo)
        mo.parent = rig
        bpy.data.objects.remove(co)
        parts.append(mo)
# the fissure: a dark sliver along the top
me = bpy.data.meshes.new("fissure")
bm = bmesh.new()
bmesh.ops.create_uvsphere(bm, u_segments=24, v_segments=12, radius=0.1)
bm.to_mesh(me)
bm.free()
fis = bpy.data.objects.new("fissure", me)
fis.data.materials.append(DEEP)
scene.collection.objects.link(fis)
fis.parent = rig
fis.location = (0, 0, 0.09)
fis.scale = (1.3, 0.08, 0.8)

rig.rotation_euler = (math.radians(-20), 0, math.radians(-20))   # a little from above, turned
rig.location = (0, 0, 0.025)

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
    sol.thickness = -0.004
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


def bitten(n):                       # (eaten: bite by bite smaller, sinking into the hands)
    s = 1 - n / 6
    rig.scale = (s, s, s)


d = os.path.join(OUT, "brain")
os.makedirs(d, exist_ok=True)
for f in os.listdir(d):
    if f.endswith(".png"):
        os.remove(os.path.join(d, f))
meta = {}
for name, frames in (("lie", [0]), ("eat", [0, 1, 2, 3, 4, 5])):
    for i, n in enumerate(frames):
        bitten(n)
        scene.render.filepath = os.path.join(d, f"{name}_{i:04d}.png")
        bpy.ops.render.render(write_still=True)
    meta[name] = {"files": f"{name}_*.png", "count": len(frames), "fps": 3, "loop": False, "stride": 0}
json.dump({"view": "front", "model": "brain.py", "clips": meta, "unit_px": PX, "origin_px": [PX * -X_LO, RES[1]]},
          open(os.path.join(d, "clips.json"), "w"), indent=1)
print("BAKED brain", OUT, RES)
