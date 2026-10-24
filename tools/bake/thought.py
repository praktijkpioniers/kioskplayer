# Draw the zombie's thought: puffs rising into a cloud with a pink brain in it (no text).
#
#   python3 tools/bake/thought.py themes/halloween/thought
#
# Frames (one PNG each, same size, the puffs start at the bottom left):
#   0-2   one, two, three puffs (the thought coming up)
#   3-5   the cloud with the brain, pulsing (brains... brains...)
#   6-8   the same with the brain crossed out (a skeleton: nothing to eat there)

import math, os, sys
from PIL import Image, ImageDraw, ImageFilter

OUT = sys.argv[1]
SS = 4                                  # supersampling
W, H = 300, 260
INK, CLOUD = (24, 22, 30, 255), (250, 250, 252, 255)
PINK, PINK_D, PINK_L = (240, 150, 170, 255), (196, 92, 120, 255), (255, 196, 210, 255)
RED = (214, 40, 40, 255)


def S(*v):
    return [round(x * SS) for x in v]


def blob(d, cx, cy, r, fill, ink=INK, line=4):
    d.ellipse(S(cx - r - line, cy - r - line, cx + r + line, cy + r + line), fill=ink)
    d.ellipse(S(cx - r, cy - r, cx + r, cy + r), fill=fill)


PUFFS = [(30, 238, 9), (58, 210, 14), (94, 178, 19)]
LOBES = [(150, 110, 62), (100, 100, 44), (205, 98, 46), (128, 62, 46), (186, 58, 44), (232, 128, 34),
         (80, 130, 32), (160, 150, 44), (116, 146, 38), (204, 146, 36)]


def cloud(d):
    for cx, cy, r in LOBES:                       # outline first, then the fill over all of it
        d.ellipse(S(cx - r - 4, cy - r - 4, cx + r + 4, cy + r + 4), fill=INK)
    for cx, cy, r in LOBES:
        d.ellipse(S(cx - r, cy - r, cx + r, cy + r), fill=CLOUD)


def brain(d, cx, cy, k):
    """A cartoon brain from the side: two humps, a stem, squiggly folds."""
    w, h = 58 * k, 40 * k
    lobes = [(-0.55, 0.1, 0.5), (-0.2, -0.35, 0.55), (0.3, -0.35, 0.55), (0.6, 0.05, 0.5), (0.05, 0.25, 0.6)]
    for dx, dy, r in lobes:
        d.ellipse(S(cx + dx * w - r * w - 3, cy + dy * h - r * h * 1.4 - 3, cx + dx * w + r * w + 3, cy + dy * h + r * h * 1.4 + 3), fill=PINK_D)
    for dx, dy, r in lobes:
        d.ellipse(S(cx + dx * w - r * w, cy + dy * h - r * h * 1.4, cx + dx * w + r * w, cy + dy * h + r * h * 1.4), fill=PINK)
    d.ellipse(S(cx - 0.55 * w, cy - 0.75 * h, cx - 0.1 * w, cy - 0.45 * h), fill=PINK_L)    # shine
    # the middle groove and the folds
    d.line(S(cx - 0.05 * w, cy - 0.85 * h, cx + 0.02 * w, cy + 0.6 * h), fill=PINK_D, width=SS * 3)
    for sx, sy, ln, ph in [(-0.75, -0.2, 0.5, 0), (-0.6, 0.35, 0.45, 1), (0.2, -0.3, 0.55, 2), (0.25, 0.3, 0.5, 0.5), (-0.45, -0.6, 0.35, 1.5)]:
        pts = []
        for i in range(9):
            t = i / 8
            pts.append((cx + (sx + ln * t) * w, cy + sy * h + 0.12 * h * math.sin(ph + t * 2 * math.pi * 1.3)))
        d.line([tuple(S(*p)) for p in pts], fill=PINK_D, width=SS * 3, joint="curve")
    d.rounded_rectangle(S(cx + 0.15 * w, cy + 0.65 * h, cx + 0.35 * w, cy + 1.05 * h), radius=SS * 4, fill=PINK_D)


def frame(n_puffs, show_brain=False, pulse=1.0, crossed=False):
    im = Image.new("RGBA", (W * SS, H * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for cx, cy, r in PUFFS[:n_puffs]:
        blob(d, cx, cy, r, CLOUD)
    if show_brain:
        cloud(d)
        brain(d, 156, 104, pulse)
        if crossed:
            r = 66
            d.ellipse(S(156 - r, 104 - r, 156 + r, 104 + r), outline=RED, width=SS * 9)
            a = math.radians(45)
            d.line(S(156 - r * math.cos(a), 104 - r * math.sin(a), 156 + r * math.cos(a), 104 + r * math.sin(a)), fill=RED, width=SS * 9)
    return im.resize((W, H), Image.LANCZOS)


os.makedirs(OUT, exist_ok=True)
frames = [frame(1), frame(2), frame(3)]
for crossed in (False, True):
    for p in (0.94, 1.0, 1.07):
        frames.append(frame(3, True, p, crossed))
for i, im in enumerate(frames):
    im.save(os.path.join(OUT, f"thought_{i}.png"), optimize=True)
print("thought frames:", len(frames), OUT)
