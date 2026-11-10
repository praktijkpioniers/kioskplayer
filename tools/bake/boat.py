#!/usr/bin/env python3
# A steamboat for themes/engine.lua's "performer" (no Blender): a side-view picture (facing right)
# that bobs and rocks on the water, with smoke puffs from the funnel and, optionally, a baked
# character (kaykit.py output) on the deck.
#
#   python3 tools/bake/boat.py tools/bake/recipes/steamboat.json <out_dir>
#
# The recipe (paths relative to the repo):
#   {"image": "themes/sinterklaas/art/steamboat.png",  the boat, transparent around it
#    "height_units": 3.2,     the boat's height in world units (the sprite's "unit" scales it)
#    "funnel": [0.62, 0.08],  the top of the funnel (fractions of the trimmed picture)
#    "speed": 0.45,           world units per second while sailing
#    "rider": {"anim": "themes/sinterklaas/anim/sint", "x": 0.42, "deck": 0.52, "height_units": 1.0},
#                             the character's feet at x, deck (fractions), scaled to height_units
#    "smoke": "#b9b3ad"}
# Clips: walk (sailing; the rider stands), idle (lying still; smoke goes straight up), wave (the
# rider waves, then stands). All loop-safe: the puffs are periodic with the clip.
import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

REPO = Path(__file__).resolve().parents[2]
FPS = 12


def hexrgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def trim(im):
    a = im.getchannel("A").point(lambda v: 255 if v > 8 else 0)
    return im.crop(a.getbbox())


def puff(r, rgb, alpha):
    """one soft round puff with a darker rim, r px"""
    s = int(r * 2 + 6)
    im = Image.new("RGBA", (s, s))
    d = ImageDraw.Draw(im)
    rim = tuple(int(c * 0.72) for c in rgb)
    d.ellipse((3, 3, s - 3, s - 3), fill=rim + (int(alpha * 255),))
    d.ellipse((3 + r * 0.12, 3 + r * 0.08, s - 3 - r * 0.08, s - 3 - r * 0.14), fill=rgb + (int(alpha * 255),))
    return im.filter(ImageFilter.GaussianBlur(max(0.6, r * 0.04)))


def main():
    spec = json.loads(Path(sys.argv[1]).read_text())
    out = Path(sys.argv[2])
    boat = trim(Image.open(REPO / spec["image"]).convert("RGBA"))
    bw, bh = boat.size
    px = bh / spec.get("height_units", 3.2)              # px per world unit
    rgb = hexrgb(spec.get("smoke", "#b9b3ad"))
    fx, fy = spec.get("funnel", [0.6, 0.1])
    fx, fy = fx * bw, fy * bh
    speed = spec.get("speed", 0.45)
    # the canvas: room above for the smoke, a little at the sides for the rocking
    top, side = int(bh * 0.9), int(bw * 0.06)
    CW, CH = bw + 2 * side, bh + top
    rider = None
    if spec.get("rider"):
        r = spec["rider"]
        rd = REPO / r["anim"]
        rm = json.loads((rd / "clips.json").read_text())
        k = px / rm["unit_px"] * r.get("scale", 1.0)
        def rframes(clip):
            c = rm["clips"][clip]
            fr = []
            for i in range(c["count"]):
                im = Image.open(rd / f"{clip}_{i:04d}.png").convert("RGBA")
                fr.append(im.resize((max(1, round(im.width * k)), max(1, round(im.height * k))), Image.LANCZOS))
            return fr
        rider = {"clips": {c: rframes(c) for c in ("idle", "wave") if c in rm["clips"]},
                 "ox": rm["origin_px"][0] * k, "oy": rm["origin_px"][1] * k,
                 "x": r.get("x", 0.45) * bw, "deck": r.get("deck", 0.5) * bh}

    def frame(i, n, drift, rclip, ri, bob=1.0):
        t = i / n                                         # 0..1 over the loop
        im = Image.new("RGBA", (CW, CH))
        # smoke behind everything: puffs leave every n/4 frames and live a whole loop
        period = n / 4
        for p in range(8):
            age = ((i - p * period) % n) / n              # 0 new .. 1 gone
            if p * period >= n and age < 0:
                continue
            r = bh * (0.05 + 0.14 * age)
            a = 0.9 * (1 - age) ** 1.3
            x = side + fx - drift * bw * 0.55 * age ** 1.2 + math.sin(age * 5 + p) * bh * 0.02
            y = top + fy - bh * 0.85 * age ** 0.8
            pf = puff(r, rgb, a)
            im.alpha_composite(pf, (round(x - pf.width / 2), round(y - pf.height / 2)))
        # the boat and its rider, bobbing (two bobs per loop) and rocking a little
        layer = Image.new("RGBA", (CW, CH))
        layer.alpha_composite(boat, (side, top))
        if rider:
            fr = rider["clips"][rclip]
            rim = fr[ri % len(fr)]
            at = (round(side + rider["x"] - rider["ox"]), round(top + rider["deck"] - rider["oy"]))
            if spec.get("rider_behind"):      # behind the boat's rail: only what sticks out shows
                under = Image.new("RGBA", (CW, CH))
                under.alpha_composite(rim, at)
                under.alpha_composite(layer)
                layer = under
            else:
                layer.alpha_composite(rim, at)
        ang = math.sin(2 * math.pi * 2 * t) * 1.2 * bob
        layer = layer.rotate(ang, resample=Image.BICUBIC, center=(CW / 2, top + bh * 0.8))
        dy = round(math.sin(2 * math.pi * 2 * t + 1) * bh * 0.012 * bob)
        im.alpha_composite(layer, (0, dy))
        return im

    out.mkdir(parents=True, exist_ok=True)
    for f in out.glob("*.png"):
        f.unlink()
    meta = {}
    n = 48
    plans = {"walk": (n, 1.0, "idle", True), "idle": (n, 0.15, "idle", True)}
    if rider and "wave" in rider["clips"]:
        plans["wave"] = (n, 0.15, "wave", False)
    for name, (cnt, drift, rclip, loop) in plans.items():
        for i in range(cnt):
            if rider and name == "wave":
                w = len(rider["clips"]["wave"])
                rc, ri = ("wave", i) if i < w else ("idle", i - w)
            else:
                rc, ri = rclip, i
            frame(i, cnt, drift, rc, ri, bob=1.0 if name == "walk" else 0.6).save(out / f"{name}_{i:04d}.png", optimize=True)
        meta[name] = {"files": f"{name}_*.png", "count": cnt, "fps": FPS, "loop": loop,
                      "stride": round(speed * cnt / FPS, 3) if name == "walk" else 0.0}
    json.dump({"view": "front", "model": "boat.py " + Path(sys.argv[1]).name, "clips": meta, "unit_px": px,
               "origin_px": [side + bw / 2, top + bh * 0.97]}, open(out / "clips.json", "w"), indent=1)
    print("BOAT", out, {k: v["count"] for k, v in meta.items()}, (CW, CH), "px/unit %.1f" % px)


if __name__ == "__main__":
    main()
