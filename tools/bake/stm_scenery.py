#!/usr/bin/env python3
"""St Maarten scenery and animals, drawn with PIL (no Blender): the standalone pieces.

    python3 tools/bake/stm_scenery.py [what ...]     # all when none given
    what: houses dom bonfire geese_v goose cow island flags caravel coconut

Each one is an anim folder themes/stmaarten/anim/<name>/ (clips.json + <clip>_NNNN.png, the format of
tools/bake/kaykit.py, so themes.py loads it the same way), or a plain PNG under themes/stmaarten/scenery/.

house_a, house_b, house_c  a Dutch terraced house front (a gable, brick, white frames), facing us:
    idle (light on, door shut), ring (the doorbell rings: the button lights up, little ring lines),
    open (the door swings in, the resident steps into the doorway with a bowl of sweets held out; play
    it backwards to shut), offer (holding the bowl out, a little bob, loop), dark (the window light goes
    off - the grumpy neighbour; backwards: on again), dark_idle, peek (dark: the curtain twitches, two
    eyes, back). origin_px = the bottom middle of the door step; door_px = the door's middle on the step.
dom          the Utrecht Dom tower at dusk (scenery/dom.png): a tall square gothic tower in three stages,
             the open octagonal lantern on top, a lit clock face; a background landmark.
bonfire      Sint-Maartensvuur: a pile of logs, flickering flames, sparks (burn, loop).
geese_v      a V of geese flying over (fly, loop), seen from the side and below.
goose        a white farm goose: walk, idle, honk (the neck up, the beak open, wings out), turn_front.
cow          a black-and-white Dutch cow (Holstein): walk, idle, swish (the tail), moo (head up, mouth open).
island       Sint Maarten as a cartoon island: island_whole, island_fr (the bigger north part, left),
             island_nl (the south part, right); sand, green hills, a palm. scenery/*.png.
flags        flag_fr, flag_nl, flag_utrecht (white over red, per bend), flag_columbus (a small red cloak
             on white: named for St Martin) on a pole, waving (wave, loop); origin = the pole's foot.
caravel      Columbus's caravel: sail (bobbing, rocking, the main sail with a red cross), bump (a jolt).
coconut      scenery/coconut.png, falling off the palm when the caravel bumps the island.
"""
import json, math, os, random, sys
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
THEME = os.path.join(ROOT, "themes", "stmaarten")
ANIM = os.path.join(THEME, "anim")
SCEN = os.path.join(THEME, "scenery")
S = 4                                   # supersampling
INK = (28, 24, 30, 255)


def rgb(h, a=255):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)


def mix(c, f, to=(255, 255, 255)):
    return tuple(int(c[i] + (to[i] - c[i]) * f) for i in range(3)) + ((c[3] if len(c) > 3 else 255),)


def dark(c, f):
    return mix(c, f, (0, 0, 0))


class Canvas:
    """A supersampled RGBA canvas; coordinates in 1x pixels."""

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.im = Image.new("RGBA", (w * S, h * S), (0, 0, 0, 0))
        self.d = ImageDraw.Draw(self.im)

    def P(self, pts):
        return [(x * S, y * S) for x, y in pts]

    def poly(self, pts, fill, ol=INK, w=2.0):
        self.d.polygon(self.P(pts), fill=fill)
        if ol and w:
            pp = self.P(pts)
            self.d.line(pp + [pp[0]], fill=ol, width=max(1, int(w * S)), joint="curve")

    def rect(self, x0, y0, x1, y1, fill, ol=INK, w=2.0):
        self.poly([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], fill, ol, w)

    def ell(self, cx, cy, rx, ry, fill, ol=INK, w=2.0):
        box = [(cx - rx) * S, (cy - ry) * S, (cx + rx) * S, (cy + ry) * S]
        self.d.ellipse(box, fill=fill, outline=ol if (ol and w) else None, width=max(1, int(w * S)) if ol and w else 0)

    def line(self, pts, fill=INK, w=2.0):
        self.d.line(self.P(pts), fill=fill, width=max(1, int(w * S)), joint="curve")

    def glow(self, cx, cy, r, color, alpha=120):
        g = Image.new("RGBA", self.im.size, (0, 0, 0, 0))
        gd = ImageDraw.Draw(g)
        gd.ellipse([(cx - r) * S, (cy - r) * S, (cx + r) * S, (cy + r) * S], fill=color[:3] + (alpha,))
        g = g.filter(ImageFilter.GaussianBlur(r * S * 0.45))
        self.im.alpha_composite(g)

    def under(self, other):
        """Put another canvas's picture under this one."""
        base = other.im.copy()
        base.alpha_composite(self.im)
        self.im, self.d = base, ImageDraw.Draw(base)

    def out(self):
        im = self.im.resize((self.w, self.h), Image.LANCZOS)
        for x, y in ((0, 0), (self.w - 1, 0), (0, self.h - 1), (self.w - 1, self.h - 1)):
            if im.getpixel((x, y))[3] == 0:
                im.putpixel((x, y), (0, 0, 0, 1))      # keeps the frame box (themes.py crops to what shows)
        return im


def write_anim(name, clips, extra=None):
    """clips: {clip: (frames [Image], fps, loop)} -> anim/<name>/"""
    d = os.path.join(ANIM, name)
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        if f.endswith(".png"):
            os.remove(os.path.join(d, f))
    info = {"view": "front", "baked_by": "tools/bake/stm_scenery.py", "clips": {}}
    info.update(extra or {})
    for n, (frames, fps, loop, *more) in clips.items():
        for k, im in enumerate(frames):
            im.save(os.path.join(d, f"{n}_{k:04d}.png"))
        c = {"files": f"{n}_*.png", "count": len(frames), "fps": fps, "loop": loop}
        if more:
            c.update(more[0])
        info["clips"][n] = c
    with open(os.path.join(d, "clips.json"), "w") as f:
        json.dump(info, f, indent=1)
    print("anim", name, {n: len(v[0]) for n, v in clips.items()})


def clock_hands(name, w, h, cx, cy, minute_len, hour_len, width=3.0, extra=None):
    """The hands of a clock as their own sprite (the engine sets them to the real time, over a face baked
    without hands): clips "min" (60 frames: minute k) and "hour" (48: quarter hours from 12) in a canvas
    the size of the building's, so the same origin puts them on its face. Not pinned: themes.py crops
    the atlas to the hands."""
    def hand(ang, ln, wd):
        c = Canvas(w, h)
        x1, y1 = cx + ln * math.sin(ang), cy - ln * math.cos(ang)
        c.line([(cx, cy), (x1, y1)], INK, wd)
        c.ell(cx, cy, wd * 0.8, wd * 0.8, INK, None, 0)
        return c.im.resize((w, h), Image.LANCZOS)
    write_anim(name, {
        "min": ([hand(2 * math.pi * k / 60, minute_len, width * 0.75) for k in range(60)], 1, True),
        "hour": ([hand(2 * math.pi * k / 48, hour_len, width) for k in range(48)], 1, True),
    }, extra)


def write_png(name, im):
    os.makedirs(SCEN, exist_ok=True)
    im.save(os.path.join(SCEN, name + ".png"))
    print("png", name, im.size)


# ── houses ───────────────────────────────────────────────────────────────────

HW, HH = 300, 560
GROUND = 552                          # the step's bottom
DOOR = (34, 372, 112, 538)            # the door hole
HOUSES = {
    # brick, mortar-dark, trim, door colour, gable kind, resident
    "house_a": ("#9a3f2c", "#6e2a1d", "#f4efe4", "#1f4d3a", "step", "granny"),
    "house_b": ("#6b4632", "#4a2f21", "#f4efe4", "#7a1f24", "neck", "man"),
    "house_c": ("#b0743e", "#7d4f28", "#efe6d2", "#23395e", "bell", "woman"),
}
WARM = rgb("#ffcf6e")


def gable(c, kind, brick, trim):
    top = 120
    if kind == "step":                 # a stepped gable
        pts = [(0, 560), (0, top + 80), (40, top + 80), (40, top + 40), (80, top + 40), (80, top),
               (220, top), (220, top + 40), (260, top + 40), (260, top + 80), (300, top + 80), (300, 560)]
        pts = [(0, 560), (0, 200), (34, 200), (34, 160), (68, 160), (68, 120), (102, 120), (102, 82),
               (198, 82), (198, 120), (232, 120), (232, 160), (266, 160), (266, 200), (300, 200), (300, 560)]
    elif kind == "neck":               # a neck gable with curled shoulders
        pts = [(0, 560), (0, 210), (40, 210)]
        for k in range(9):            # the curl up to the neck
            a = math.pi * k / 8
            pts.append((40 + 50 * (1 - math.cos(a)) / 2 * 1.2, 210 - 90 * math.sin(a / 2)))
        pts += [(98, 120), (98, 70), (202, 70), (202, 120)]
        for k in range(9):
            a = math.pi * (8 - k) / 8
            pts.append((260 - 50 * (1 - math.cos(a)) / 2 * 1.2, 210 - 90 * math.sin(a / 2)))
        pts += [(260, 210), (300, 210), (300, 560)]
    else:                              # a bell gable
        pts = [(0, 560), (0, 220)]
        for k in range(21):
            t = k / 20
            x = 300 * t
            y = 220 - 150 * math.sin(math.pi * t) ** 0.7
            pts.append((x, y))
        pts += [(300, 220), (300, 560)]
    c.poly(pts, brick, INK, 2.5)
    return pts


def bricks(c, x0, y0, x1, y1, mortar):
    for k, y in enumerate(range(int(y0) + 12, int(y1), 14)):
        c.line([(x0 + 3, y), (x1 - 3, y)], mortar[:3] + (90,), 1)
        off = 0 if k % 2 else 18
        for x in range(int(x0) + off, int(x1), 36):
            c.line([(x, y), (x, y + 14)], mortar[:3] + (70,), 1)


def window(c, x0, y0, x1, y1, trim, lit, curtain=0.0, eyes=False, sill=True):
    glass = mix(WARM, 0.15) if lit else rgb("#2a2f45")
    c.rect(x0 - 6, y0 - 6, x1 + 6, y1 + 6, trim, INK, 2)
    c.rect(x0, y0, x1, y1, glass, INK, 1.5)
    if lit:
        c.glow((x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) * 0.6, WARM, 90)
    # curtains: two drapes, gathered (curtain > 0: the right one pulled aside a bit - a twitch)
    cc = rgb("#c9a46a") if lit else rgb("#3a3a50")
    w = (x1 - x0) * 0.22
    c.poly([(x0, y0), (x0 + w, y0), (x0 + w * 0.6, y1), (x0, y1)], cc, INK, 1)
    rx = x1 - w - curtain * (x1 - x0) * 0.25
    c.poly([(rx, y0), (x1, y0), (x1, y1), (rx + w * 0.4, y1)], cc, INK, 1)
    if eyes:                           # behind the gap: two eyes peeking
        ex, ey = rx - 12, y0 + (y1 - y0) * 0.4
        for dx in (-7, 7):
            c.ell(ex + dx, ey, 5, 4, (240, 240, 240, 255), INK, 1)
            c.ell(ex + dx + 1.5, ey + 0.5, 2, 2, INK, None, 0)
    # the frame bars
    mx = (x0 + x1) / 2
    c.line([(mx, y0), (mx, y1)], trim, 3)
    c.line([(x0, y0 + (y1 - y0) * 0.35), (x1, y0 + (y1 - y0) * 0.35)], trim, 3)
    if sill:
        c.rect(x0 - 10, y1 + 6, x1 + 10, y1 + 12, trim, INK, 1.5)


def resident(c, who, cx, top, p, bob=0.0):
    """The resident in the doorway, from the knees up; p 0..1: stepping forward (bigger, the bowl out)."""
    s = 0.9 + 0.1 * p
    y = top + 10 + (1 - p) * 6 + bob
    skin = rgb("#f0c8a8")
    body = {"granny": rgb("#7a5a8a"), "man": rgb("#3d5c7a"), "woman": rgb("#b34a5a")}[who]
    # body
    c.poly([(cx - 26 * s, y + 160), (cx - 22 * s, y + 52), (cx + 22 * s, y + 52), (cx + 26 * s, y + 160)], body, INK, 2)
    # head
    hy = y + 30
    c.ell(cx, hy, 17 * s, 19 * s, skin, INK, 2)
    if who == "granny":
        c.ell(cx, hy - 14, 18 * s, 10 * s, rgb("#d8d8d8"), INK, 1.5)
        c.ell(cx, hy - 24, 8 * s, 7 * s, rgb("#d8d8d8"), INK, 1.5)            # a bun
        for dx in (-6, 6):
            c.ell(cx + dx, hy + 1, 5, 4, None, INK, 1.2)                       # glasses
    elif who == "man":
        c.poly([(cx - 17, hy - 8), (cx - 14, hy - 20), (cx + 14, hy - 20), (cx + 17, hy - 8)], rgb("#5a4030"), INK, 1.5)
        c.line([(cx - 9, hy + 10), (cx + 9, hy + 10)], rgb("#5a4030"), 3)      # a moustache
    else:
        c.poly([(cx - 19, hy + 12), (cx - 19, hy - 12), (cx, hy - 22), (cx + 19, hy - 12), (cx + 19, hy + 12),
                (cx + 12, hy - 4), (cx - 12, hy - 4)], rgb("#c08a3a"), INK, 1.5)
    for dx in (-6, 6):
        c.ell(cx + dx, hy + 2, 1.8, 2.2, INK, None, 0)
    c.line([(cx - 5, hy + 10), (cx, hy + 12), (cx + 5, hy + 10)], INK, 1.5)   # a smile
    # arms round the bowl, the bowl in front, held out towards the step as p grows
    by = y + 100 - 8 * p
    c.poly([(cx - 22, y + 58), (cx - 30, by), (cx - 18, by + 6), (cx - 10, y + 70)], body, INK, 1.5)
    c.poly([(cx + 22, y + 58), (cx + 30, by), (cx + 18, by + 6), (cx + 10, y + 70)], body, INK, 1.5)
    bw = 34 + 6 * p
    c.poly([(cx - bw, by - 4), (cx + bw, by - 4), (cx + bw * 0.7, by + 16), (cx - bw * 0.7, by + 16)],
           rgb("#d9d9e6"), INK, 2)
    random.seed(7)
    for k in range(9):                                  # sweets heaped in it
        sx = cx + random.uniform(-bw * 0.8, bw * 0.8)
        col = random.choice([rgb("#e8402e"), rgb("#ffcc33"), rgb("#4caf50"), rgb("#ff8a1e"), rgb("#7e57c2")])
        c.ell(sx, by - 6 - random.uniform(0, 6), 5, 4, col, INK, 1)
    for dx in (-30, 30):
        c.ell(cx + dx * 0.95, by + 2, 6, 5, skin, INK, 1.5)                   # hands on the rim


def house_frame(name, door=0.0, who_p=None, bob=0.0, lit=1.0, ring=0.0, curtain=0.0, eyes=False):
    brick_h, mortar_h, trim_h, door_h, kind, who = HOUSES[name]
    brick, mortar, trim, doorc = rgb(brick_h), rgb(mortar_h), rgb(trim_h), rgb(door_h)
    c = Canvas(HW, HH)
    gable(c, kind, brick, trim)
    bricks(c, 6, 200, 294, 548, mortar)
    # the attic hatch / window in the gable
    window(c, 128, 130, 172, 176, trim, False, sill=False)
    # upper floor
    window(c, 40, 230, 120, 312, trim, False)
    window(c, 170, 230, 250, 312, trim, lit > 0.5)
    # ground floor: the big window, the door
    on = lit > 0.5
    window(c, 150, 360, 270, 478, trim, on, curtain=curtain, eyes=eyes)
    if 0 < lit < 1:                                       # the light going off: a dim pass
        c.rect(150, 360, 270, 478, (20, 20, 40, int(120 * (1 - lit))), None, 0)
    x0, y0, x1, y1 = DOOR
    c.rect(x0 - 8, y0 - 40, x1 + 8, y1, trim, INK, 2)     # the frame and transom
    c.rect(x0, y0 - 32, x1, y0 - 6, mix(WARM, 0.3) if on else rgb("#2a2f45"), INK, 1.5)
    c.line([((x0 + x1) / 2, y0 - 32), ((x0 + x1) / 2, y0 - 6)], trim, 2)
    # the hall behind the door (warm), a lamp
    c.rect(x0, y0, x1, y1, rgb("#e9b866"), INK, 2)
    c.rect(x0, y1 - 40, x1, y1, rgb("#8a5a3a"), None, 0)
    c.line([((x0 + x1) / 2, y0), ((x0 + x1) / 2, y0 + 16)], INK, 1.5)
    c.ell((x0 + x1) / 2, y0 + 22, 9, 6, rgb("#fff1c0"), INK, 1)
    if who_p is not None:
        resident(c, who, (x0 + x1) / 2, y0, who_p, bob)
    # the door: hinged on the left, swinging in (narrower, darker) as door goes 0 → 1
    if door < 0.98:
        w = (x1 - x0) * math.cos(door * math.pi / 2)
        dc = dark(doorc, 0.35 * door)
        skew = 8 * door
        c.poly([(x0, y0), (x0 + w, y0 + skew), (x0 + w, y1 - skew), (x0, y1)], dc, INK, 2)
        if w > 30:
            c.rect(x0 + 10 * w / 78, y0 + 16, x0 + w - 10 * w / 78, y0 + 70, dark(dc, 0.15), INK, 1)
            c.rect(x0 + 10 * w / 78, y0 + 86, x0 + w - 10 * w / 78, y1 - 18, dark(dc, 0.15), INK, 1)
            c.ell(x0 + w - 12 * w / 78, (y0 + y1) / 2 + 6, 3.5, 3.5, rgb("#d8b04a"), INK, 1)
            c.rect(x0 + w * 0.3, y0 + 96, x0 + w * 0.7, y0 + 104, rgb("#d8b04a"), INK, 1)   # the letterbox
    # the doorbell to the right of the door
    bx, by = x1 + 18, 440
    c.rect(bx - 7, by - 12, bx + 7, by + 12, rgb("#c8a24a"), INK, 1.5)
    c.ell(bx, by, 4, 4, rgb("#fff3a0") if ring > 0 else rgb("#f2efe6"), INK, 1)
    if ring > 0:
        c.glow(bx, by, 12, rgb("#fff3a0"), int(160 * ring))
        for k, a in enumerate((-0.6, 0, 0.6)):
            r0, r1 = 12 + 6 * ring, 20 + 10 * ring
            c.line([(bx + r0 * math.cos(a), by + r0 * math.sin(a)), (bx + r1 * math.cos(a), by + r1 * math.sin(a))], INK, 1.5)
    # the step and the doormat
    c.rect(x0 - 12, y1, x1 + 12, GROUND, rgb("#9a9a9a"), INK, 2)
    c.rect(x0 + 6, y1 - 6, x1 - 6, y1, rgb("#8a6a3a"), INK, 1)
    # the pavement line
    c.rect(0, GROUND, HW, HH - 1, rgb("#6f6f74"), INK, 1.5)
    return c.out()


def houses():
    for name in HOUSES:
        clips = {}
        clips["idle"] = ([house_frame(name)], 1, True)
        clips["ring"] = ([house_frame(name, ring=r) for r in (1, 0.6, 1, 0.3, 0)], 8, False)
        op = [house_frame(name, door=min(1, k / 6)) for k in range(7)]
        op += [house_frame(name, door=1, who_p=k / 5) for k in range(1, 6)]
        clips["open"] = (op, 10, False)
        clips["offer"] = ([house_frame(name, door=1, who_p=1, bob=2 * math.sin(2 * math.pi * k / 6)) for k in range(6)], 6, True)
        clips["dark"] = ([house_frame(name, lit=l) for l in (1, 0.6, 0.3, 0)], 8, False)
        clips["dark_idle"] = ([house_frame(name, lit=0)], 1, True)
        pk = [house_frame(name, lit=0, curtain=c, eyes=c > 0.5) for c in (0, 0.4, 0.8, 1, 1, 1, 1, 0.6, 0.2, 0)]
        clips["peek"] = (pk, 6, False)
        door_mid = (DOOR[0] + DOOR[2]) / 2
        write_anim(name, clips, {"unit_px": 166 / 2.4, "origin_px": [door_mid, GROUND], "door_px": [door_mid, DOOR[3]],
                                 "bell_px": [DOOR[2] + 18, 440], "size_px": [HW, HH]})


# ── the Dom tower ────────────────────────────────────────────────────────────

def dom():
    """The Dom tower of Utrecht, front view at dusk: a square tower in two big square stages (the lower
    one with the passage and the clock, the upper one with tall paired lancets and corner pinnacles), on
    top the open octagonal lantern - see-through (punched out: the sky shows), flying-buttress pinnacles
    at its foot - and a small spire with a cross."""
    W, H = 300, 900
    c = Canvas(W, H)
    stone, stone2, stone3 = rgb("#8c8274"), rgb("#776e62"), rgb("#9a9082")
    ink, hole, glass = INK, (0, 0, 0, 0), rgb("#2b2f45")
    cx = W / 2

    def arch(x0, x1, y0, y1, fill, w=1.5):
        """A pointed (gothic) opening: sides from y1 up to y0 + the point."""
        r = (x1 - x0)
        ys = y0 + r * 0.866                      # the spring line; two arcs (radius = the width) meet at y0
        pts = [(x0, y1)]
        for j in range(9):                       # left arc, centre (x1, ys): 180 -> 120 degrees
            a = math.pi - (math.pi / 3) * j / 8
            pts.append((x1 + r * math.cos(a), ys - r * math.sin(a)))
        for j in range(1, 9):                    # right arc, centre (x0, ys): 60 -> 0 degrees
            a = (math.pi / 3) * (1 - j / 8)
            pts.append((x0 + r * math.cos(a), ys - r * math.sin(a)))
        pts.append((x1, y1))
        c.poly(pts, fill, ink, w)

    def pinnacle(x, y, w, h, fill=stone2):
        c.rect(x - w / 2, y - h * 0.45, x + w / 2, y, fill, ink, 1.5)
        c.poly([(x - w / 2, y - h * 0.45), (x, y - h), (x + w / 2, y - h * 0.45)], fill, ink, 1.5)
        for k in range(1, 3):                     # crockets
            yy = y - h * 0.45 - (h * 0.55) * k / 3
            ww = w / 2 * (1 - k / 3)
            c.line([(x - ww - 2, yy), (x + ww + 2, yy)], ink, 1)

    G = H - 2
    # ── the lower stage: square, corner buttresses, the passage, the clock
    L0, L1, ly = cx - 86, cx + 86, 600
    c.rect(L0, ly, L1, G, stone, ink, 2.5)
    for bx in (L0, L1 - 16):
        c.rect(bx, ly, bx + 16, G, stone2, ink, 2)
    for k in range(1, 4):                         # string courses
        y = ly + (G - ly) * k / 4
        c.line([(L0 + 16, y), (L1 - 16, y)], dark(stone, 0.25), 1.5)
    arch(cx - 30, cx + 30, 800, G, rgb("#ffcf6e"), 2)    # the passage under the tower, lit
    c.ell(cx, 670, 30, 30, rgb("#f3e6b8"), ink, 2)       # the clock
    c.glow(cx, 670, 44, rgb("#ffe8a0"), 80)
    c.ell(cx, 670, 30, 30, None, ink, 2)
    for k in range(12):                           # (the hands: dom_hands, set to the real time)
        a = 2 * math.pi * k / 12
        c.line([(cx + 25 * math.sin(a), 670 - 25 * math.cos(a)), (cx + 28 * math.sin(a), 670 - 28 * math.cos(a))], ink, 1.4)
    clock_hands("dom_hands", W, H, cx, 670, 22, 14, 3.0, {"unit_px": H, "origin_px": [0, H]})
    for dx in (-50, 50):                          # small blind lancets beside the clock
        arch(cx + dx - 9, cx + dx + 9, 640, 740, glass, 1.2)
    # the ledge and its corner pinnacles
    c.rect(L0 - 4, ly - 10, L1 + 4, ly + 2, stone2, ink, 2)
    # ── the upper stage: square, narrower, tall paired lancets
    U0, U1, uy = cx - 74, cx + 74, 370
    c.rect(U0, uy, U1, ly - 10, stone3, ink, 2.5)
    for bx in (U0, U1 - 14):
        c.rect(bx, uy, bx + 14, ly - 10, stone2, ink, 2)
    for x0 in (U0 + 24, cx + 6):
        arch(x0, x0 + 20, 400, 570, glass, 1.5)
        arch(x0 + 22, x0 + 42, 400, 570, glass, 1.5)
        c.line([(x0, 470), (x0 + 42, 470)], dark(stone3, 0.3), 1)
    for px in (L0 + 2, L1 - 2):
        pinnacle(px, ly - 10, 14, 70)
    c.rect(U0 - 4, uy - 10, U1 + 4, uy + 2, stone2, ink, 2)   # the top ledge, a balustrade
    for k in range(13):
        x = U0 + (U1 - U0) * k / 12
        c.line([(x, uy - 10), (x, uy - 18)], ink, 1.2)
    c.line([(U0 - 4, uy - 18), (U1 + 4, uy - 18)], ink, 1.5)
    # ── the octagonal lantern: three faces show (the middle full, two foreshortened), open
    O = [cx - 56, cx - 30, cx + 30, cx + 56]
    oy0, oy1 = 130, uy - 18
    c.poly([(O[0], oy1), (O[0], oy0), (O[1], oy0 - 6), (O[1], oy1)], stone2, ink, 2)
    c.poly([(O[2], oy1), (O[2], oy0 - 6), (O[3], oy0), (O[3], oy1)], stone2, ink, 2)
    c.rect(O[1], oy0 - 6, O[2], oy1, stone3, ink, 2)
    # see-through: the tall openings punched out (the sky shows), a far mullion in each
    arch(O[1] + 9, O[2] - 9, oy0 + 10, oy1 - 10, hole, 1.5)
    c.line([(cx, oy0 + 40), (cx, oy1 - 10)], ink, 2)
    c.line([(O[1] + 9, oy0 + 120), (O[2] - 9, oy0 + 120)], ink, 1.5)
    arch(O[0] + 6, O[1] - 5, oy0 + 16, oy1 - 10, hole, 1.2)
    arch(O[2] + 5, O[3] - 6, oy0 + 16, oy1 - 10, hole, 1.2)
    # flying buttresses from the corner pinnacles to the lantern
    for sgn in (-1, 1):
        bx = cx + sgn * 70
        pinnacle(bx, uy - 18, 12, 90)
        c.poly([(bx - sgn * 4, uy - 50), (cx + sgn * 56, oy0 + 60), (cx + sgn * 56, oy0 + 74), (bx - sgn * 4, uy - 36)],
               stone2, ink, 1.2)
    # the lantern's crown: a parapet and little pinnacles
    c.rect(O[0] - 3, oy0 - 14, O[3] + 3, oy0, stone2, ink, 1.8)
    for px in (O[0], O[1], cx, O[2], O[3]):
        pinnacle(px, oy0 - 14, 7, 30)
    # ── the small spire, a cross
    c.poly([(cx - 22, oy0 - 14), (cx, 38), (cx + 22, oy0 - 14)], rgb("#5f5a54"), ink, 2)
    c.line([(cx, 40), (cx, 12)], ink, 2.5)
    c.line([(cx - 7, 22), (cx + 7, 22)], ink, 2.5)
    write_png("dom", c.out())


# ── the bonfire ─────────────────────────────────────────────────────────────

def bonfire():
    W, H = 260, 300
    frames = []
    rng = random.Random(3)
    sparks = [(rng.uniform(70, 190), rng.uniform(0, 1), rng.uniform(-12, 12)) for _ in range(14)]
    for k in range(10):
        c = Canvas(W, H)
        ph = 2 * math.pi * k / 10
        c.glow(130, 200, 80, rgb("#ff9a3c"), 110 + int(30 * math.sin(ph * 2)))
        # logs, leaning in a cone
        for a, col in ((-0.5, "#6b4528"), (0.45, "#5e3c22"), (-0.15, "#7a5030"), (0.2, "#6b4528")):
            x = 130 + math.sin(a) * 90
            c.poly([(x - 8, 290), (x + 8, 290), (130 + a * 10 + 4, 150), (130 + a * 10 - 4, 150)], rgb(col), INK, 2)
        # flames: three tongues, wobbling
        for j, (cx, hh, col) in enumerate(((130, 150, "#ff7a1a"), (108, 110, "#ff9a2a"), (154, 120, "#ff9a2a"))):
            pts = []
            n = 14
            for i in range(n + 1):
                t = i / n
                side = math.sin(math.pi * t)
                w = 46 * side * (1 - 0.3 * t)
                y = 270 - hh * t
                wob = 7 * math.sin(ph * 2 + t * 6 + j) * t
                pts.append((cx - w + wob, y))
            back = []
            for i in range(n + 1):
                t = 1 - i / n
                side = math.sin(math.pi * t)
                w = 46 * side * (1 - 0.3 * t)
                y = 270 - hh * t
                wob = 7 * math.sin(ph * 2 + t * 6 + j + 0.8) * t
                back.append((cx + w + wob, y))
            c.poly(pts + back, rgb(col), dark(rgb(col), 0.4), 1.5)
            inner = [(x * 0.55 + cx * 0.45, 270 - (270 - y) * 0.7) for x, y in pts + back]
            c.poly(inner, rgb("#ffe066"), None, 0)
        # stones round it
        for sx in range(40, 230, 26):
            c.ell(sx, 286, 15, 9, rgb("#8a8a90"), INK, 1.5)
        # sparks rising
        for sx, s0, drift in sparks:
            p = (s0 + k / 10) % 1
            c.ell(sx + drift * p, 160 - 150 * p, 2.2 * (1 - p) + 0.6, 2.2 * (1 - p) + 0.6, rgb("#ffd060", int(255 * (1 - p))), None, 0)
        frames.append(c.out())
    write_anim("bonfire", {"burn": (frames, 10, True)}, {"unit_px": 75, "origin_px": [130, 290]})


# ── geese ───────────────────────────────────────────────────────────────────

def goose_side(c, x, y, s, flap, neck_up=0.0, beak_open=0.0, step=0.0, flying=False, color="#f4f2ec"):
    """A goose facing right, (x, y) = its feet / belly line middle; flap -1..1."""
    body = rgb(color)
    shade = dark(body, 0.12)
    orange = rgb("#f08a24")
    if not flying:
        for k, ph in enumerate((0, math.pi)):
            sw = math.sin(step * 2 * math.pi + ph) * 8 * s
            c.line([(x + 4 * s * (k - 0.5) * 2, y - 14 * s), (x + sw + 4 * s * (k - 0.5) * 2, y)], orange, 3 * s)
            c.poly([(x + sw - 6 * s, y), (x + sw + 8 * s, y), (x + sw + 1 * s, y - 3 * s)], orange, INK, 1)
    by = y - (26 if not flying else 0) * s
    # tail
    c.poly([(x - 34 * s, by - 6 * s), (x - 48 * s, by - 16 * s), (x - 30 * s, by + 4 * s)], shade, INK, 1.5)
    c.ell(x - 4 * s, by, 34 * s, 16 * s, body, INK, 2)
    # neck and head
    nx, ny = x + 26 * s, by - 6 * s
    hx = nx + (10 - 6 * neck_up) * s
    hy = ny - (30 + 18 * neck_up) * s
    c.line([(nx, ny), (nx + 4 * s, (ny + hy) / 2), (hx, hy)], INK, 13 * s)
    c.line([(nx, ny), (nx + 4 * s, (ny + hy) / 2), (hx, hy)], body, 9.5 * s)
    c.ell(hx + 2 * s, hy, 9 * s, 7.5 * s, body, INK, 1.5)
    bx = hx + 10 * s
    up = beak_open * 5 * s
    c.poly([(bx - 2 * s, hy - 3 * s), (bx + 12 * s, hy - 1 * s - up), (bx + 1 * s, hy + 1 * s)], orange, INK, 1)
    c.poly([(bx - 2 * s, hy + 1 * s), (bx + 11 * s, hy + 2 * s + up), (bx + 1 * s, hy + 4 * s)], dark(orange, 0.15), INK, 1)
    c.ell(hx + 4 * s, hy - 2 * s, 1.6 * s, 1.6 * s, INK, None, 0)
    # wing: folded or flapping
    if flap == 0 and not flying:
        c.poly([(x - 30 * s, by - 2 * s), (x + 10 * s, by - 10 * s), (x + 14 * s, by + 2 * s), (x - 20 * s, by + 8 * s)], shade, INK, 1.5)
    else:
        tipy = by - 40 * s * flap
        c.poly([(x - 14 * s, by - 6 * s), (x + 12 * s, by - 8 * s), (x - 6 * s, tipy - 4 * s), (x - 30 * s, tipy)], shade, INK, 1.5)


def geese_v():
    W, H = 520, 220
    frames = []
    spots = [(0, 0)] + [(-k * 58, -k * 22) for k in range(1, 4)] + [(-k * 58, k * 22) for k in range(1, 4)]
    for k in range(8):
        c = Canvas(W, H)
        for i, (dx, dy) in enumerate(spots):
            flap = math.sin(2 * math.pi * k / 8 + i * 0.9)
            goose_side(c, 440 + dx, 110 + dy, 0.62 - abs(dy) * 0.003, flap, flying=True, color="#b9b4a8")
        frames.append(c.out())
    write_anim("geese_v", {"fly": (frames, 10, True)})


def goose():
    W, H = 210, 150
    X, Y = 70, 140
    clips = {}
    clips["walk"] = ([_g(W, H, X, Y, step=k / 6, flap=0) for k in range(6)], 8, True, {"stride": 22 / W})
    clips["idle"] = ([_g(W, H, X, Y, neck_up=0.1 * math.sin(2 * math.pi * k / 6)) for k in range(6)], 4, True)
    hk = []
    for k in range(12):
        # the honk: neck up, beak wide open, wings raised and shaking, sound puffs out of the beak
        p = min(1.0, math.sin(math.pi * k / 11) * 1.6)
        hk.append(_g(W, H, X, Y, neck_up=p, beak_open=p * (1.5 + 0.3 * (k % 2)),
                     flap=(0.75 + 0.25 * (k % 2)) * p, honk=p if 1 <= k <= 10 else 0.0, honk_k=k))
    clips["honk"] = (hk, 9, False)
    write_anim("goose", clips, {"unit_px": 90, "origin_px": [X, Y]})


def _g(W, H, X, Y, honk=0.0, honk_k=0, **kw):
    c = Canvas(W, H)
    kw.setdefault("flap", 0)
    goose_side(c, X, Y, 1.0, **kw)
    if honk > 0.25:                     # where the beak is (goose_side's head, neck_up = honk)
        nu = kw.get("neck_up", 0)
        hx = X + 26 + 10 - 6 * nu
        hy = Y - 26 - 6 - (30 + 18 * nu)
        bx, by = hx + 24, hy
        # three sound strokes fanning out, and a puff
        for j, a in enumerate((-0.45, 0.0, 0.45)):
            r0, r1 = 8 + 3 * (honk_k % 2), 22 + 6 * (honk_k % 2)
            c.line([(bx + r0 * math.cos(a), by + r0 * math.sin(a)), (bx + r1 * math.cos(a), by + r1 * math.sin(a))], INK, 3)
        px, py = bx + 44 + 4 * (honk_k % 3), by - 10 - 3 * (honk_k % 3)
        rr = 9 + 2 * (honk_k % 2)
        for dx, dy, r in ((-rr, 2, rr * 0.8), (0, -4, rr), (rr, 2, rr * 0.8), (0, 5, rr * 0.8)):
            c.ell(px + dx, py + dy, r, r, rgb("#ffffff"), INK, 1.8)
        for dx, dy, r in ((-rr, 2, rr * 0.8 - 1.5), (0, -4, rr - 1.5), (rr, 2, rr * 0.8 - 1.5), (0, 5, rr * 0.8 - 1.5)):
            c.ell(px + dx, py + dy, r, r, rgb("#ffffff"), None, 0)
        c.line([(px - 3, py - 4), (px - 3, py + 2)], INK, 2.5)       # "!!"
        c.line([(px + 4, py - 4), (px + 4, py + 2)], INK, 2.5)
        c.ell(px - 3, py + 6, 1.4, 1.4, INK, None, 0)
        c.ell(px + 4, py + 6, 1.4, 1.4, INK, None, 0)
    return c.out()


# ── the cow ─────────────────────────────────────────────────────────────────

def cow_frame(step=None, swish=0.0, head_up=0.0, mouth=0.0, blink=False, chew=0.0):
    W, H = 400, 300
    c = Canvas(W, H)
    white, black, pink = rgb("#f6f4ee"), rgb("#26242a"), rgb("#f2a7a9")
    gy = 290
    bx0, bx1, by0, by1 = 90, 290, 110, 205
    # legs (far pair darker), two-segment swing
    def leg(x, ph, far):
        col = dark(white, 0.15) if far else white
        if step is None:
            a = 0
        else:
            a = math.sin(2 * math.pi * step + ph) * 0.35
        kx = x + math.sin(a) * 40
        lift = max(0, math.sin(2 * math.pi * (step or 0) + ph + 0.6)) * 10 if step is not None else 0
        fx, fy = x + math.sin(a) * 85, gy - lift
        c.line([(x, by1 - 10), (kx, by1 + 40), (fx, fy - 8)], INK, 21)
        c.line([(x, by1 - 10), (kx, by1 + 40), (fx, fy - 8)], col, 16)
        c.rect(fx - 9, fy - 12, fx + 9, fy, black, INK, 1.5)
    leg(115, math.pi, True)
    leg(260, 0, True)
    # tail: from the rump, hanging, swishing
    tx, ty = bx0 + 4, by0 + 14
    sw = swish
    pts = [(tx, ty), (tx - 18 - 10 * sw, ty + 40), (tx - 14 - 40 * sw, ty + 85 - 10 * abs(sw))]
    c.line(pts, INK, 7)
    c.line(pts, white, 4)
    c.ell(pts[-1][0], pts[-1][1] + 6, 7, 11, black, INK, 1)
    # body
    c.poly([(bx0, by0 + 10), (bx0 + 20, by0), (bx1 - 10, by0 + 4), (bx1 + 6, by0 + 30), (bx1, by1),
            (bx0 + 10, by1), (bx0 - 4, by0 + 50)], white, INK, 2.5)
    # patches
    for pts in ([(130, 112), (185, 108), (200, 140), (170, 175), (128, 160)],
                [(225, 118), (268, 112), (290, 140), (262, 170), (232, 150)],
                [(98, 150), (118, 140), (125, 190), (100, 196)]):
        c.poly(pts, black, None, 0)
    # udder
    c.ell(150, by1 + 4, 22, 13, pink, INK, 1.5)
    for dx in (-10, 0, 10):
        c.line([(150 + dx, by1 + 14), (150 + dx, by1 + 22)], pink, 4)
    leg(130, 0, False)
    leg(275, math.pi, False)
    # head: on the neck, lifted for the moo
    hx, hy = 330, 120 - 34 * head_up
    c.poly([(bx1 - 20, by0 + 6), (hx - 10, hy - 8), (hx + 6, hy + 30), (bx1 - 6, by0 + 70)], white, INK, 2)
    c.poly([(bx1 - 12, by0 + 10), (hx - 16, hy - 4), (hx - 18, hy + 18), (bx1 - 10, by0 + 40)], black, None, 0)
    # horns, ears
    c.poly([(hx - 6, hy - 22), (hx - 2, hy - 40), (hx + 6, hy - 22)], rgb("#efe6c8"), INK, 1.5)
    c.poly([(hx - 22, hy - 14), (hx - 44, hy - 20), (hx - 24, hy - 2)], black, INK, 1.5)
    c.ell(hx + 6, hy, 26, 28, white, INK, 2)
    c.ell(hx - 2, hy - 8, 14, 16, black, None, 0)
    # muzzle; mouth open for the moo
    mx, my = hx + 22, hy + 22
    c.ell(mx, my, 20, 16 + 6 * mouth, pink, INK, 2)
    c.ell(mx + 6, my - 4, 2.5, 3.5, dark(pink, 0.4), None, 0)
    c.ell(mx + 14, my - 4, 2.5, 3.5, dark(pink, 0.4), None, 0)
    if mouth > 0.05:
        c.ell(mx + 6, my + 8, 10 * mouth + 2, 7 * mouth + 1, rgb("#6a2a30"), INK, 1)
    else:
        c.line([(mx - 4, my + 9 + chew * 2), (mx + 14, my + 9)], INK, 1.5)
    if blink:
        c.line([(hx + 8, hy - 6), (hx + 18, hy - 6)], INK, 2)
    else:
        c.ell(hx + 13, hy - 6, 5, 6, (255, 255, 255, 255), INK, 1.5)
        c.ell(hx + 15, hy - 5, 2.4, 3, INK, None, 0)
    if mouth > 0.4:                        # moo lines
        for k, a in enumerate((-0.5, 0, 0.5)):
            r0, r1 = 34, 46 + 8 * mouth
            c.line([(mx + r0 * math.cos(a), my + r0 * math.sin(a)), (mx + r1 * math.cos(a), my + r1 * math.sin(a))], INK, 2)
    return c.out()


def cow():
    clips = {}
    clips["walk"] = ([cow_frame(step=k / 10) for k in range(10)], 8, True, {"stride": 150 / 400})
    clips["idle"] = ([cow_frame(chew=(k % 2), blink=(k == 5)) for k in range(8)], 4, True)
    clips["swish"] = ([cow_frame(swish=math.sin(2 * math.pi * k / 8)) for k in range(16)], 10, False)
    mo = [cow_frame(head_up=min(1, k / 4), mouth=max(0, min(1, (k - 3) / 3))) for k in range(8)]
    mo += [cow_frame(head_up=1, mouth=1)] * 4 + [cow_frame(head_up=1 - k / 4, mouth=0) for k in range(5)]
    clips["moo"] = (mo, 8, False)
    write_anim("cow", clips, {"unit_px": 95, "origin_px": [200, 290]})


# ── the island ──────────────────────────────────────────────────────────────

def island_shape(c, x0, x1, base, part, cut):
    """Draw the part of the island between x0 and x1 (the cut runs at x = cut)."""
    sand, green, green2, sea = rgb("#f2d48c"), rgb("#4caf50"), rgb("#2e8b3e"), rgb("#4fb6e6")
    # water ring
    c.ell((x0 + x1) / 2, base + 6, (x1 - x0) / 2 + 18, 14, sea[:3] + (200,), INK, 1.5)
    # sand
    pts = [(x0, base)]
    for k in range(25):
        t = k / 24
        x = x0 + (x1 - x0) * t
        y = base - 22 * math.sin(math.pi * t) ** 0.5
        pts.append((x, y))
    pts.append((x1, base))
    c.poly(pts, sand, INK, 2)
    # hills
    hp = [(x0 + 20, base - 18)]
    for k in range(31):
        t = k / 30
        x = x0 + 20 + (x1 - x0 - 40) * t
        y = base - 18 - (70 * math.sin(math.pi * t) ** 1.3 + 18 * math.sin(3 * math.pi * t + 0.6) * math.sin(math.pi * t))
        hp.append((x, y))
    hp.append((x1 - 20, base - 18))
    c.poly(hp, green, INK, 2)


def island():
    W, H = 520, 260
    base = 230

    def palm(c, x, y):
        c.line([(x, y), (x + 8, y - 50), (x + 4, y - 96)], rgb("#8a5a32"), 9)
        for a in (-2.6, -2.0, -1.2, -0.5, 0.1):
            ex, ey = x + 4 + math.cos(a) * 50, y - 96 + math.sin(a) * 26 + 14
            c.poly([(x + 4, y - 96), (ex, ey), (x + 4 + math.cos(a) * 30, y - 90)], rgb("#2e8b3e"), INK, 1.5)
        c.ell(x + 2, y - 92, 6, 6, rgb("#6a4a2a"), INK, 1)

    def whole():
        c = Canvas(W, H)
        island_shape(c, 30, 490, base, "whole", None)
        palm(c, 360, base - 30)
        return c

    cut = 300                                    # the French part (left) the bigger
    full = whole().out()
    write_png("island_whole", full)
    write_png("island_fr", full.crop((0, 0, cut, H)))
    write_png("island_nl", full.crop((cut, 0, W, H)))
    with open(os.path.join(SCEN, "island.json"), "w") as f:
        json.dump({"size_px": [W, H], "cut_px": cut, "ground_px": base + 6}, f)


# ── flags ───────────────────────────────────────────────────────────────────

def flag(name, bands, vertical):
    W, H = 150, 220
    frames = []
    for k in range(8):
        c = Canvas(W, H)
        px, top, fw, fh = 20, 12, 110, 70
        c.line([(px, H - 4), (px, top - 6)], rgb("#c8c8c8"), 5)
        c.line([(px, H - 4), (px, top - 6)], INK, 1)
        c.ell(px, top - 8, 5, 5, rgb("#e0c060"), INK, 1)
        n = len(bands)
        for i, col in enumerate(bands):
            pts = []
            # each band a strip; the flag waves along x
            if vertical:
                a0, a1 = i / n, (i + 1) / n
                for t in (a0, a1):
                    x = px + fw * t
                    pts.append((x, top + 6 * math.sin(2 * math.pi * (k / 8 - t)) * t))
                for t in (a1, a0):
                    x = px + fw * t
                    pts.append((x, top + fh + 6 * math.sin(2 * math.pi * (k / 8 - t)) * t))
            else:
                for j in range(9):
                    t = j / 8
                    pts.append((px + fw * t, top + fh * i / n + 6 * math.sin(2 * math.pi * (k / 8 - t)) * t))
                for j in range(9):
                    t = 1 - j / 8
                    pts.append((px + fw * t, top + fh * (i + 1) / n + 6 * math.sin(2 * math.pi * (k / 8 - t)) * t))
            c.poly(pts, rgb(col), None, 0)
        # outline
        o = [(px + fw * j / 8, top + 6 * math.sin(2 * math.pi * (k / 8 - j / 8)) * j / 8) for j in range(9)]
        o += [(px + fw * (1 - j / 8), top + fh + 6 * math.sin(2 * math.pi * (k / 8 - (1 - j / 8))) * (1 - j / 8)) for j in range(9)]
        c.poly(o, None, INK, 1.5)
        frames.append(c.out())
    write_anim(name, {"wave": (frames, 8, True)}, {"unit_px": 80, "origin_px": [20, H - 4]})


def flag_special(name, draw):
    """A flag whose cloth draw(c, px, top, fw, fh, wave) paints; the outline and pole as flag()."""
    W, H = 150, 220
    frames = []
    for k in range(8):
        c = Canvas(W, H)
        px, top, fw, fh = 20, 12, 110, 70
        c.line([(px, H - 4), (px, top - 6)], rgb("#c8c8c8"), 5)
        c.line([(px, H - 4), (px, top - 6)], INK, 1)
        c.ell(px, top - 8, 5, 5, rgb("#e0c060"), INK, 1)
        wave = lambda t: 6 * math.sin(2 * math.pi * (k / 8 - t)) * t
        draw(c, px, top, fw, fh, wave)
        o = [(px + fw * j / 8, top + wave(j / 8)) for j in range(9)]
        o += [(px + fw * (1 - j / 8), top + fh + wave(1 - j / 8)) for j in range(9)]
        c.poly(o, None, INK, 1.5)
        frames.append(c.out())
    write_anim(name, {"wave": (frames, 8, True)}, {"unit_px": 80, "origin_px": [20, H - 4]})


def flags():
    flag("flag_fr", ["#1f3d8c", "#f4f4f4", "#d42a32"], True)
    flag("flag_nl", ["#ae1c28", "#f4f4f4", "#21468b"], False)

    def utrecht(c, px, top, fw, fh, wave):       # per bend: white over red (top-left white)
        white = [(px + fw * j / 8, top + wave(j / 8)) for j in range(9)] + [(px, top + fh + wave(0))]
        red = [(px, top + fh + wave(0))] + [(px + fw * j / 8, top + fh + wave(j / 8)) for j in range(9)] + \
              [(px + fw, top + wave(1))]
        c.poly(white, rgb("#f4f4f4"), None, 0)
        c.poly(red, rgb("#d01f2a"), None, 0)
    flag_special("flag_utrecht", utrecht)

    def columbus(c, px, top, fw, fh, wave):      # white, a small red cloak (St Martin's) in the middle
        cloth = [(px + fw * j / 8, top + wave(j / 8)) for j in range(9)]
        cloth += [(px + fw * (1 - j / 8), top + fh + wave(1 - j / 8)) for j in range(9)]
        c.poly(cloth, rgb("#f6f2e4"), None, 0)
        mx, my = px + fw * 0.5, top + fh * 0.5 + wave(0.5)
        c.poly([(mx - 6, my - 20), (mx + 6, my - 20), (mx + 22, my + 20), (mx, my + 14), (mx - 22, my + 20)],
               rgb("#c4232b"), INK, 1)
        c.ell(mx, my - 24, 6, 6, rgb("#e0b040"), INK, 1)
    flag_special("flag_columbus", columbus)


# ── Columbus's caravel, a coconut ───────────────────────────────────────────

def caravel_frame(k, n, bump=0.0, tilt=None):
    W, H = 420, 380
    c = Canvas(W, H)
    ph = 2 * math.pi * k / n
    bob = 4 * math.sin(ph) if tilt is None else 0
    rock = (0.03 * math.sin(ph + 0.6) if tilt is None else tilt)
    cx, wl = 210, 320 + bob                 # the middle, the waterline
    def R(x, y):                             # rock about the waterline middle
        dx, dy = x - cx, y - wl
        return (cx + dx * math.cos(rock) - dy * math.sin(rock), wl + dx * math.sin(rock) + dy * math.cos(rock))
    def poly(pts, fill, w=2):
        c.poly([R(x, y) for x, y in pts], fill, INK, w)
    wood, wood2, sail, red = rgb("#8a5a32"), rgb("#6b4428"), rgb("#f4ecd6"), rgb("#c4232b")
    # masts
    for mx, top in ((150, 70), (230, 40), (310, 110)):
        c.line([R(mx, wl - 30), R(mx, top)], wood2, 7)
        c.line([R(mx, wl - 30), R(mx, top)], INK, 1)
    # sails: square on the fore and main mast (the main with a red cross), a lateen on the mizzen
    for mx, y0, y1, w, cross in ((230, 70, 200, 70, True), (150, 100, 200, 50, False)):
        bell = 10 + 4 * math.sin(ph * 2)
        poly([(mx - w, y0), (mx + w, y0), (mx + w + bell * 0.3, y1), (mx, y1 + bell), (mx - w - bell * 0.3, y1)], sail)
        if cross:
            poly([(mx - 8, y0 + 20), (mx + 8, y0 + 20), (mx + 8, y1 - 10), (mx - 8, y1 - 10)], red, 1)
            poly([(mx - 40, (y0 + y1) / 2 - 8), (mx + 40, (y0 + y1) / 2 - 8), (mx + 40, (y0 + y1) / 2 + 8),
                  (mx - 40, (y0 + y1) / 2 + 8)], red, 1)
    poly([(310, 110), (360, 220), (290, 215)], sail)
    # a pennant on the main mast
    poly([(230, 40), (262, 46 + 3 * math.sin(ph * 3)), (230, 52)], red, 1)
    # hull: high stern (left), lower bow (right)
    poly([(70, 230), (110, 232), (330, 250), (372, 236), (350, 300), (300, wl + 6), (110, wl + 6), (80, 280)], wood)
    poly([(70, 230), (70, 205), (125, 205), (125, 235)], wood2)                 # the sterncastle
    for x in range(105, 330, 36):
        c.ell(*R(x, 268), 5, 5, rgb("#3a2414"), INK, 1)                          # gun ports / portholes
    c.line([R(82, 285), R(350, 285)], wood2, 3)
    # water: a few curls
    for x in range(70, 380, 40):
        c.line([(x, 330 + bob * 0.3), (x + 18, 326 + bob * 0.3), (x + 34, 330 + bob * 0.3)], rgb("#e8f6ff"), 3)
    if bump > 0:                             # a bump: little stars at the bow
        for a in (-0.8, -0.2, 0.4):
            r0, r1 = 14, 30 + 10 * bump
            bx, by = 375, 280
            c.line([(bx + r0 * math.cos(a), by + r0 * math.sin(a)), (bx + r1 * math.cos(a), by + r1 * math.sin(a))], INK, 2.5)
    return c.out()


def caravel():
    clips = {"sail": ([caravel_frame(k, 8) for k in range(8)], 6, True),
             "bump": ([caravel_frame(0, 8, bump=b, tilt=t) for b, t in ((1, -0.08), (0.8, 0.05), (0.4, -0.03), (0, 0.01))], 8, False)}
    write_anim("caravel", clips, {"unit_px": 100, "origin_px": [210, 320]})


def turnip():
    c = Canvas(60, 70)
    for dx, a in ((-8, -0.5), (0, 0), (8, 0.5)):
        c.poly([(30 + dx * 0.4, 30), (30 + dx + 10 * a, 2), (30 + dx + 6, 6)], rgb("#4caf50"), INK, 1.2)
    c.ell(30, 44, 20, 18, rgb("#efe6f0"), INK, 2)
    c.poly([(14, 38), (46, 38), (44, 30), (16, 30)], rgb("#9c4a9a"), None, 0)
    c.ell(30, 44, 20, 18, None, INK, 2)
    c.line([(30, 62), (31, 69)], INK, 1.5)
    write_png("turnip", c.out())


def coconut():
    c = Canvas(40, 40)
    c.ell(20, 20, 15, 14, rgb("#6a4a2a"), INK, 2)
    for dx, dy in ((-4, -4), (3, -5), (0, 1)):
        c.ell(20 + dx, 20 + dy, 2, 2, rgb("#3a2614"), None, 0)
    write_png("coconut", c.out())


ALL = {"houses": houses, "dom": dom, "bonfire": bonfire, "geese_v": geese_v, "goose": goose, "cow": cow,
       "island": island, "flags": flags, "caravel": caravel, "coconut": coconut, "turnip": turnip}

if __name__ == "__main__":
    for w in (sys.argv[1:] or list(ALL)):
        ALL[w]()
