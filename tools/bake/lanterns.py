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
CW, CH = 120, 150
GRIP = (8, 146)
TIP = (78, 40)
INK = (25, 22, 30, 255)


def pinned(im):
    """Near-invisible corner pixels: themes.py crops frames to what shows, these keep the whole frame
    (the grip, the string's top stay at the same place in every frame)."""
    for x, y in ((0, 0), (im.width - 1, 0), (0, im.height - 1), (im.width - 1, im.height - 1)):
        im.putpixel((x, y), (0, 0, 0, 1))
    return im


def mix(c, f, to=(255, 255, 255)):
    return tuple(int(c[i] + (to[i] - c[i]) * f) for i in range(3))


def lantern_body(shape, col, light):
    """The lantern alone, hung from its top middle at (r, 0) of a (2r × 2.3r) box; light 0.85..1.15."""
    r = 26 * S
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


def carried(shape, col, k):
    im = Image.new("RGBA", (CW * S, CH * S), (0, 0, 0, 0))
    lt = light_at(k)
    body = lantern_body(shape, col, lt)
    sway = 9 * math.sin(2 * math.pi * k / FRAMES)
    tip = (TIP[0] * S, TIP[1] * S)
    # the lantern hangs from the tip, swinging about it
    big = Image.new("RGBA", (body.width * 2, body.height * 2), (0, 0, 0, 0))
    big.paste(body, (body.width // 2, body.height))
    big = big.rotate(sway, resample=Image.BICUBIC, center=(body.width, body.height))
    centre = (tip[0] - math.sin(math.radians(sway)) * body.height * 0.5,
              tip[1] + math.cos(math.radians(sway)) * body.height * 0.5)
    im.alpha_composite(glow(im.size, centre, 40 * S, col, lt))
    im.alpha_composite(big, (tip[0] - body.width, tip[1] - body.height))
    d = ImageDraw.Draw(im)
    d.line([(GRIP[0] * S, GRIP[1] * S), tip], fill=INK, width=6 * S)
    d.line([(GRIP[0] * S, GRIP[1] * S), tip], fill=(130, 90, 55, 255), width=3 * S)
    return pinned(im.resize((CW, CH), Image.LANCZOS))


def hanging(shape, col, k, string):
    body = lantern_body(shape, col, light_at(k))
    w = body.width + 50 * S
    h = string * S + body.height + 10 * S
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


def moon():
    R = 60 * S
    im = Image.new("RGBA", (4 * R, 4 * R), (0, 0, 0, 0))
    c = 2 * R
    g = Image.new("RGBA", im.size, (0, 0, 0, 0))
    ImageDraw.Draw(g).ellipse((c - 1.5 * R, c - 1.5 * R, c + 1.5 * R, c + 1.5 * R), fill=(255, 240, 190, 70))
    im.alpha_composite(g.filter(ImageFilter.GaussianBlur(R / 3)))
    d = ImageDraw.Draw(im)
    d.ellipse((c - R, c - R, c + R, c + R), fill=(250, 240, 200, 255))
    for (dx, dy, rr) in ((-0.3, -0.2, 0.22), (0.35, 0.25, 0.16), (0.05, 0.5, 0.12), (0.4, -0.4, 0.1)):
        d.ellipse((c + dx * R - rr * R, c + dy * R - rr * R, c + dx * R + rr * R, c + dy * R + rr * R),
                  fill=(228, 216, 178, 255))
    return im.resize((im.width // S, im.height // S), Image.LANCZOS)


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


def main():
    ld, pd = os.path.join(OUT, "lantern"), os.path.join(OUT, "prop")
    os.makedirs(ld, exist_ok=True)
    os.makedirs(pd, exist_ok=True)
    for shape in SHAPES:
        for name, col in COLOURS.items():
            for k in range(FRAMES):
                carried(shape, col, k).save(os.path.join(ld, f"carry_{shape}_{name}_{k}.png"), optimize=True)
                standing(shape, col, k).save(os.path.join(ld, f"stand_{shape}_{name}_{k}.png"), optimize=True)
    for i, (shape, name, string) in enumerate([("round", "orange", 40), ("star", "yellow", 70), ("round", "red", 25),
                                                ("house", "blue", 55), ("round", "green", 80), ("star", "pink", 35)]):
        for k in range(FRAMES):
            hanging(shape, COLOURS[name], (k + i) % FRAMES, string).save(os.path.join(ld, f"hang_{i}_{k}.png"), optimize=True)
    moon().save(os.path.join(pd, "moon.png"), optimize=True)
    for k in range(4):
        note(k).save(os.path.join(pd, f"note_{k}.png"), optimize=True)
        coin(k).save(os.path.join(pd, f"coin_{k}.png"), optimize=True)
    sweet().save(os.path.join(pd, "sweet.png"), optimize=True)
    fruit("mandarin").save(os.path.join(pd, "mandarin.png"), optimize=True)
    fruit("apple").save(os.path.join(pd, "apple.png"), optimize=True)
    present().save(os.path.join(pd, "present.png"), optimize=True)
    cloth().save(os.path.join(pd, "cloth.png"), optimize=True)
    print("lanterns and props written to", OUT)


if __name__ == "__main__":
    main()
