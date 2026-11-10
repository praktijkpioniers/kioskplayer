#!/usr/bin/env python3
"""St Maarten: the village church, drawn with PIL (the Canvas of stm_scenery.py, the same scale as its houses).

    python3 tools/bake/church.py       # -> themes/stmaarten/anim/church

A stone church facing us: the nave's gable behind a tower with a slate spire and a cross, a clock, the
bell in the belfry, tall pointed windows lit warm, a pointed double door at the tower's foot.
Clips: idle (door shut), bell (the bell swinging: it rings, loop), open (the two leaves swing in on the
warm candlelit inside; backwards to shut), opened (inside the candles flicker, loop).
origin_px = the middle of the door on the step (where people go in and come out).
"""
import math, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stm_scenery import Canvas, INK, rgb, mix, dark, write_anim   # noqa: E402

CW, CH = 460, 800
GROUND = 792
DX = 230                                   # the door's middle (and the tower's)
DOOR = (182, 278, 640, 782)                # x0, x1, spring of the arch, bottom
STONE, STONE_D, TRIM = rgb("#cfc3a6"), rgb("#a99c80"), rgb("#ece4d0")
SLATE, SLATE_D = rgb("#4c5160"), rgb("#383c48")
WOOD, WOOD_D = rgb("#6b3f22"), rgb("#4e2d17")
WARM, WARM_HI = rgb("#f2b54a"), rgb("#ffe39a")
GOLD = rgb("#e2b340")
UNIT_PX = 166 / 2.4                        # (as stm_scenery.py's houses)


def arch(x0, x1, ys, yb, n=10):
    """A pointed (gothic) arch: up the sides from yb to ys, two arcs meeting at the top."""
    w = x1 - x0
    pts = [(x0, yb), (x0, ys)]
    # left arc: centred on the right spring, radius w
    a_top = math.acos(0.5)                 # (the arcs meet over the middle)
    for i in range(1, n + 1):
        a = math.pi - a_top * i / n
        pts.append((x1 + w * math.cos(a), ys - w * math.sin(a)))
    for i in range(n - 1, -1, -1):
        a = a_top * i / n
        pts.append((x0 + w * math.cos(a), ys - w * math.sin(a)))
    pts.append((x1, ys))
    pts.append((x1, yb))
    return pts


def apex(x0, x1, ys):
    w = x1 - x0
    return ys - w * math.sin(math.acos(0.5))


def courses(c, x0, y0, x1, y1, step=22, col=None):
    """Stone courses: thin lines, every other row offset joints."""
    col = col or STONE_D
    y, k = y0 + step, 0
    while y < y1:
        c.line([(x0 + 2, y), (x1 - 2, y)], col, 1.0)
        off = 18 if k % 2 else 0
        x = x0 + 14 + off
        while x < x1 - 6:
            c.line([(x, y - step + 2), (x, y - 1)], col, 1.0)
            x += 36
        y, k = y + step, k + 1


def window(c, x0, x1, ys, yb, lit):
    c.poly(arch(x0 - 5, x1 + 5, ys, yb + 5), TRIM)
    glass = mix(WARM, 0.25 * (1 - lit), (60, 50, 60)) if lit > 0 else rgb("#3a3346")
    c.poly(arch(x0, x1, ys, yb), glass)
    mid = (x0 + x1) / 2
    c.line([(mid, apex(x0, x1, ys) + 4), (mid, yb)], WOOD_D, 2.0)
    for y in range(int(ys) + 18, int(yb), 26):
        c.line([(x0 + 1, y), (x1 - 1, y)], WOOD_D, 1.4)


def bell_shape(c, cx, top, ang):
    """The bell hanging from (cx, top), swung by ang radians."""
    def R(x, y):
        return (cx + x * math.cos(ang) - y * math.sin(ang), top + x * math.sin(ang) + y * math.cos(ang))
    pts = [(-7, 4), (-11, 14), (-13, 30), (-20, 40), (20, 40), (13, 30), (11, 14), (7, 4)]
    c.line([(cx, top - 8), R(0, 4)], INK, 3)
    c.poly([R(x, y) for x, y in pts], rgb("#c08a3a"))
    c.ell(*R(0, 44), 5, 5, rgb("#8a5e24"))


def church_frame(door=0.0, bell=0.0, flicker=0.0):
    c = Canvas(CW, CH)
    lit = 1.0
    # ── the nave behind: walls either side of the tower, the gable roof ──
    c.poly([(16, 520), (DX, 330), (CW - 16, 520)], SLATE)
    for k in range(1, 6):                              # slate rows
        f = k / 6
        y = 330 + 190 * f
        c.line([(DX - (DX - 16) * f, y), (DX + (CW - 16 - DX) * f, y)], SLATE_D, 1.2)
    c.rect(36, 512, CW - 36, GROUND, STONE)
    courses(c, 36, 512, CW - 36, GROUND)
    for x0 in (52, 348):                               # tall windows in the nave
        window(c, x0, x0 + 58, 600, 748, lit)
    # ── the tower ──
    tx0, tx1 = 150, 310
    c.rect(tx0, 170, tx1, GROUND, STONE)
    courses(c, tx0, 170, tx1, GROUND, 24)
    for bx in (tx0, tx1):                              # corner buttresses
        c.rect(bx - 12, 360, bx + 12, GROUND, mix(STONE, 0.12))
        for y in (470, 600, 720):
            c.poly([(bx - 14, y), (bx + 14, y), (bx + 14, y + 8), (bx - 14, y + 8)], TRIM, INK, 1.2)
    c.rect(tx0 - 8, 300, tx1 + 8, 312, TRIM)           # string course
    c.rect(tx0 - 8, 160, tx1 + 8, 176, TRIM)           # parapet
    for x in range(tx0 - 8, tx1 + 8, 22):
        c.rect(x, 146, x + 12, 162, TRIM, INK, 1.2)
    # the belfry: two pointed openings, louvres, the bell in the left one... (both: one bell big in the middle)
    c.poly(arch(186, 274, 236, 296), rgb("#2a2430"))
    bell_shape(c, DX, 216, 0.5 * math.sin(2 * math.pi * bell) if bell else 0.0)
    for y in (262, 276, 290):
        c.line([(188, y), (272, y)], WOOD_D, 1.5)
    # the clock
    c.ell(DX, 368, 38, 38, TRIM)
    c.ell(DX, 368, 31, 31, rgb("#fff4d8"), INK, 1.6)
    for k in range(12):
        a = 2 * math.pi * k / 12
        c.line([(DX + 26 * math.sin(a), 368 - 26 * math.cos(a)), (DX + 29 * math.sin(a), 368 - 29 * math.cos(a))], INK, 1.4)
    c.line([(DX, 368), (DX + 15 * math.sin(math.radians(330)), 368 - 15 * math.cos(math.radians(330)))], INK, 3)   # 11:..
    c.line([(DX, 368), (DX + 22 * math.sin(math.radians(66)), 368 - 22 * math.cos(math.radians(66)))], INK, 2)     # ..:11
    # a round window over the door
    c.ell(DX, 470, 30, 30, TRIM)
    c.ell(DX, 470, 23, 23, WARM)
    for k in range(4):
        a = math.pi * k / 4
        c.line([(DX - 23 * math.cos(a), 470 - 23 * math.sin(a)), (DX + 23 * math.cos(a), 470 + 23 * math.sin(a))], WOOD_D, 1.5)
    # the spire, the ball and the cross
    c.poly([(tx0 + 2, 148), (DX, 44), (tx1 - 2, 148)], SLATE)
    for k in range(1, 6):
        f = k / 6
        y = 44 + 104 * f
        hw = (DX - tx0 - 2) * f
        c.line([(DX - hw, y), (DX + hw, y)], SLATE_D, 1.2)
    c.ell(DX, 40, 6, 6, GOLD)
    c.rect(DX - 3, 4, DX + 3, 36, GOLD, INK, 1.2)
    c.rect(DX - 12, 13, DX + 12, 19, GOLD, INK, 1.2)
    # ── the door: the warm inside, the two leaves swinging in ──
    x0, x1, ys, yb = DOOR
    c.poly(arch(x0 - 10, x1 + 10, ys, yb), TRIM)
    inside = arch(x0, x1, ys, yb)
    if door > 0:
        c.poly(inside, mix(WARM, 0.1 + 0.08 * flicker))
        c.glow(DX, yb - 70, 60, WARM_HI, int(140 + 50 * flicker))
        # the aisle, the altar far in with candles
        c.poly([(DX - 14, yb - 80), (DX + 14, yb - 80), (DX + 34, yb), (DX - 34, yb)], rgb("#a85a3a"), None, 0)
        c.rect(DX - 20, yb - 104, DX + 20, yb - 82, rgb("#f4ead0"), INK, 1.2)
        for k, cx in enumerate((DX - 13, DX, DX + 13)):
            c.line([(cx, yb - 104), (cx, yb - 116)], rgb("#fff8e8"), 3)
            fl = 3 + 1.5 * math.sin(flicker * 6.28 + k * 2)
            c.ell(cx, yb - 120, 2.2, fl, WARM_HI, None, 0)
        for side in (-1, 1):                           # pews
            for k in range(3):
                y = yb - 70 + k * 22
                c.rect(DX + side * 18 if side > 0 else x0 + 4, y, x1 - 4 if side > 0 else DX - 18, y + 6, WOOD, INK, 1.0)
    else:
        c.poly(inside, WOOD)
    if door < 1:
        w = (x1 - x0) / 2
        for side in (-1, 1):                           # each leaf hinged at its outer edge
            hx = x0 if side < 0 else x1
            lw = w * math.cos(door * math.pi / 2)
            ex = hx - side * lw
            col = dark(WOOD, 0.3 * door)
            # (the leaf: the half of the arch on its side, squeezed towards the hinge)
            pts = []
            for px, py in inside:
                if (px <= DX + 0.5 and side < 0) or (px >= DX - 0.5 and side > 0):
                    f = abs(px - hx) / w
                    pts.append((hx - side * f * lw, py + 6 * door * f))
            if side < 0:
                pts = pts + [(ex, yb)]
            else:
                pts = [(ex, yb)] + pts
            c.poly(pts, col)
            if lw > 8:
                for k in range(1, 3):
                    xx = hx - side * lw * k / 3
                    c.line([(xx, ys - 20), (xx, yb - 6)], dark(col, 0.25), 1.2)
                for y in (ys + 6, yb - 30):            # iron hinges
                    c.line([(hx, y), (hx - side * lw * 0.8, y)], INK, 2.4)
                c.ell(ex + side * 8, (ys + yb) / 2 + 10, 3, 3, GOLD, INK, 1)
    # the steps
    c.rect(x0 - 26, yb, x1 + 26, yb + 5, TRIM, INK, 1.4)
    c.rect(x0 - 40, yb + 5, x1 + 40, GROUND, mix(TRIM, 0.0, (200, 190, 170)), INK, 1.4)
    return c.out()


def main():
    fl = [0.5 + 0.5 * math.sin(2 * math.pi * k / 4) for k in range(4)]
    clips = {
        "idle": ([church_frame()], 1, True),
        "bell": ([church_frame(bell=k / 12) for k in range(12)], 12, True),
        "open": ([church_frame(door=k / 7, flicker=0.5) for k in range(8)], 10, False),
        "opened": ([church_frame(door=1, flicker=f) for f in fl], 6, True),
    }
    write_anim("church", clips, {"unit_px": UNIT_PX, "origin_px": [DX, GROUND], "door_px": [DX, DOOR[3]],
                                 "baked_by": "tools/bake/church.py"})


if __name__ == "__main__":
    main()
