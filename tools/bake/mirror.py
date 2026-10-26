# Bake a spooky standing mirror (a cheval mirror: an oval tarnished-gilt frame swinging between
# two dark wooden posts on feet, a winged skull on top) for the vampire-princess gag in
# themes/engine.lua:
#
#   blender -b -P tools/bake/mirror.py -- <out_dir> [size] [frame_h]
#
# Three sprites, so the engine can draw a reflection between them:
#   <out_dir>/mirror_back/   frame, stand and the glass (dark, bluish, opaque): "stand" (a faint
#                            glint sweeping over the glass, loop), "fog" (the glass mists over and
#                            clears again, one-shot)
#   <out_dir>/mirror_front/  frame and stand only, the glass area fully transparent (drawn on top
#                            of the reflection: the frame masks its edges)
#   <out_dir>/mirror_glass/  the visible glass area in white, transparent elsewhere (a mask)
# The mirror is turned TURN degrees about its upright axis: the glass faces partly to the viewer
# and partly to the viewer's right, so a character standing right of it, facing left, looks in.
# Same look as kaykit.py and coffin.py (level orthographic camera, flat colours, dark outline) and
# the same frame height in world units, so with the same "unit" in theme.json it matches the cast.
# The mirror's centre (on the ground) is world x = 0; clips.json gives "origin_px" for it and
# "glass_px" (the glass ellipse's centre and radii in frame pixels).

import bpy, bmesh, json, math, os, sys

argv = sys.argv[sys.argv.index("--") + 1:]
OUT = os.path.abspath(argv[0])
SIZE = int(argv[1]) if len(argv) > 1 else 384
FRAME_H = float(argv[2]) if len(argv) > 2 else 2.6

TURN = 25                          # degrees: the glass turned towards the viewer's right
GRX, GRZ, GCZ = 0.38, 0.6, 1.24   # glass: half width, half height, centre height
RING = 0.12                        # frame width round the glass
PX = 0.57                          # posts at x = +-PX
X_LO, X_HI = -0.85, 0.85
GLINT_N, GLINT_ON, FOG_N = 12, 6, 16

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def mat(name, rgb, emit=None):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*[(c / 255) ** 2.2 for c in rgb], 1)
    b.inputs["Roughness"].default_value = 0.8
    if emit is not None:                     # flat, unlit (glints, fog, the mask)
        b.inputs["Base Color"].default_value = (0, 0, 0, 1)
        b.inputs["Specular IOR Level"].default_value = 0
        b.inputs["Emission Color"].default_value = (*[(c / 255) ** 2.2 for c in rgb], 1)
        b.inputs["Emission Strength"].default_value = emit
    return m


GILT, GILT_DK, WOOD, WOOD_DK, BONE, SOCKET, GLASS, SHEEN = (
    mat("gilt", (150, 120, 58)), mat("gilt_dk", (96, 72, 34)), mat("wood", (62, 38, 28)),
    mat("wood_dk", (38, 22, 16)), mat("bone", (226, 214, 184)), mat("socket", (22, 16, 14)),
    mat("glass", (48, 58, 72)), mat("sheen", (70, 84, 102)))
GLINT = mat("glint", (205, 220, 236), emit=1.0)
FOG = mat("fog", (150, 160, 172), emit=1.0)
WHITE = mat("white", (255, 255, 255), emit=1.0)

root = bpy.data.objects.new("root", None)          # the whole mirror, turned
scene.collection.objects.link(root)
root.rotation_euler = (0, 0, math.radians(TURN))


def link(o, material, parent):
    o.data.materials.append(material)
    scene.collection.objects.link(o)
    o.parent = parent or root
    return o


def slab(name, pts, y0, y1, material, parent=None):
    """A polygon in the mirror's plane (x, z) extruded along y from y0 to y1 (y0 < y1: front first)."""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    front = [bm.verts.new((x, y0, z)) for x, z in pts]
    back = [bm.verts.new((x, y1, z)) for x, z in pts]
    bm.faces.new(front)
    bm.faces.new(back[::-1])
    n = len(pts)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((front[j], front[i], back[i], back[j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    return link(bpy.data.objects.new(name, me), material, parent)


def ring(name, rx0, rz0, rx1, rz1, cz, y0, y1, material, n=48):
    """An elliptic ring (inner radii rx0, rz0; outer rx1, rz1) in the mirror's plane."""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    vs = []
    for k in range(n):
        a = 2 * math.pi * k / n
        c, s = math.cos(a), math.sin(a)
        vs.append([bm.verts.new((rx * c, y, cz + rz * s)) for rx, rz in ((rx0, rz0), (rx1, rz1)) for y in (y0, y1)])
    for k in range(n):        # [inner front, inner back, outer front, outer back]
        a, b = vs[k], vs[(k + 1) % n]
        bm.faces.new((a[0], b[0], b[2], a[2]))      # front
        bm.faces.new((a[3], b[3], b[1], a[1]))      # back
        bm.faces.new((a[2], b[2], b[3], a[3]))      # outer edge
        bm.faces.new((a[1], b[1], b[0], a[0]))      # inner edge
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    return link(bpy.data.objects.new(name, me), material, None)


def box(name, cx, cy, cz, sx, sy, sz, material, parent=None):
    return slab(name, [(cx - sx, cz - sz), (cx + sx, cz - sz), (cx + sx, cz + sz), (cx - sx, cz + sz)],
                cy - sy, cy + sy, material, parent)


def ball(name, x, y, z, r, material, sz=1.0):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=8, radius=r, location=(x, y, z))
    o = bpy.context.object
    o.scale = (1, 1, sz)
    o.data.materials.append(material)
    o.parent = root
    return o


def ellipse(rx, rz, cz, n=48):
    return [(rx * math.cos(2 * math.pi * k / n), cz + rz * math.sin(2 * math.pi * k / n)) for k in range(n)]


def clip(poly, convex):
    """Sutherland-Hodgman: poly clipped to the convex polygon (counter-clockwise)."""
    out = poly
    for i in range(len(convex)):
        (ax, az), (bx, bz) = convex[i], convex[(i + 1) % len(convex)]
        side = lambda p: (bx - ax) * (p[1] - az) - (bz - az) * (p[0] - ax)
        src, out = out, []
        for k in range(len(src)):
            p, q = src[k], src[(k + 1) % len(src)]
            sp, sq = side(p), side(q)
            if sp >= 0:
                out.append(p)
            if (sp >= 0) != (sq >= 0):
                t = sp / (sp - sq)
                out.append((p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1])))
        if not out:
            return []
    return out


GLASS_PTS = ellipse(GRX, GRZ, GCZ)
GLASS_IN = ellipse(GRX * 0.985, GRZ * 0.99, GCZ)    # overlays stay inside the glass

# ---- the frame: a gilt oval with a dark inner lip, knobs, a winged skull on top ----
glass = slab("glass", GLASS_PTS, 0.0, 0.015, GLASS)
backing = slab("backing", ellipse(GRX + RING * 0.8, GRZ + RING * 0.8, GCZ), 0.015, 0.05, WOOD_DK)
sheen = []                                           # two faint fixed streaks: it reads as glass
for x0, w in ((-0.2, 0.09), (-0.04, 0.035)):
    band = [(x0, GCZ - 1), (x0 + w, GCZ - 1), (x0 + w + 0.9, GCZ + 1), (x0 + 0.9, GCZ + 1)]
    band = [(x - 0.45, z) for x, z in band]
    sheen.append(slab(f"sheen{x0}", clip(band, GLASS_IN), -0.004, -0.001, SHEEN))
frame = [
    ring("lip", GRX - 0.01, GRZ - 0.01, GRX + 0.03, GRZ + 0.03, GCZ, -0.035, 0.02, GILT_DK),
    ring("frame", GRX + 0.025, GRZ + 0.025, GRX + RING, GRZ + RING, GCZ, -0.05, 0.04, GILT),
    ring("bead", GRX + RING - 0.005, GRZ + RING - 0.005, GRX + RING + 0.025, GRZ + RING + 0.025, GCZ, -0.03, 0.03,
         GILT_DK),
]
for a in (0, 180, 270):                              # knobs left, right, bottom (the skull sits on top)
    c, s = math.cos(math.radians(a)), math.sin(math.radians(a))
    frame.append(ball(f"knob{a}", (GRX + RING + 0.02) * c, -0.04, GCZ + (GRZ + RING + 0.02) * s, 0.045, GILT))
for a in (35, 145, 215, 325):                        # small studs on the diagonals
    c, s = math.cos(math.radians(a)), math.sin(math.radians(a))
    frame.append(ball(f"stud{a}", (GRX + RING * 0.55) * c, -0.06, GCZ + (GRZ + RING * 0.55) * s, 0.022, GILT_DK))
TOP = GCZ + GRZ + RING                               # top of the frame
SK = TOP + 0.1                                       # the skull's centre
frame += [
    ball("skull", 0, -0.03, SK + 0.01, 0.105, BONE, sz=0.95),
    box("jaw", 0, -0.04, SK - 0.085, 0.055, 0.04, 0.035, BONE),
    ball("eye_l", -0.04, -0.12, SK + 0.0, 0.03, SOCKET),
    ball("eye_r", 0.04, -0.12, SK + 0.0, 0.03, SOCKET),
    slab("nose", [(-0.012, SK - 0.05), (0.012, SK - 0.05), (0.0, SK - 0.025)], -0.125, -0.1, SOCKET),
]
for k in (-1, 1):                                    # bat wings off the skull: scalloped
    wing = [(0.07, SK + 0.04), (0.17, SK + 0.12), (0.3, SK + 0.13), (0.38, SK + 0.06),
            (0.32, SK + 0.035), (0.27, SK - 0.01), (0.21, SK + 0.02), (0.15, SK - 0.03), (0.08, SK - 0.03)]
    if k < 0:
        wing = [(-x, z) for x, z in wing[::-1]]
    frame.append(slab(f"wing{k}", wing, -0.02, 0.01, WOOD_DK))
frame.append(slab("point", [(-0.04, GCZ - GRZ - RING + 0.01), (0.04, GCZ - GRZ - RING + 0.01),
                            (0.0, GCZ - GRZ - RING - 0.1)], -0.03, 0.02, GILT))   # a drop below

# ---- the stand: two posts with spiked finials, pins into the frame, a stretcher, curled feet ----
stand = []
PZ = GCZ + 0.12                                      # post tops
for k in (-1, 1):
    x = k * PX
    stand += [
        box(f"post{k}", x, 0.02, PZ / 2 + 0.04, 0.032, 0.032, PZ / 2 - 0.02, WOOD),
        ball(f"cap{k}", x, 0.02, PZ + 0.04, 0.045, WOOD_DK),
        slab(f"spike{k}", [(x - 0.03, PZ + 0.07), (x + 0.03, PZ + 0.07), (x, PZ + 0.2)], 0.0, 0.04, WOOD_DK),
        box(f"pin{k}", k * (PX + GRX + RING) / 2, 0.0, GCZ, (PX - GRX - RING) / 2 + 0.02, 0.02, 0.02, GILT_DK),
        ball(f"pinhead{k}", x, -0.02, GCZ, 0.035, GILT),
        box(f"foot{k}", x, 0.02, 0.04, 0.035, 0.27, 0.035, WOOD_DK),
        ball(f"toe{k}a", x, -0.25, 0.04, 0.05, WOOD_DK),
        ball(f"toe{k}b", x, 0.29, 0.04, 0.05, WOOD_DK),
    ]
stand.append(box("stretcher", 0, 0.02, 0.24, PX, 0.022, 0.025, WOOD))
stand.append(ball("stretch_knob", 0, 0.0, 0.24, 0.04, WOOD_DK))

# ---- the glint (a sweeping bright band) and the fog (blobs of mist): built per frame ----
fx = []


def clear_fx():
    for o in fx:
        bpy.data.objects.remove(o, do_unlink=True)
    fx.clear()


def glint(p):
    """A diagonal band at p (0: off the glass left, 1: off right)."""
    x = -GRX - 0.35 + p * (2 * GRX + 0.7)
    for dx, w, y in ((0, 0.075, -0.008), (0.12, 0.03, -0.009)):
        band = [(x + dx - 0.25, GCZ - 0.8), (x + dx + w - 0.25, GCZ - 0.8), (x + dx + w + 0.25, GCZ + 0.8),
                (x + dx + 0.25, GCZ + 0.8)]
        pts = clip(band, GLASS_IN)
        if len(pts) >= 3:
            fx.append(slab("glint", pts, y, y + 0.002, GLINT, None))


FOG_BLOBS = [(-0.12, GCZ - 0.3, 0.0), (0.14, GCZ - 0.15, 0.08), (-0.05, GCZ + 0.05, 0.15),
             (0.1, GCZ + 0.28, 0.22), (-0.16, GCZ + 0.32, 0.28), (0.0, GCZ - 0.45, 0.05), (0.2, GCZ + 0.05, 0.18)]


def fog(p):
    """Mist at p (0..1): blooms from the bottom up to cover the glass, then clears."""
    amount = math.sin(math.pi * p) ** 1.5                 # 0 → 1 → 0
    for i, (bx, bz, delay) in enumerate(FOG_BLOBS):
        r = 0.5 * max(0.0, min(1.0, (amount * 1.3 - delay)))
        if r < 0.02:
            continue
        circle = [(bx + r * math.cos(2 * math.pi * k / 24), bz + r * 1.15 * math.sin(2 * math.pi * k / 24))
                  for k in range(24)]
        pts = clip(circle, GLASS_IN)
        if len(pts) >= 3:
            fx.append(slab(f"fog{i}", pts, -0.006 - 0.0004 * i, -0.0058 - 0.0004 * i, FOG, None))


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
SOLID = frame + stand + [backing]
for o in SOLID:
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

# the glass ellipse in frame pixels: turned about z, it stays an axis-aligned ellipse
UNIT_PX = RES[1] / FRAME_H
c, s = math.cos(math.radians(TURN)), math.sin(math.radians(TURN))
GLASS_PX = {"cx": RES[0] * (0 - X_LO) / frame_w, "cy": RES[1] - GCZ * UNIT_PX,
            "rx": GRX * c * UNIT_PX, "ry": GRZ * UNIT_PX, "turn": TURN}


def show(objs, holdout=()):
    for o in SOLID + [glass] + sheen + fx:
        o.hide_render = o not in objs and o not in holdout
        o.is_holdout = o in holdout


def bake(sub, clips):
    """clips: name -> (count, fps, loop, frame(i, n) -> (visible objects, holdout objects))."""
    d = os.path.join(OUT, sub)
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        if f.endswith(".png"):
            os.remove(os.path.join(d, f))
    meta = {}
    for name, (n, fps, loop, frame_fn) in clips.items():
        for i in range(n):
            clear_fx()
            vis, hold = frame_fn(i, n)
            show(vis + fx, hold)
            scene.render.filepath = os.path.join(d, f"{name}_{i:04d}.png")
            bpy.ops.render.render(write_still=True)
        meta[name] = {"files": f"{name}_*.png", "count": n, "fps": fps, "loop": loop, "stride": 0}
    clear_fx()
    json.dump({"view": "front", "model": "mirror.py", "clips": meta, "unit_px": UNIT_PX,
               "origin_px": [RES[0] * -X_LO / frame_w, RES[1]], "glass_px": GLASS_PX},
              open(os.path.join(d, "clips.json"), "w"), indent=1)


def f_stand(i, n):
    if i < GLINT_ON:
        glint(i / (GLINT_ON - 1))
    return SOLID + [glass] + sheen, []


def f_fog(i, n):
    fog(i / (n - 1))
    return SOLID + [glass] + sheen, []


def f_front(i, n):
    return frame + stand, [glass]           # the glass cuts a hole through everything behind it


def f_mask(i, n):
    glass.data.materials[0] = WHITE
    return [glass], frame + stand           # only what of the glass the frame leaves visible


bake("mirror_back", {"stand": (GLINT_N, 8, True, f_stand), "fog": (FOG_N, 10, False, f_fog)})
bake("mirror_front", {"stand": (1, 1, False, f_front)})
bake("mirror_glass", {"stand": (1, 1, False, f_mask)})
print("BAKED mirror", OUT, RES, GLASS_PX)
