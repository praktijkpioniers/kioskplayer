#!/usr/bin/env python3
# Put a rider on a horse: composite two baked clip folders into one (no Blender needed).
#
#   python3 tools/bake/ride.py tools/bake/recipes/sint_horse.ride.json <out_dir>
#
# The spec (paths relative to the repo):
#   {"horse": "themes/sinterklaas/anim/horse",       horse.py output: clips with track.saddle
#    "rider": "<dir>",                               a kaykit.py bake at the same px per unit as the
#                                                    horse (unit_px), its clips with track.hips
#    "seat": 0.12,                                   the hips this far (world units) above the saddle
#    "clips": {"walk": {"horse": "walk", "rider": "ride"}, ...}}
# Each out clip runs over the horse clip's frames (the rider's clip looping along), or with
# "length": "rider" over the rider's (the horse's looping): e.g. Sint waving while the horse stands.
# Stride, fps and loop come from the clip that sets the length. Writes <out_dir>/<clip>_NNNN.png
# and clips.json (unit_px as the horse, origin_px moved to the new canvas), and track.hips (the
# rider's hips, for the engine to carry a speech balloon or so).
import json
import sys
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parents[2]


def frames(d, meta, clip):
    c = meta["clips"][clip]
    return [Image.open(d / f"{clip}_{i:04d}.png").convert("RGBA") for i in range(c["count"])], c


def main():
    spec = json.loads(Path(sys.argv[1]).read_text())
    out = Path(sys.argv[2])
    hd, rd = (REPO / Path(spec[k]).expanduser() for k in ("horse", "rider"))
    hm, rm = json.loads((hd / "clips.json").read_text()), json.loads((rd / "clips.json").read_text())
    px = hm["unit_px"]
    if abs(rm["unit_px"] - px) > 0.5:
        sys.exit(f"rider {rm['unit_px']:.1f} px/unit, horse {px:.1f}: bake the rider at a size to match")
    lift = spec.get("seat", 0.12) * px
    plan = {}
    for name, c in spec["clips"].items():
        hf, hc = frames(hd, hm, c["horse"])
        rf, rc = frames(rd, rm, c["rider"])
        n = len(rf) if c.get("length") == "rider" else len(hf)
        lay = []
        for i in range(n):
            h, r = hf[i % len(hf)], i % len(rf)
            sx, sy = hc["track"]["saddle"][i % len(hf)]
            hx, hy = rc["track"]["hips"][r]
            lay.append((h, rf[r], round(sx - hx), round(sy - lift - hy)))   # rider's top-left on the horse's
        base = rc if c.get("length") == "rider" else hc
        plan[name] = (lay, base, rc, n)
    # one canvas for every clip: the horse's frame grown to take the rider everywhere
    W, H = hf[0].size
    x0 = min(0, *(ox for lay, *_ in plan.values() for _, _, ox, _ in lay))
    y0 = min(0, *(oy for lay, *_ in plan.values() for _, _, _, oy in lay))
    x1 = max(W, *(ox + r.width for lay, *_ in plan.values() for _, r, ox, _ in lay))
    CW, CH = x1 - x0, H - y0
    out.mkdir(parents=True, exist_ok=True)
    for f in out.glob("*.png"):
        f.unlink()
    meta = {}
    for name, (lay, base, rc, n) in plan.items():
        hips = []
        for i, (h, r, ox, oy) in enumerate(lay):
            im = Image.new("RGBA", (CW, CH))
            im.alpha_composite(h, (-x0, -y0))
            im.alpha_composite(r, (ox - x0, oy - y0))
            im.save(out / f"{name}_{i:04d}.png", optimize=True)
            hx, hy = rc["track"]["hips"][i % rc["count"]]
            hips.append([round(ox - x0 + hx, 1), round(oy - y0 + hy, 1)])
        meta[name] = {"files": f"{name}_*.png", "count": n, "fps": base["fps"], "loop": base["loop"],
                      "stride": base.get("stride", 0.0), "track": {"hips": hips}}
    ox, oy = hm["origin_px"]
    json.dump({"view": "front", "model": "ride.py " + Path(sys.argv[1]).name, "clips": meta, "unit_px": px,
               "origin_px": [ox - x0, oy - y0]}, open(out / "clips.json", "w"), indent=1)
    print("RIDE", out, {k: v["count"] for k, v in meta.items()}, (CW, CH))


if __name__ == "__main__":
    main()
