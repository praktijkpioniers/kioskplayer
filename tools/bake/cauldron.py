# Bake a cartoon witch's cauldron (on legs, a fire under it) for the witch scene in themes/engine.lua:
#
#   blender -b -P tools/bake/cauldron.py -- <out_dir> [size] [frame_h]
#
# Two sprites, so the engine can put what jumps in or out between them:
#   <out_dir>/cauldron_back/   the whole pot, fire and brew: "bubble" (loop), "splash" (something
#                              dropped in), "poof" (a spell: a cloud billowing up and away),
#                              "appear"/"vanish" (the pot comes/goes in such a cloud: at SWAP)
#   <out_dir>/cauldron_front/  the pot's body and rim only (drawn in front: what's in it is hidden
#                              below the rim)
# Same look as kaykit.py (level orthographic camera, flat colours, dark outline) and the same
# frame height in world units, so with the same "unit" in theme.json it matches the witch's scale.
# The pot's centre is world x = 0; clips.json gives "origin_px" for it.

import bpy, bmesh, json, math, os, random, sys

argv = sys.argv[sys.argv.index("--") + 1:]
OUT = os.path.abspath(argv[0])
SIZE = int(argv[1]) if len(argv) > 1 else 384
FRAME_H = float(argv[2]) if len(argv) > 2 else 2.6

R = 0.62                  # pot radius
CZ = 0.62                 # pot centre height (on its legs)
SQ = 0.8                  # pot squashed in height
RIM = CZ + 0.5 * R * SQ   # rim plane
X_LO, X_HI = -1.1, 1.1

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
rng = random.Random(7)


def mat(name, rgb, glow=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    c = (*[(v / 255) ** 2.2 for v in rgb], 1)
    b.inputs["Base Color"].default_value = c
    b.inputs["Roughness"].default_value = 0.7
    if glow:
        b.inputs["Emission Color"].default_value = c
        b.inputs["Emission Strength"].default_value = glow
    return m


IRON, IRON_HI = mat("iron", (46, 44, 54)), mat("iron_hi", (70, 68, 80))
BREW, FOAM = mat("brew", (98, 200, 60), 0.6), mat("foam", (170, 240, 110), 0.5)
WOOD = mat("wood", (96, 60, 34))
FLAME_O, FLAME_Y = mat("flame_o", (255, 120, 20), 2.0), mat("flame_y", (255, 220, 80), 2.5)
PUFF = mat("puff", (200, 170, 235), 0.4)
DROP = mat("drop", (120, 220, 70), 0.6)


def link(o, material):
    o.data.materials.append(material)
    scene.collection.objects.link(o)
    return o


def sphere(name, x, z, r, material, sz=1.0, y=0.0, seg=20):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=seg // 2, radius=r)
    bm.to_mesh(me)
    bm.free()
    o = link(bpy.data.objects.new(name, me), material)
    o.location = (x, y, z)
    o.scale = (1, 1, sz)
    return o


def cylinder(name, x, z, r, h, material, rot=(0, 0, 0), y=0.0):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=14, radius1=r, radius2=r, depth=h)
    bm.to_mesh(me)
    bm.free()
    o = link(bpy.data.objects.new(name, me), material)
    o.location = (x, y, z)
    o.rotation_euler = rot
    return o


def cone(name, material):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=12, radius1=1, radius2=0, depth=1)
    bm.to_mesh(me)
    bm.free()
    return link(bpy.data.objects.new(name, me), material)


# the pot: a squashed sphere, open at the top, a thick rim, three stubby legs
me = bpy.data.meshes.new("pot")
bm = bmesh.new()
bmesh.ops.create_uvsphere(bm, u_segments=32, v_segments=16, radius=R)
for v in bm.verts:
    v.co.z *= SQ
cut = 0.5 * R * SQ
bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=(0, 0, cut),
                       plane_no=(0, 0, 1), clear_outer=True)
bm.to_mesh(me)
bm.free()
pot = link(bpy.data.objects.new("pot", me), IRON)
pot.location = (0, 0, CZ)
rim_r = R * math.sqrt(1 - 0.25)
bpy.ops.mesh.primitive_torus_add(major_radius=rim_r, minor_radius=0.07, location=(0, 0, RIM))
rim = bpy.context.active_object
rim.data.materials.append(IRON_HI)
legs = [cylinder(f"leg{i}", 0.62 * R * math.cos(a), 0.12, 0.07, 0.3, IRON, y=0.62 * R * math.sin(a))
        for i, a in enumerate((math.radians(-60), math.radians(-120), math.radians(90)))]
body = [pot, rim] + legs

# the brew: a foamy dome just over the rim (the camera is level: a flat surface wouldn't show)
brew = sphere("brew", 0, RIM, rim_r * 0.95, BREW, sz=0.22, seg=28)
foam = [sphere(f"foam{i}", rng.uniform(-0.6, 0.6) * rim_r, RIM + 0.06, rng.uniform(0.07, 0.12), FOAM,
               y=rng.uniform(-0.3, 0.3)) for i in range(6)]
bubbles = [sphere(f"bubble{i}", 0, 0, 1, FOAM) for i in range(5)]
bub_plan = [(rng.uniform(-0.65, 0.65) * rim_r, rng.uniform(-0.4, 0.2), rng.uniform(0.07, 0.13), rng.random())
            for _ in bubbles]

# the fire: two logs crossed under the pot, flames licking up round it
logs = [cylinder("log1", 0, 0.07, 0.06, 0.9, WOOD, rot=(0, math.radians(90), math.radians(20))),
        cylinder("log2", 0, 0.07, 0.06, 0.9, WOOD, rot=(0, math.radians(90), math.radians(-20)))]
flames = [(cone(f"flame{i}", FLAME_O if i % 2 == 0 else FLAME_Y), (i - 3) * 0.13, 0.42 if i % 2 == 0 else 0.3)
          for i in range(7)]

drops = [sphere(f"drop{i}", 0, 0, 1, DROP) for i in range(7)]
drop_plan = [(rng.uniform(-1, 1), rng.uniform(2.2, 3.2), rng.uniform(0.07, 0.11)) for _ in drops]
puffs = [sphere(f"puff{i}", 0, 0, 1, PUFF) for i in range(9)]
puff_plan = [(rng.uniform(-0.5, 0.5), rng.uniform(0.0, 0.5), rng.uniform(0.25, 0.45), rng.uniform(-0.3, 0.3))
             for _ in puffs]

# the front sprite: the pot's upper part only (the flames lick up in front of the lower part)
TOP = 0.56
me = bpy.data.meshes.new("pot_top")
bm = bmesh.new()
bm.from_mesh(pot.data)
bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=(0, 0, TOP - CZ),
                       plane_no=(0, 0, -1), clear_outer=True)
bm.to_mesh(me)
bm.free()
pot_top = link(bpy.data.objects.new("pot_top", me), IRON)
pot_top.location = pot.location
body_top = [pot_top, rim]

back = body + body_top[:1] + [brew] + foam + bubbles + logs + [f for f, _, _ in flames] + drops + puffs

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
for o in back:
    o.data.materials.append(ink)
    sol = o.modifiers.new("outline", "SOLIDIFY")
    sol.thickness = -0.008 * FRAME_H
    sol.use_flip_normals = True
    sol.use_rim = False
    sol.material_offset = len(o.data.materials) - 1
for o in (pot, pot_top):                         # the open pot has a wall, not a skin
    o.modifiers.new("wall", "SOLIDIFY").thickness = 0.04
    o.modifiers.move(len(o.modifiers) - 1, 0)

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


def flicker(p):
    """The flames at phase p (0..1, a loop)."""
    for k, (f, x, h) in enumerate(flames):
        w = 0.5 + 0.5 * math.sin(2 * math.pi * (p * 2 + k * 0.37))
        hh = h * (0.75 + 0.5 * w)
        f.scale = (0.11 + 0.04 * w, 0.11, hh)
        f.location = (x + 0.025 * math.sin(2 * math.pi * (p + k * 0.2)), -0.5, 0.06 + hh / 2)


def brew_at(p, lift=0.0):
    """The bubbling brew at phase p (a loop); lift: how far it heaves up (a splash, a spell)."""
    brew.scale = (1, 1, 0.22 + 0.06 * math.sin(2 * math.pi * p) + lift)
    for k, f in enumerate(foam):
        f.location.z = RIM + 0.06 + 0.03 * math.sin(2 * math.pi * (p + k / 6)) + lift * 0.5
    for b, (x, y, r, ph) in zip(bubbles, bub_plan):
        q = (p + ph) % 1.0                           # each its own moment: rise, grow, pop
        s = r * (0.3 + q) if q < 0.85 else 0.0
        b.scale = (max(s, 1e-4),) * 3
        b.location = (x, y, RIM + 0.1 + lift * 0.4 + 0.25 * q)
        b.hide_render = s <= 0


def hide_fx():
    for o in drops + puffs:
        o.hide_render = True


def render(d, name, i):
    scene.render.filepath = os.path.join(d, f"{name}_{i:04d}.png")
    bpy.ops.render.render(write_still=True)


def bake(sub, clips, show):
    d = os.path.join(OUT, sub)
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        if f.endswith(".png"):
            os.remove(os.path.join(d, f))
    meta = {}
    for name, (n, fps, loop, frame) in clips.items():
        for i in range(n):
            for o in back:
                o.hide_render = o not in show
            hide_fx()
            frame(i, n)
            render(d, name, i)
        meta[name] = {"files": f"{name}_*.png", "count": n, "fps": fps, "loop": loop, "stride": 0}
    json.dump({"view": "front", "model": "cauldron.py", "clips": meta,
               "unit_px": RES[1] / FRAME_H, "origin_px": [RES[0] * -X_LO / frame_w, RES[1]]},
              open(os.path.join(d, "clips.json"), "w"), indent=1)


def f_bubble(i, n):
    flicker(i / n)
    brew_at(i / n)


def f_splash(i, n):
    p = i / (n - 1)
    flicker(i / n)
    brew_at(i / n, lift=0.25 * math.sin(math.pi * min(1, p * 1.6)))
    for o, (vx, vz, r) in zip(drops, drop_plan):   # drops thrown up and out, falling back
        t = p * 1.4
        z = RIM + vz * t - 4.0 * t * t
        o.hide_render = z < RIM - 0.05 or p == 0
        o.location = (vx * 0.9 * t, -0.3, z)
        o.scale = (r,) * 3


def f_poof(i, n):
    p = i / (n - 1)
    flicker(i / n)
    brew_at(i / n, lift=0.3 * math.sin(math.pi * p))
    grow = math.sin(math.pi * min(1, p * 1.25))     # billows up, then shrinks away
    for o, (x, y0, r, y) in zip(puffs, puff_plan):
        s = r * grow * (0.7 + 0.6 * p)
        o.hide_render = s < 0.02
        o.scale = (max(s, 1e-4),) * 3
        o.location = (x * (0.4 + p), y - 0.4, RIM + 0.2 + y0 + 1.1 * p)


POT = body + [brew] + foam + bubbles + logs + [f for f, _, _ in flames]
SWAP = 0.4                                          # (the cloud at its biggest: the pot comes or goes)


def f_appear(i, n):
    f_poof(i, n)
    if i / (n - 1) < SWAP:
        for o in POT:
            o.hide_render = True


def f_vanish(i, n):
    f_poof(i, n)
    if i / (n - 1) >= SWAP:
        for o in POT:
            o.hide_render = True


bake("cauldron_back", {"bubble": (12, 10, True, f_bubble), "splash": (10, 12, False, f_splash),
                       "poof": (14, 12, False, f_poof), "appear": (14, 12, False, f_appear),
                       "vanish": (14, 12, False, f_vanish)}, [o for o in back if o is not pot_top])
bake("cauldron_front", {"front": (1, 1, False, lambda i, n: None)}, body_top)
print("BAKED cauldron", OUT, RES)
