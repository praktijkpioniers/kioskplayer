# Bake an eyeball for the skeleton in themes/engine.lua (it took the zombie's brain and eye in a
# fight: the eye sits in its socket, and falls out after a while - it lies there):
#
#   blender -b -P tools/bake/eye.py -- <out_dir> [size]
#
# <out_dir>/eye/: "lie" (one frame, looking at the viewer a little sideways). Same look and world unit
# as brain.py (size is the height of a 2.6 unit frame). Its middle at the bottom is world x = 0.

import bpy, bmesh, json, math, os, sys

argv = sys.argv[sys.argv.index("--") + 1:]
OUT = os.path.abspath(argv[0])
SIZE = int(argv[1]) if len(argv) > 1 else 384
FRAME_H = 0.16
X_LO, X_HI = -0.08, 0.08
PX = SIZE / 2.6

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def mat(name, rgb, rough=0.3):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*[(v / 255) ** 2.2 for v in rgb], 1)
    b.inputs["Roughness"].default_value = rough
    return m


WHITE, IRIS, PUPIL, VEIN = mat("white", (246, 242, 232)), mat("iris", (70, 150, 60)), mat("pupil", (12, 12, 14)), mat("vein", (200, 60, 60))
rig = bpy.data.objects.new("rig", None)
scene.collection.objects.link(rig)
parts = []


def ball(name, r, at, scale, m):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=32, v_segments=16, radius=r)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    o.data.materials.append(m)
    for f in me.polygons:
        f.use_smooth = True
    scene.collection.objects.link(o)
    o.parent = rig
    o.location, o.scale = at, scale
    parts.append(o)
    return o


ball("eye", 0.06, (0, 0, 0.06), (1, 1, 1), WHITE)
ball("iris", 0.032, (0, -0.05, 0.06), (1, 0.35, 1), IRIS)
ball("pupil", 0.016, (0, -0.064, 0.06), (1, 0.3, 1), PUPIL)
rig.rotation_euler = (0, 0, math.radians(-25))   # (looking a little sideways)
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
    sol.thickness = -0.003
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


d = os.path.join(OUT, "eye")
os.makedirs(d, exist_ok=True)
for f in os.listdir(d):
    if f.endswith(".png"):
        os.remove(os.path.join(d, f))
scene.render.filepath = os.path.join(d, "lie_0000.png")
bpy.ops.render.render(write_still=True)
meta = {"lie": {"files": "lie_*.png", "count": 1, "fps": 1, "loop": False, "stride": 0}}
json.dump({"view": "front", "model": "eye.py", "clips": meta, "unit_px": PX, "origin_px": [PX * -X_LO, RES[1]]},
          open(os.path.join(d, "clips.json"), "w"), indent=1)
print("BAKED eye", OUT, RES)
