# Bake a bone for the werewolf in themes/engine.lua (he comes out of a fight with a skeleton or the
# mummy carrying it; puts it down somewhere - one lying about may be taken up again, or a skeleton
# climbs up out of the ground where it lies):
#
#   blender -b -P tools/bake/bone.py -- <out_dir> [size]
#
# <out_dir>/bone/: "lie" (one frame): a cartoon bone, seen from the side, a little from above. Same
# look and world unit as cauldron.py / kaykit.py (size is the height of a 2.6 unit frame; this frame
# is cut smaller at the same scale). Its middle at the bottom is world x = 0 (origin_px).

import bpy, bmesh, json, math, os, sys

argv = sys.argv[sys.argv.index("--") + 1:]
OUT = os.path.abspath(argv[0])
SIZE = int(argv[1]) if len(argv) > 1 else 384
FRAME_H = 0.2
X_LO, X_HI = -0.3, 0.3
PX = SIZE / 2.6

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def mat(name, rgb, rough=0.45):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*[(v / 255) ** 2.2 for v in rgb], 1)
    b.inputs["Roughness"].default_value = rough
    return m


IVORY = mat("ivory", (236, 226, 200))

rig = bpy.data.objects.new("rig", None)
scene.collection.objects.link(rig)
parts = []


def piece(name, make, loc, scale=(1, 1, 1), rot=(0, 0, 0)):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    make(bm)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    o.data.materials.append(IVORY)
    for f in me.polygons:
        f.use_smooth = True
    scene.collection.objects.link(o)
    o.parent = rig
    o.location, o.scale, o.rotation_euler = loc, scale, rot
    parts.append(o)


# the shaft along x, two knobs at each end
piece("shaft", lambda bm: bmesh.ops.create_cone(bm, cap_ends=True, segments=20, radius1=0.032, radius2=0.032, depth=0.34),
      (0, 0, 0.05), rot=(0, math.pi / 2, 0))
for sx in (-0.17, 0.17):
    for sy in (-0.032, 0.032):
        piece("knob", lambda bm: bmesh.ops.create_uvsphere(bm, u_segments=20, v_segments=10, radius=0.046),
              (sx, sy, 0.05 + (0.012 if sy > 0 else -0.004)))

rig.rotation_euler = (math.radians(-25), 0, math.radians(-12))   # a little from above, turned
rig.location = (0, 0, 0.012)

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


d = os.path.join(OUT, "bone")
os.makedirs(d, exist_ok=True)
for f in os.listdir(d):
    if f.endswith(".png"):
        os.remove(os.path.join(d, f))
scene.render.filepath = os.path.join(d, "lie_0000.png")
bpy.ops.render.render(write_still=True)
meta = {"lie": {"files": "lie_*.png", "count": 1, "fps": 1, "loop": False, "stride": 0}}
json.dump({"view": "front", "model": "bone.py", "clips": meta, "unit_px": PX, "origin_px": [PX * -X_LO, RES[1]]},
          open(os.path.join(d, "clips.json"), "w"), indent=1)
print("BAKED bone", OUT, RES)
