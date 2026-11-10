#!/usr/bin/env python3
"""St Maarten: paper lanterns and small props, drawn with PIL (no Blender).

    python3 tools/bake/lanterns.py      # writes themes/stmaarten/{lantern,prop}/*.png

lantern/carry_<shape>_<colour>_<k>.png  a lantern on its stick, held by a child: the grip (the stick's
    lower end) at GRIP of the frame (fractions; the engine puts it on the tracked hand), the lantern
    swaying under the tip and its candle flickering over the frames
lantern/hang_<shape>_<colour>_<k>.png   hanging from the top edge on a string (decor)
lantern/stand_<shape>_<colour>_<k>.png  its stick stuck in the ground (left with a beggar)
prop/moon.png, prop/note_<k>.png, prop/sweet.png, prop/mandarin.png, prop/apple.png, prop/present.png,
prop/coin_<k>.png (a glint)
Shapes: round (a ribbed paper ball), star, house. The glow is a soft halo baked round the lantern.
"""
import math, os
from PIL import Image, ImageDraw, ImageFilter, ImageEnhance

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "themes", "stmaarten")
S = 4                                 # supersampling
FRAMES = 8
COLOURS = {"orange": (255, 140, 30), "red": (235, 50, 45), "yellow": (255, 215, 50), "blue": (70, 130, 240),
           "green": (70, 200, 90), "pink": (250, 110, 180), "purple": (160, 90, 230)}
SHAPES = ["round", "star", "house"]
# carried lantern frame (px at 1x): the grip, the stick, the lantern under its tip
# (the stick held up and forward: the lantern hangs in front of the child at chest/head height, about
# head-size; themes.py crops nothing off thanks to pinned())
CW, CH = 220, 195          # (room round the lantern for its whole glow: no hard edge)
GRIP = (8, 185)
TIP = (120, 55)
CARRY_R = 34
INK = (25, 22, 30, 255)


def pinned(im):
    """Near-invisible corner pixels: themes.py crops frames to what shows, these keep the whole frame
    (the grip, the string's top stay at the same place in every frame)."""
    for x, y in ((0, 0), (im.width - 1, 0), (0, im.height - 1), (im.width - 1, im.height - 1)):
        im.putpixel((x, y), (0, 0, 0, 1))
    return im


def mix(c, f, to=(255, 255, 255)):
    return tuple(int(c[i] + (to[i] - c[i]) * f) for i in range(3))


def lantern_body(shape, col, light, r=26):
    """The lantern alone, hung from its top middle at (r, 0) of a (2r × 2.3r) box; light 0.85..1.15."""
    r = r * S
    w, h = 2 * r + 8 * S, int(2.5 * r)
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    cx = w // 2
    lit = mix(col, 0.35 * light)
    deep = mix(col, 0.25, (60, 20, 10))
    ow = 3 * S
    d.line([(cx, 0), (cx, 8 * S)], fill=INK, width=2 * S)            # the wire
    top = 8 * S
    if shape == "round":
        box = (cx - r, top + 4 * S, cx + r, top + 4 * S + int(1.8 * r))
        d.ellipse(box, fill=lit + (255,), outline=INK, width=ow)
        cy = (box[1] + box[3]) // 2
        # paper ribs: horizontal arcs, darker
        for k in range(1, 6):
            yy = box[1] + (box[3] - box[1]) * k / 6
            half = r * math.sqrt(max(0, 1 - ((yy - cy) / (0.9 * r)) ** 2))
            d.line([(cx - half + 2 * S, yy), (cx + half - 2 * S, yy)], fill=deep + (255,), width=S + 1)
        # a glowing middle
        g = Image.new("RGBA", im.size, (0, 0, 0, 0))
        ImageDraw.Draw(g).ellipse((cx - r * 0.45, cy - r * 0.5, cx + r * 0.45, cy + r * 0.5),
                                  fill=mix(col, 0.8 * light, (255, 250, 210)) + (int(170 * light),))
        im.alpha_composite(g.filter(ImageFilter.GaussianBlur(5 * S)))
        d = ImageDraw.Draw(im)
        d.rectangle((cx - 0.45 * r, top, cx + 0.45 * r, top + 6 * S), fill=(40, 35, 45, 255))
        d.rectangle((cx - 0.45 * r, box[3] - 5 * S, cx + 0.45 * r, box[3] + S), fill=(40, 35, 45, 255))
    elif shape == "star":
        cy = top + int(1.05 * r)
        pts = []
        for k in range(10):
            a = -math.pi / 2 + k * math.pi / 5
            rr = r * (1.08 if k % 2 == 0 else 0.5)
            pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
        d.polygon(pts, fill=lit + (255,), outline=INK, width=ow)
        g = Image.new("RGBA", im.size, (0, 0, 0, 0))
        ImageDraw.Draw(g).ellipse((cx - r * 0.35, cy - r * 0.35, cx + r * 0.35, cy + r * 0.35),
                                  fill=mix(col, 0.8 * light, (255, 250, 210)) + (int(190 * light),))
        im.alpha_composite(g.filter(ImageFilter.GaussianBlur(4 * S)))
    else:   # house
        x0, x1 = cx - 0.8 * r, cx + 0.8 * r
        roof_top, eave, base = top + 2 * S, top + int(0.75 * r), top + int(1.95 * r)
        d.polygon([(cx, roof_top), (x1 + 6 * S, eave), (x0 - 6 * S, eave)], fill=deep + (255,), outline=INK, width=ow)
        d.rectangle((x0, eave, x1, base), fill=lit + (255,), outline=INK, width=ow)
        win = mix(col, 0.85 * light, (255, 245, 190)) + (255,)
        for wx in (cx - 0.42 * r, cx + 0.12 * r):
            d.rectangle((wx, eave + 0.25 * r, wx + 0.3 * r, eave + 0.55 * r), fill=win, outline=INK, width=S)
        d.rectangle((cx - 0.15 * r, base - 0.6 * r, cx + 0.15 * r, base), fill=win, outline=INK, width=S)
    return im


def glow(size, centre, rad, col, light):
    g = Image.new("RGBA", size, (0, 0, 0, 0))
    ImageDraw.Draw(g).ellipse((centre[0] - rad, centre[1] - rad, centre[0] + rad, centre[1] + rad),
                              fill=mix(col, 0.5, (255, 220, 140)) + (int(95 * light),))
    return g.filter(ImageFilter.GaussianBlur(rad / 3))


def light_at(k):
    return 1.0 + 0.1 * math.sin(2 * math.pi * k / FRAMES) + 0.05 * math.sin(6 * math.pi * k / FRAMES + 1)


def carried(shape, col, k, lit=True):
    im = Image.new("RGBA", (CW * S, CH * S), (0, 0, 0, 0))
    lt = light_at(k) if lit else 0.0
    body = lantern_body(shape, col if lit else mix(col, 0.55, (45, 35, 40)), lt, CARRY_R)
    sway = 9 * math.sin(2 * math.pi * k / FRAMES)
    tip = (TIP[0] * S, TIP[1] * S)
    # the lantern hangs from the tip, swinging about it
    big = Image.new("RGBA", (body.width * 2, body.height * 2), (0, 0, 0, 0))
    big.paste(body, (body.width // 2, body.height))
    big = big.rotate(sway, resample=Image.BICUBIC, center=(body.width, body.height))
    centre = (tip[0] - math.sin(math.radians(sway)) * body.height * 0.5,
              tip[1] + math.cos(math.radians(sway)) * body.height * 0.5)
    if lit:
        im.alpha_composite(glow(im.size, centre, 58 * S, col, lt * 1.5))
    im.alpha_composite(big, (tip[0] - body.width, tip[1] - body.height))
    d = ImageDraw.Draw(im)
    d.line([(GRIP[0] * S, GRIP[1] * S), tip], fill=INK, width=6 * S)
    d.line([(GRIP[0] * S, GRIP[1] * S), tip], fill=(130, 90, 55, 255), width=3 * S)
    return pinned(im.resize((CW, CH), Image.LANCZOS))


def hanging(shape, col, k, string):
    body = lantern_body(shape, col, light_at(k))
    w = body.width + 80 * S
    h = string * S + body.height + 34 * S
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    sway = 4 * math.sin(2 * math.pi * k / FRAMES)
    big = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(big).line([(w // 2, 0), (w // 2, string * S)], fill=(60, 55, 60, 255), width=S + 1)
    big.alpha_composite(body, ((w - body.width) // 2, string * S))
    big = big.rotate(sway, resample=Image.BICUBIC, center=(w // 2, 0))
    im.alpha_composite(glow(im.size, (w // 2 - math.sin(math.radians(sway)) * (string * S + body.height / 2),
                                      string * S + body.height // 2), 34 * S, col, light_at(k)))
    im.alpha_composite(big)
    return pinned(im.resize((w // S, h // S), Image.LANCZOS))


def standing(shape, col, k):
    """Stuck in the ground: the stick upright with a crook at the top, the lantern hanging from it."""
    body = lantern_body(shape, col, light_at(k))
    w, h = 100 * S, 150 * S
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    sx, top = 30 * S, 22 * S
    hook = (sx + 30 * S, top)
    centre = (hook[0], hook[1] + body.height * 0.5)
    im.alpha_composite(glow(im.size, centre, 38 * S, col, light_at(k)))
    im.alpha_composite(body, (hook[0] - body.width // 2, hook[1]))
    d = ImageDraw.Draw(im)
    for wd, c in ((6 * S, INK), (3 * S, (130, 90, 55, 255))):
        d.line([(sx, h - 2 * S), (sx, top), hook], fill=c, width=wd, joint="curve")
    return pinned(im.resize((w // S, h // S), Image.LANCZOS))


MOON_PALE, MOON_WARM = (236, 240, 248), (255, 205, 120)


def moon_disc(R, f=1.0, warm=0.0, glow_a=80):
    """The moon: a pale silver-white disc with a soft glow and faint craters, in a (4R x 4R) canvas;
    f its size (1 = the full moon), warm 0..1 its colour going over to a lantern's (on its way down)."""
    im = Image.new("RGBA", (4 * R, 4 * R), (0, 0, 0, 0))
    c = 2 * R
    r = R * f
    col = mix(MOON_PALE, warm, MOON_WARM)
    g = Image.new("RGBA", im.size, (0, 0, 0, 0))
    ImageDraw.Draw(g).ellipse((c - 1.55 * r, c - 1.55 * r, c + 1.55 * r, c + 1.55 * r), fill=mix(col, 0.3) + (glow_a,))
    im.alpha_composite(g.filter(ImageFilter.GaussianBlur(max(1, r / 3))))
    d = ImageDraw.Draw(im)
    d.ellipse((c - r, c - r, c + r, c + r), fill=col + (255,))
    cr = Image.new("RGBA", im.size, (0, 0, 0, 0))
    cd = ImageDraw.Draw(cr)
    for (dx, dy, rr) in ((-0.32, -0.18, 0.2), (0.3, 0.28, 0.15), (0.02, 0.52, 0.1), (0.42, -0.36, 0.09), (-0.45, 0.35, 0.08)):
        cd.ellipse((c + (dx - rr) * r, c + (dy - rr) * r, c + (dx + rr) * r, c + (dy + rr) * r),
                   fill=mix(col, 0.22, (140, 146, 165)) + (150,))
    im.alpha_composite(cr.filter(ImageFilter.GaussianBlur(max(1, r / 14))))
    return im


def moon():
    R = 60 * S
    return moon_disc(R).resize((4 * R // S, 4 * R // S), Image.LANCZOS)


def moonfly(k, n=8):
    """The moon at n sizes: k 0 = lantern-size and warm (on a child's stick) .. n-1 = the full moon, pale."""
    R = 60 * S
    f = k / (n - 1)
    return pinned(moon_disc(R, 0.32 + 0.68 * f, 1 - f).resize((4 * R // S, 4 * R // S), Image.LANCZOS))


def carried_moon(k):
    """The moon as a lantern on a child's stick (same frame as carried())."""
    im = Image.new("RGBA", (CW * S, CH * S), (0, 0, 0, 0))
    sway = 9 * math.sin(2 * math.pi * k / FRAMES)
    tip = (TIP[0] * S, TIP[1] * S)
    r = 26 * S
    disc = moon_disc(r, 1.0, 0.35, glow_a=int(110 * light_at(k)))
    hang = 14 * S
    cx = tip[0] - math.sin(math.radians(sway)) * (hang + r)
    cy = tip[1] + math.cos(math.radians(sway)) * (hang + r)
    im.alpha_composite(disc, (int(cx - 2 * r), int(cy - 2 * r)))
    d = ImageDraw.Draw(im)
    d.line([tip, (cx + math.sin(math.radians(sway)) * r, cy - math.cos(math.radians(sway)) * r)], fill=INK, width=2 * S)
    d.line([(GRIP[0] * S, GRIP[1] * S), tip], fill=INK, width=6 * S)
    d.line([(GRIP[0] * S, GRIP[1] * S), tip], fill=(130, 90, 55, 255), width=3 * S)
    return pinned(im.resize((CW, CH), Image.LANCZOS))


def bare_stick():
    im = Image.new("RGBA", (CW * S, CH * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    tip = (TIP[0] * S, TIP[1] * S)
    d.line([(GRIP[0] * S, GRIP[1] * S), tip], fill=INK, width=6 * S)
    d.line([(GRIP[0] * S, GRIP[1] * S), tip], fill=(130, 90, 55, 255), width=3 * S)
    d.line([tip, (tip[0], tip[1] + 10 * S)], fill=INK, width=2 * S)          # (the bit of wire left)
    return pinned(im.resize((CW, CH), Image.LANCZOS))


def loose(shape, col):
    """A lantern come off its stick (flying off): the lantern alone, its glow round it."""
    w = 160 * S
    im = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    body = lantern_body(shape, col, 1.0, CARRY_R)
    im.alpha_composite(glow(im.size, (w // 2, w // 2), 58 * S, col, 1.5))
    im.alpha_composite(body, ((w - body.width) // 2, (w - body.height) // 2))
    return pinned(im.resize((w // S, w // S), Image.LANCZOS))


def note(k):
    w, h = 30 * S, 44 * S
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    col = [(255, 235, 150, 255), (255, 255, 255, 255), (190, 225, 255, 255)][k % 3]
    for wd, c in ((5 * S, INK), (0, col)):
        def head(x, y):
            d.ellipse((x - 7 * S - wd / 2, y - 5 * S - wd / 2, x + 7 * S + wd / 2, y + 5 * S + wd / 2), fill=c)
        if k % 2 == 0:       # a quaver
            head(10 * S, 36 * S)
            d.line([(16 * S, 36 * S), (16 * S, 4 * S)], fill=c, width=3 * S + wd)
            d.line([(16 * S, 4 * S), (26 * S, 14 * S)], fill=c, width=3 * S + wd)
        else:                # two beamed
            head(7 * S, 38 * S); head(22 * S, 34 * S)
            d.line([(13 * S, 38 * S), (13 * S, 8 * S)], fill=c, width=3 * S + wd)
            d.line([(28 * S, 34 * S), (28 * S, 4 * S)], fill=c, width=3 * S + wd)
            d.line([(13 * S, 8 * S), (28 * S, 4 * S)], fill=c, width=5 * S + wd)
    return im.resize((w // S, h // S), Image.LANCZOS)


def sweet():
    w, h = 44 * S, 22 * S
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = (240, 70, 90, 255)
    for wd, col in ((3 * S, INK), (0, c)):
        d.polygon([(2 * S - wd, 2 * S - wd), (14 * S, 11 * S), (2 * S - wd, 20 * S + wd)], fill=col)
        d.polygon([(42 * S + wd, 2 * S - wd), (30 * S, 11 * S), (42 * S + wd, 20 * S + wd)], fill=col)
        d.ellipse((11 * S - wd, 3 * S - wd, 33 * S + wd, 19 * S + wd), fill=col)
    d.line([(16 * S, 6 * S), (28 * S, 16 * S)], fill=(255, 255, 255, 255), width=3 * S)
    return im.resize((w // S, h // S), Image.LANCZOS)


def fruit(kind):
    w = h = 36 * S
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    col = (245, 140, 30, 255) if kind == "mandarin" else (215, 40, 40, 255)
    d.ellipse((3 * S, 7 * S, 33 * S, 34 * S), fill=col, outline=INK, width=3 * S)
    d.ellipse((9 * S, 12 * S, 15 * S, 18 * S), fill=(255, 255, 255, 120))
    d.line([(18 * S, 9 * S), (19 * S, 2 * S)], fill=(90, 60, 30, 255), width=3 * S)
    d.ellipse((19 * S, 2 * S, 30 * S, 8 * S), fill=(60, 160, 60, 255), outline=INK, width=2 * S)
    return im.resize((w // S, h // S), Image.LANCZOS)


def present():
    w = h = 38 * S
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rectangle((3 * S, 12 * S, 35 * S, 35 * S), fill=(70, 120, 220, 255), outline=INK, width=3 * S)
    d.rectangle((16 * S, 12 * S, 22 * S, 35 * S), fill=(250, 210, 60, 255))
    d.rectangle((3 * S, 20 * S, 35 * S, 25 * S), fill=(250, 210, 60, 255))
    d.ellipse((8 * S, 3 * S, 19 * S, 13 * S), outline=(250, 210, 60, 255), width=3 * S)
    d.ellipse((19 * S, 3 * S, 30 * S, 13 * S), outline=(250, 210, 60, 255), width=3 * S)
    return im.resize((w // S, h // S), Image.LANCZOS)


def coin(k):
    w = h = 30 * S
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.ellipse((5 * S, 5 * S, 25 * S, 25 * S), fill=(235, 190, 60, 255), outline=(120, 85, 20, 255), width=2 * S)
    d.ellipse((10 * S, 10 * S, 20 * S, 20 * S), outline=(200, 150, 40, 255), width=S)
    if k in (1, 2):     # the glint
        a = 1 if k == 1 else 0.6
        c = (15 * S, 15 * S)
        L = 13 * S * a
        d.line([(c[0] - L, c[1]), (c[0] + L, c[1])], fill=(255, 255, 240, 255), width=2 * S)
        d.line([(c[0], c[1] - L), (c[0], c[1] + L)], fill=(255, 255, 240, 255), width=2 * S)
    return im.resize((w // S, h // S), Image.LANCZOS)


def cloth():
    """The piece of red cloak St Martin hands over (flying from his hand to the beggar)."""
    w, h = 60 * S, 40 * S
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    pts = [(4 * S, 10 * S), (30 * S, 3 * S), (56 * S, 9 * S), (52 * S, 36 * S), (40 * S, 30 * S), (28 * S, 37 * S),
           (16 * S, 31 * S), (6 * S, 36 * S)]
    d.polygon(pts, fill=(196, 35, 43, 255), outline=INK, width=3 * S)
    d.line([(14 * S, 10 * S), (18 * S, 30 * S)], fill=(150, 24, 32, 255), width=2 * S)
    d.line([(34 * S, 8 * S), (36 * S, 30 * S)], fill=(150, 24, 32, 255), width=2 * S)
    return im.resize((w // S, h // S), Image.LANCZOS)


def spark(k):
    """A little spark jumping from one lantern to the other (4 frames: a twinkle)."""
    w = 40 * S
    im = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    c = w // 2
    g = Image.new("RGBA", im.size, (0, 0, 0, 0))
    ImageDraw.Draw(g).ellipse((c - 14 * S, c - 14 * S, c + 14 * S, c + 14 * S), fill=(255, 220, 120, 150))
    im.alpha_composite(g.filter(ImageFilter.GaussianBlur(5 * S)))
    d = ImageDraw.Draw(im)
    rr = (16, 11, 14, 9)[k % 4] * S
    for a in range(4):
        t = math.pi / 4 * (2 * a + (k % 2))
        d.line([(c - rr * math.cos(t), c - rr * math.sin(t)), (c + rr * math.cos(t), c + rr * math.sin(t))],
               fill=(255, 250, 200, 255), width=2 * S)
    d.ellipse((c - 4 * S, c - 4 * S, c + 4 * S, c + 4 * S), fill=(255, 255, 240, 255))
    return im.resize((w // S, w // S), Image.LANCZOS)


def flare(k):
    """The POOF: a big flare of flame (k 0..3 growing), then smoke (puff)."""
    w = 120 * S
    im = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    c = w // 2
    f = (0.45, 0.8, 1.0, 0.85)[k % 4]
    g = Image.new("RGBA", im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(g)
    for rad, col in ((56, (255, 140, 30, 170)), (40, (255, 200, 60, 220)), (22, (255, 250, 210, 255))):
        r = rad * f * S
        d.ellipse((c - r, c - r * 1.15, c + r, c + r * 0.85), fill=col)
    im.alpha_composite(g.filter(ImageFilter.GaussianBlur(4 * S)))
    return pinned(im.resize((w // S, w // S), Image.LANCZOS))


def puff(k):
    """A grey puff of smoke (4 frames: spreading, fading)."""
    w = 140 * S
    im = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    f = 0.55 + 0.15 * k
    al = (230, 210, 170, 110)[k % 4]
    for i, (dx, dy, r) in enumerate([(0, 0, 30), (-26, 8, 22), (26, 6, 24), (-12, -20, 22), (16, -22, 20), (0, 20, 20)]):
        g = 120 + 15 * (i % 3)
        R = r * f * S
        x, y = w // 2 + dx * f * S, w // 2 + dy * f * S
        d.ellipse((x - R, y - R, x + R, y + R), fill=(g, g, g + 5, al), outline=(70, 70, 75, al), width=2 * S)
    return pinned(im.filter(ImageFilter.GaussianBlur(S)).resize((w // S, w // S), Image.LANCZOS))


def soot():
    """Sooty face and frizzy hair: an overlay over a kid's head (the head's middle at the frame's middle)."""
    w = 90 * S
    im = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = w // 2
    rnd = __import__("random").Random(11)
    for i in range(46):                                   # frizz: wiry black zigzags out of the top of the head
        a = math.pi * (1.05 + 0.9 * i / 45)
        x0, y0 = c + 30 * S * math.cos(a), c + 6 * S + 30 * S * math.sin(a)
        pts = [(x0, y0)]
        for j in range(4):
            ln = rnd.uniform(4, 7) * S
            aa = a + rnd.uniform(-0.7, 0.7)
            pts.append((pts[-1][0] + ln * math.cos(aa), pts[-1][1] + ln * math.sin(aa)))
        d.line(pts, fill=(30, 26, 26, 255), width=int(1.6 * S))
    g = Image.new("RGBA", im.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(g)
    for _ in range(14):                                   # soot smudges on the face
        x, y, r = c + rnd.uniform(-20, 20) * S, c + rnd.uniform(-2, 22) * S, rnd.uniform(5, 10) * S
        gd.ellipse((x - r, y - r, x + r, y + r), fill=(35, 30, 30, 120))
    im.alpha_composite(g.filter(ImageFilter.GaussianBlur(3 * S)))
    return pinned(im.resize((w // S, w // S), Image.LANCZOS))


BURN_N = 10


def burning(k, n=BURN_N):
    """A paper lantern catching fire (k 0..n-1): flames lick up from the candle, the paper chars and
    shrinks, bits of ash fall; at the end only the wire, smoking, on the stick."""
    f = k / (n - 1)
    rnd = __import__("random").Random(100 + k)
    im = Image.new("RGBA", (CW * S, CH * S), (0, 0, 0, 0))
    tip = (TIP[0] * S, TIP[1] * S)
    col = COLOURS["orange"]
    heat = min(1.0, f / 0.3) if f < 0.3 else max(0.0, 1 - (f - 0.3) / 0.45)
    keep = 1.0 - max(0.0, min(1.0, (f - 0.25) / 0.55))       # how much paper is left
    centre = (tip[0], tip[1] + int(0.5 * 2.5 * CARRY_R * S))
    if keep > 0.05:
        char = mix(col, min(1.0, 0.25 + 0.9 * f), (40, 28, 22))
        body = lantern_body("round", char, 0.6 + 0.6 * heat, CARRY_R)
        bw, bh = max(1, int(body.width * (0.45 + 0.55 * keep))), max(1, int(body.height * (0.35 + 0.65 * keep)))
        body = body.resize((bw, bh), Image.LANCZOS)
        im.alpha_composite(glow(im.size, centre, 60 * S, (255, 150, 40), 0.8 + 1.4 * heat))
        im.alpha_composite(body, (tip[0] - bw // 2, tip[1] + int(8 * S * (1 - keep))))
    d = ImageDraw.Draw(im)
    # flames: tongues round the burning paper
    if heat > 0.02:
        g = Image.new("RGBA", im.size, (0, 0, 0, 0))
        gd = ImageDraw.Draw(g)
        base_y = centre[1] + 0.6 * CARRY_R * S * keep
        for i in range(7):
            x = centre[0] + (i - 3) * 9 * S * (0.6 + 0.4 * keep) + rnd.uniform(-3, 3) * S
            h = (26 + 30 * rnd.random()) * S * heat * (1.25 if i in (2, 3, 4) else 0.85)
            w = (9 + 4 * rnd.random()) * S * (0.5 + 0.5 * heat)
            lean = rnd.uniform(-6, 6) * S
            for sc, c in ((1.0, (255, 110, 20, 230)), (0.66, (255, 200, 60, 240)), (0.33, (255, 250, 210, 255))):
                hh, ww = h * sc, w * sc
                gd.polygon([(x - ww, base_y), (x + lean * sc, base_y - hh), (x + ww, base_y),
                            (x, base_y + ww * 0.6)], fill=c)
        im.alpha_composite(g.filter(ImageFilter.GaussianBlur(1.5 * S)))
        d = ImageDraw.Draw(im)
    # ash falling
    if f > 0.3:
        for i in range(int(10 * min(1, (f - 0.3) / 0.4))):
            x = centre[0] + rnd.uniform(-30, 30) * S
            y = centre[1] + rnd.uniform(10, 70) * S
            r = rnd.uniform(1.5, 3.5) * S
            g_ = rnd.randint(40, 90)
            d.ellipse((x - r, y - r * 0.6, x + r, y + r * 0.6), fill=(g_, g_, g_, 230))
    # the stick, the wire (a glowing end at the last), smoke at the end
    d.line([(GRIP[0] * S, GRIP[1] * S), tip], fill=INK, width=6 * S)
    d.line([(GRIP[0] * S, GRIP[1] * S), tip], fill=(130, 90, 55, 255), width=3 * S)
    d.line([tip, (tip[0], tip[1] + 10 * S)], fill=INK, width=2 * S)
    if f > 0.8:
        d.ellipse((tip[0] - 3 * S, tip[1] + 8 * S, tip[0] + 3 * S, tip[1] + 14 * S), fill=(255, 120, 40, 255))
        s_ = Image.new("RGBA", im.size, (0, 0, 0, 0))
        sd = ImageDraw.Draw(s_)
        for j in range(4):
            r = (5 + 3 * j) * S
            sx_, sy_ = tip[0] + j * 9 * S, tip[1] + 4 * S - j * 8 * S
            sd.ellipse((sx_ - r, sy_ - r, sx_ + r, sy_ + r), fill=(150, 150, 155, 120 - 22 * j))
        im.alpha_composite(s_.filter(ImageFilter.GaussianBlur(3 * S)))
    return pinned(im.resize((CW, CH), Image.LANCZOS))


def ash():
    """What's left on the ground: a little grey heap with a glowing bit and the black wire ring."""
    w, h = 60 * S, 26 * S
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.ellipse((4 * S, 12 * S, w - 4 * S, h + 12 * S), fill=(178, 174, 170, 255), outline=(110, 106, 104, 255), width=S)
    rnd = __import__("random").Random(5)
    for _ in range(12):
        x, y = rnd.uniform(12, 48) * S, rnd.uniform(13, 22) * S
        g = rnd.randint(70, 150)
        d.ellipse((x - 2 * S, y - S, x + 2 * S, y + S), fill=(g, g, g, 255))
    d.ellipse((30 * S, 15 * S, 35 * S, 19 * S), fill=(255, 120, 40, 255))
    d.arc((14 * S, 9 * S, 34 * S, 21 * S), 180, 360, fill=(40, 36, 40, 255), width=S)
    return pinned(im.resize((w // S, h // S), Image.LANCZOS))


LED = (225, 240, 255)


def led(k, on=True):
    """A shop lantern on an LED stick: a white-blue paper ball, a cool even light (no flicker), a black
    plastic stick with a battery handle and a little bulb at the tip; off: dark paper, a dead bulb."""
    im = Image.new("RGBA", (CW * S, CH * S), (0, 0, 0, 0))
    col = (110, 170, 250)
    body = lantern_body("round", col if on else mix(col, 0.55, (45, 35, 40)), 1.15 if on else 0.0, CARRY_R)
    if on:     # (white LED light, not the candle's warm one)
        g = Image.new("RGBA", body.size, (0, 0, 0, 0))
        cx, cy = body.width // 2, int(body.height * 0.5)
        ImageDraw.Draw(g).ellipse((cx - 14 * S, cy - 14 * S, cx + 14 * S, cy + 14 * S), fill=LED + (200,))
        body.alpha_composite(g.filter(ImageFilter.GaussianBlur(5 * S)))
    sway = 7 * math.sin(2 * math.pi * k / FRAMES)
    tip = (TIP[0] * S, TIP[1] * S)
    big = Image.new("RGBA", (body.width * 2, body.height * 2), (0, 0, 0, 0))
    big.paste(body, (body.width // 2, body.height))
    big = big.rotate(sway, resample=Image.BICUBIC, center=(body.width, body.height))
    centre = (tip[0] - math.sin(math.radians(sway)) * body.height * 0.5,
              tip[1] + math.cos(math.radians(sway)) * body.height * 0.5)
    if on:
        im.alpha_composite(glow(im.size, centre, 58 * S, LED, 1.4))
    im.alpha_composite(big, (tip[0] - body.width, tip[1] - body.height))
    d = ImageDraw.Draw(im)
    gx, gy = GRIP[0] * S, GRIP[1] * S
    d.line([(gx, gy), tip], fill=INK, width=6 * S)
    d.line([(gx, gy), tip], fill=(45, 45, 52, 255), width=3 * S)
    # the battery handle (along the stick, at the grip) with a little switch
    ang = math.atan2(tip[1] - gy, tip[0] - gx)
    hl = 30 * S
    hx, hy = gx + hl * math.cos(ang), gy + hl * math.sin(ang)
    d.line([(gx, gy), (hx, hy)], fill=INK, width=12 * S)
    d.line([(gx, gy), (hx, hy)], fill=(30, 30, 36, 255), width=9 * S)
    sx, sy = gx + 0.6 * hl * math.cos(ang), gy + 0.6 * hl * math.sin(ang)
    d.ellipse((sx - 3 * S, sy - 3 * S, sx + 3 * S, sy + 3 * S), fill=(220, 50, 50, 255) if on else (90, 40, 40, 255))
    # the bulb at the tip
    d.ellipse((tip[0] - 4 * S, tip[1] - 2 * S, tip[0] + 4 * S, tip[1] + 6 * S),
              fill=(LED + (255,)) if on else (120, 120, 125, 255), outline=INK, width=S)
    return pinned(im.resize((CW, CH), Image.LANCZOS))


def main():
    ld, pd = os.path.join(OUT, "lantern"), os.path.join(OUT, "prop")
    os.makedirs(ld, exist_ok=True)
    os.makedirs(pd, exist_ok=True)
    for shape in SHAPES:
        for name, col in COLOURS.items():
            for k in range(FRAMES):
                carried(shape, col, k).save(os.path.join(ld, f"carry_{shape}_{name}_{k}.png"), optimize=True)
                if k == 0:     # unlit: dark paper, no glow, one frame (a child waiting for a light)
                    carried(shape, col, k, lit=False).save(os.path.join(ld, f"unlit_{shape}_{name}.png"), optimize=True)
                standing(shape, col, k).save(os.path.join(ld, f"stand_{shape}_{name}_{k}.png"), optimize=True)
    for i, (shape, name, string) in enumerate([("round", "orange", 40), ("star", "yellow", 70), ("round", "red", 25),
                                                ("house", "blue", 55), ("round", "green", 80), ("star", "pink", 35)]):
        for k in range(FRAMES):
            hanging(shape, COLOURS[name], (k + i) % FRAMES, string).save(os.path.join(ld, f"hang_{i}_{k}.png"), optimize=True)
    moon().save(os.path.join(pd, "moon.png"), optimize=True)
    for k in range(8):
        moonfly(k).save(os.path.join(pd, f"moonfly_{k}.png"), optimize=True)
        carried_moon(k).save(os.path.join(ld, f"carry_moon_{k}.png"), optimize=True)
    bare_stick().save(os.path.join(ld, "stick.png"), optimize=True)
    for shape in SHAPES:
        for name, col in COLOURS.items():
            loose(shape, col).save(os.path.join(ld, f"loose_{shape}_{name}.png"), optimize=True)
    for k in range(4):
        note(k).save(os.path.join(pd, f"note_{k}.png"), optimize=True)
        coin(k).save(os.path.join(pd, f"coin_{k}.png"), optimize=True)
    sweet().save(os.path.join(pd, "sweet.png"), optimize=True)
    for k in range(4):
        spark(k).save(os.path.join(pd, f"spark_{k}.png"), optimize=True)
        flare(k).save(os.path.join(pd, f"flare_{k}.png"), optimize=True)
        puff(k).save(os.path.join(pd, f"puff_{k}.png"), optimize=True)
    soot().save(os.path.join(pd, "soot.png"), optimize=True)
    for k in range(BURN_N):
        burning(k).save(os.path.join(ld, f"burn_{k}.png"), optimize=True)
    ash().save(os.path.join(pd, "ash.png"), optimize=True)
    for k in range(FRAMES):
        led(k).save(os.path.join(ld, f"carry_led_{k}.png"), optimize=True)
    led(0, on=False).save(os.path.join(ld, "led_off.png"), optimize=True)
    fruit("mandarin").save(os.path.join(pd, "mandarin.png"), optimize=True)
    fruit("apple").save(os.path.join(pd, "apple.png"), optimize=True)
    present().save(os.path.join(pd, "present.png"), optimize=True)
    cloth().save(os.path.join(pd, "cloth.png"), optimize=True)
    print("lanterns and props written to", OUT)


if __name__ == "__main__":
    main()
