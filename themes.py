#!/usr/bin/env python3
# themes.py — seasonal theme calendar + sprite preparation for the mpv theme engine (themes/engine.lua)
#
# Python decides *which* theme is active and *how strong*: a level 0..9 (see LEVELS).
# The Lua script inside mpv does all drawing/animation; we only send it script-messages.
#
#   themes/events.json        calendar: when each event runs, its prime day(s), lead-in ramp
#   themes/<theme>/theme.json sprites + elements (what to draw, from which level on)
#   themes/<theme>/*.png      artwork (transparent PNG)
#
# Sprites are converted once to premultiplied BGRA atlases (what mpv overlay-add wants),
# scaled for the current screen height, and cached under ~/.cache/kioskplayer/sprites.

from __future__ import annotations

import datetime as dt
import hashlib
import json
import math
import threading
import time
from pathlib import Path
from typing import Any, Callable, Optional

try:
    from PIL import Image, ImageChops, ImageEnhance  # type: ignore
except Exception:
    Image = None
    ImageChops = None


THEMES_DIR = Path(__file__).resolve().parent / "themes"
EVENTS_PATH = THEMES_DIR / "events.json"
ENGINE_LUA = THEMES_DIR / "engine.lua"
CACHE_DIR = Path("~/.cache/kioskplayer/sprites").expanduser()

WEEKDAYS = {"mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6}


# ─────────────────────────────────────────────────────────────────────────────
# Calendar
# ─────────────────────────────────────────────────────────────────────────────

def easter(year: int) -> dt.date:
    # Anonymous Gregorian algorithm
    a = year % 19
    b, c = divmod(year, 100)
    d, e = divmod(b, 4)
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i, k = divmod(c, 4)
    l = (32 + 2 * e + 2 * i - h - k) % 7
    m = (a + 11 * h + 22 * l) // 451
    month, day = divmod(h + l - 7 * m + 114, 31)
    return dt.date(year, month, day + 1)


def resolve_date(spec: Any, year: int) -> dt.date:
    """
    Date spec forms:
      "10-31"                                   fixed month-day
      {"month": 11, "weekday": "thu", "nth": 4} nth weekday of month (nth=-1 → last)
      {"easter": -47}                           days relative to Easter Sunday
      any dict form may add "offset": N         shift by N days (e.g. Black Friday = 4th thu +1)
      any form may be wrapped: {"years": {"2026": "11-14"}, "default": <spec>}
    """
    if isinstance(spec, dict) and "years" in spec:
        per_year = spec["years"].get(str(year))
        return resolve_date(per_year if per_year is not None else spec["default"], year)

    if isinstance(spec, str):
        mm, dd = spec.split("-")
        return dt.date(year, int(mm), int(dd))

    if "easter" in spec:
        d = easter(year) + dt.timedelta(days=int(spec["easter"]))
    elif "nth" in spec:
        month, wd, nth = int(spec["month"]), WEEKDAYS[str(spec["weekday"])[:3].lower()], int(spec["nth"])
        if nth > 0:
            first = dt.date(year, month, 1)
            d = first + dt.timedelta(days=(wd - first.weekday()) % 7 + 7 * (nth - 1))
        else:
            nxt = dt.date(year + (month == 12), month % 12 + 1, 1)
            last = nxt - dt.timedelta(days=1)
            d = last - dt.timedelta(days=(last.weekday() - wd) % 7)
    else:
        raise ValueError(f"bad date spec {spec!r}")
    return d + dt.timedelta(days=int(spec.get("offset", 0)))


def event_window(ev: dict[str, Any], year: int) -> tuple[dt.date, dt.date, dt.date, dt.date]:
    """Returns (start, prime_first, prime_last, end) for this event in `year`."""
    prime_first = resolve_date(ev["date"], year)
    prime_last = prime_first + dt.timedelta(days=max(1, int(ev.get("prime_days", 1))) - 1)
    start = resolve_date(ev["start"], year) if "start" in ev else prime_first - dt.timedelta(days=int(ev.get("lead_days", 0)))
    end = resolve_date(ev["end"], year) if "end" in ev else prime_last + dt.timedelta(days=int(ev.get("after_days", 0)))
    return start, prime_first, prime_last, end


PRIME_LEVEL = 8
DEMO_LEVEL = 9
LEVELS = {
    0: "off",
    1: "now and then a single decoration",
    2: "mostly one decoration, sometimes two",
    3: "a few decorations, a rare creepy-crawly",
    4: "decorations, some movement",
    5: "busier, crawling spiders",
    6: "busy, bats and ghosts",
    7: "nearly there (the day before)",
    8: "full blown (the day itself)",
    9: "demo: all artwork in a grid",
}


def event_level(ev: dict[str, Any], today: dt.date) -> Optional[int]:
    """
    None when the event is not running. Prime day(s) → PRIME_LEVEL (8).
    The run-up climbs from lead_min to lead_max (levels, default 1..7), non-linear:
    progress ** curve, so the first days stay light and it builds up faster near the prime day.
    After the prime day it fades out the same way.
    """
    # Events can wrap into the next year (e.g. new year), so check last year's occurrence too.
    for year in (today.year, today.year - 1):
        start, p1, p2, end = event_window(ev, year)
        if not (start <= today <= end):
            continue
        if p1 <= today <= p2:
            return PRIME_LEVEL
        lo = float(ev.get("lead_min", 1))
        hi = float(ev.get("lead_max", PRIME_LEVEL - 1))
        curve = float(ev.get("curve", 2.0))
        # progress 0 on the first day of the run-up .. 1 on the day before the prime day
        # (mirrored after it: 1 on the day after .. 0 on the last day)
        if today < p1:
            span = (p1 - start).days - 1
            progress = (today - start).days / span if span > 0 else 1.0
        else:
            span = (end - p2).days - 1
            progress = (end - today).days / span if span > 0 else 1.0
        return max(1, min(PRIME_LEVEL - 1, round(lo + (hi - lo) * max(0.0, min(1.0, progress)) ** curve)))
    return None


def configured_level(cfg: dict[str, Any], calendar_level: int) -> int:
    """themes_level "auto" follows the calendar, capped by themes_max_level; a number fixes it."""
    want = cfg.get("themes_level", "auto")
    if want in (None, "", "auto"):
        cap = int(cfg.get("themes_max_level", PRIME_LEVEL) or PRIME_LEVEL)
        return max(0, min(calendar_level, cap))
    try:
        return max(0, min(DEMO_LEVEL, int(want)))
    except (TypeError, ValueError):
        return calendar_level


def load_events() -> list[dict[str, Any]]:
    try:
        data = json.loads(EVENTS_PATH.read_text(encoding="utf-8"))
        return [e for e in data.get("events", []) if isinstance(e, dict)]
    except Exception:
        return []


def pick_theme(cfg: dict[str, Any], today: dt.date) -> Optional[tuple[str, float]]:
    """(theme_name, level) for today, honouring config switches, or None."""
    force = str(cfg.get("themes_force") or "").strip()
    if force:
        lvl = configured_level(cfg, PRIME_LEVEL)
        return (force, lvl) if lvl > 0 else None

    if not bool(cfg.get("themes_enabled", True)):
        return None
    disabled = {str(t).lower() for t in (cfg.get("themes_disabled_types") or [])}

    best: Optional[tuple[int, int, int, str]] = None
    for ev in load_events():
        if str(ev.get("type", ev.get("id", ""))).lower() in disabled:
            continue
        if not (THEMES_DIR / str(ev.get("theme", ev.get("id"))) / "theme.json").exists():
            continue
        try:
            lvl = event_level(ev, today)
        except Exception:
            continue
        if lvl is None:
            continue
        # Overlaps: a prime day always wins, then higher priority, then higher level.
        key = (int(lvl >= PRIME_LEVEL), int(ev.get("priority", 0)), lvl, str(ev.get("theme", ev.get("id"))))
        if best is None or key > best:
            best = key
    if best is None:
        return None
    lvl = configured_level(cfg, best[2])
    return (best[3], lvl) if lvl > 0 else None


def today_for(cfg: dict[str, Any]) -> dt.date:
    """Today's date, or themes_date_override (YYYY-MM-DD) for previewing."""
    ov = str(cfg.get("themes_date_override") or "").strip()
    if ov:
        try:
            return dt.date.fromisoformat(ov)
        except ValueError:
            pass
    return dt.date.today()


# ─────────────────────────────────────────────────────────────────────────────
# Sprite preparation (PNG → premultiplied BGRA atlas)
# ─────────────────────────────────────────────────────────────────────────────

def _premultiplied_bgra(im: "Image.Image", opacity: float) -> bytes:
    im = im.convert("RGBA")
    r, g, b, a = im.split()
    if opacity < 1.0:
        a = a.point(lambda v: int(v * opacity))
    r, g, b = (ImageChops.multiply(ch, a) for ch in (r, g, b))
    return Image.merge("RGBA", (b, g, r, a)).tobytes()


def _white_with_shadow(im: "Image.Image") -> "Image.Image":
    """TV-channel-logo look: white silhouette with a soft dark shadow so it reads on light and dark."""
    from PIL import ImageFilter  # type: ignore
    a = im.getchannel("A")
    pad = max(2, im.height // 25)
    canvas = Image.new("RGBA", (im.width + 2 * pad, im.height + 2 * pad), (0, 0, 0, 0))
    shadow_a = Image.new("L", canvas.size, 0)
    shadow_a.paste(a, (pad + pad // 3, pad + pad // 3))
    shadow_a = shadow_a.filter(ImageFilter.GaussianBlur(pad / 2)).point(lambda v: int(v * 0.6))
    canvas = Image.merge("RGBA", (Image.new("L", canvas.size, 0),) * 3 + (shadow_a,))
    white = Image.merge("RGBA", (Image.new("L", im.size, 255),) * 3 + (a,))
    canvas.alpha_composite(white, (pad, pad))
    return canvas


def _load_anim(theme_dir: Path, sdef: dict[str, Any], height_px: int,
               screen_h: int) -> tuple[list["Image.Image"], dict[str, Any], list[float] | None]:
    """
    Baked animation folder (tools/bake/*.py): clips.json + <clip>_NNNN.png.
    All frames are cropped to their *union* bounding box (per-frame crops would make the
    animation jitter) and scaled together. Returns frames in clip order + clip table + origin.
    "unit": screen-height fraction per world unit instead of "height": sprites baked apart
    (vampire, coffin) then share one scale, and "origin" (the baked world x = 0 on the ground,
    in sprite pixels) lets the engine line them up.
    """
    d = theme_dir / sdef["anim"]
    info = json.loads((d / "clips.json").read_text(encoding="utf-8"))
    names = list(info["clips"])
    raw: list["Image.Image"] = []
    clips: dict[str, Any] = {}
    for n in names:
        c = info["clips"][n]
        files = sorted(d.glob(c.get("files", f"{n}_*.png")))
        clips[n] = {"start": len(raw), "count": len(files), "fps": float(c.get("fps", 24)),
                    "loop": bool(c.get("loop", True)), "stride": float(c.get("stride", 0))}
        raw.extend(Image.open(f).convert("RGBA") for f in files)

    render_w = raw[0].width
    box = None
    for im in raw:
        b = im.getchannel("A").getbbox()
        if b:
            box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]), max(box[2], b[2]), max(box[3], b[3]))
    box = box or (0, 0, raw[0].width, raw[0].height)
    origin = None
    if sdef.get("unit") and info.get("unit_px"):
        scale = float(sdef["unit"]) * screen_h / info["unit_px"]
        height_px = max(1, round((box[3] - box[1]) * scale))
        ox, oy = info.get("origin_px", [render_w / 2, raw[0].height])
        origin = [(ox - box[0]) * scale, (oy - box[1]) * scale]
    else:
        scale = height_px / (box[3] - box[1])
    w = max(1, round((box[2] - box[0]) * scale))
    frames = [im.crop(box).resize((w, height_px), Image.LANCZOS) for im in raw]
    for c in clips.values():
        # baked stride is a fraction of the full render width → pixels per cycle on screen
        c["stride_px"] = c.pop("stride") * render_w * scale
    return frames, clips, origin


def _sprite_frames(theme_dir: Path, sdef: dict[str, Any], height_px: int) -> list["Image.Image"]:
    files = sdef.get("frames") or [sdef["file"]]
    frames = []
    for f in files:
        im = Image.open(theme_dir / f).convert("RGBA")
        bbox = im.getchannel("A").getbbox()
        if bbox:
            im = im.crop(bbox)
        w = max(1, round(im.width * height_px / im.height))
        im = im.resize((w, height_px), Image.LANCZOS)
        if sdef.get("style") == "white":
            im = _white_with_shadow(im)
        frames.append(im)

    # Cheap motion from a single drawing (image generation is poor at pose variants):
    #   "flap": N  → wing beat, the frame squashed vertically around its centre over N steps
    #   "flicker": N → candle light, brightness wobbling over N steps ("flicker_min": only from that
    #   level on, see build_manifest)
    flap = int(sdef.get("flap", 0))
    if flap > 1 and frames:
        base = frames[0]
        frames = []
        for k in range(flap):
            s = 0.55 + 0.45 * (0.5 + 0.5 * math.cos(2 * math.pi * k / flap))
            h = max(1, round(base.height * s))
            canvas = Image.new("RGBA", base.size, (0, 0, 0, 0))
            canvas.paste(base.resize((base.width, h), Image.LANCZOS), (0, (base.height - h) // 2))
            frames.append(canvas)
    flicker = int(sdef.get("flicker", 0))
    if flicker > 1 and frames:
        base = frames[0]
        frames = []
        for k in range(flicker):
            f = 1.0 + 0.12 * math.sin(2 * math.pi * k / flicker) + 0.05 * math.sin(6 * math.pi * k / flicker)
            rgb = ImageEnhance.Brightness(base.convert("RGB")).enhance(f).convert("RGBA")
            rgb.putalpha(base.getchannel("A"))
            frames.append(rgb)

    #   "sway": N → hanging things swinging gently over N steps; "sway_top" (fraction of the height,
    #   e.g. the twig a bat hangs from) stays put, the rest rotates about the middle of that line
    sway = int(sdef.get("sway", 0))
    if sway > 1 and frames:
        base = frames[0]
        amp = float(sdef.get("sway_deg", 7))
        top = round(base.height * float(sdef.get("sway_top", 0)))
        pad = int(base.height * math.sin(math.radians(amp))) + 2
        fixed = Image.new("RGBA", (base.width + 2 * pad, base.height), (0, 0, 0, 0))
        fixed.paste(base.crop((0, 0, base.width, top)), (pad, 0))
        hanging = Image.new("RGBA", fixed.size, (0, 0, 0, 0))
        hanging.paste(base.crop((0, top, base.width, base.height)), (pad, top))
        frames = []
        for k in range(sway):
            a = amp * math.sin(2 * math.pi * k / sway)
            im = hanging.rotate(a, resample=Image.BICUBIC, center=(fixed.width / 2, top))
            im.alpha_composite(fixed)
            frames.append(im)

    # Optional pre-rendered rotation steps (overlay-add can't rotate): every frame × N angles.
    spin = int(sdef.get("spin", 0))
    if spin > 1:
        rotated = []
        for im in frames:
            side = int((im.width ** 2 + im.height ** 2) ** 0.5) + 2
            for k in range(spin):
                canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
                canvas.paste(im, ((side - im.width) // 2, (side - im.height) // 2))
                rotated.append(canvas.rotate(360.0 * k / spin, resample=Image.BICUBIC))
        frames = rotated
    return frames


def _cells(frames: list["Image.Image"], square: bool = False) -> list["Image.Image"]:
    """All frames share one cell size (largest), centred horizontally, bottom-aligned."""
    cw = max(f.width for f in frames)
    ch = max(f.height for f in frames)
    if square:
        cw = ch = max(cw, ch)
    cells = []
    for f in frames:
        cell = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
        cell.paste(f, ((cw - f.width) // 2, ch - f.height if not square else (ch - f.height) // 2))
        cells.append(cell)
    return cells


# Variants stacked in the atlas. Art faces right; "directions" sprites (seen from below)
# can also walk up/down the screen, so they get rotated copies instead of just a mirror.
VARIANTS_MIRROR = ["normal", "mirror"]
VARIANTS_DIRECTIONS = ["right", "left", "up", "down"]


def _variant(im: "Image.Image", name: str) -> "Image.Image":
    if name in ("normal", "right") or name.startswith("fade"):
        return im
    if name.startswith("size"):  # "size0.7" / "size0.7m": smaller (farther away), centred in the cell
        f = float(name[4:].rstrip("m"))
        small = im.resize((max(1, round(im.width * f)), max(1, round(im.height * f))), Image.LANCZOS)
        if name.endswith("m"):
            small = small.transpose(Image.FLIP_LEFT_RIGHT)
        cell = Image.new("RGBA", im.size, (0, 0, 0, 0))
        cell.paste(small, ((im.width - small.width) // 2, (im.height - small.height) // 2))
        return cell
    if name == "mirror":
        return im.transpose(Image.FLIP_LEFT_RIGHT)
    if name == "left":
        return im.transpose(Image.ROTATE_180)
    if name == "up":
        return im.transpose(Image.ROTATE_90)
    return im.transpose(Image.ROTATE_270)


def build_sprite(theme_dir: Path, name: str, sdef: dict[str, Any], screen_h: int) -> dict[str, Any]:
    """Atlas: for each variant, all frames, stacked → frame k of variant v at offset (v*frames + k)*w*h*4."""
    height_px = max(4, round(float(sdef.get("height", 0.1)) * screen_h))
    opacity = float(sdef.get("opacity", 1.0))

    if "anim" in sdef:
        src_files = sorted((theme_dir / sdef["anim"]).glob("*"))
    else:
        src_files = [theme_dir / f for f in (sdef.get("frames") or [sdef["file"]])]
    h = hashlib.sha1()
    h.update(json.dumps([sdef, screen_h, 2], sort_keys=True).encode())
    for p in src_files:
        h.update(f"{p.name}{p.stat().st_mtime_ns}".encode())
    key = h.hexdigest()[:16]

    out = CACHE_DIR / f"{theme_dir.name}_{name}_{key}.bgra"
    meta_path = out.with_suffix(".json")
    if out.exists() and meta_path.exists():
        return json.loads(meta_path.read_text(encoding="utf-8"))

    clips: dict[str, Any] = {}
    origin = None
    if "anim" in sdef:
        frames, clips, origin = _load_anim(theme_dir, sdef, height_px, screen_h)
    else:
        frames = _sprite_frames(theme_dir, sdef, height_px)
    directions = bool(sdef.get("directions"))
    variants = VARIANTS_DIRECTIONS if directions else VARIANTS_MIRROR
    # "fade": N → N more and more transparent copies after the mirror variant (for fading out:
    # overlay bitmaps have no alpha of their own)
    fades = 0 if directions else int(sdef.get("fade", 0))
    variants = variants + [f"fade{k}" for k in range(1, fades + 1)]
    # "sizes": [0.8, 0.6] → smaller copies (+ mirrored) after that, for depth (flyers far away).
    # "depth": {"min": 0.5, "steps": 10} → a ladder of sizes down to min, for a flyer drifting
    # nearer and farther while it flies (overlay bitmaps can't be scaled when drawn)
    sizes = [] if directions else [float(f) for f in sdef.get("sizes", [])]
    depth = sdef.get("depth")
    if depth and not directions:
        lo, n = float(depth.get("min", 0.5)), max(1, int(depth.get("steps", 10)))
        sizes = [round(1 - (1 - lo) * k / n, 3) for k in range(1, n + 1)]
    variants = variants + [f"size{f}{m}" for f in sizes for m in ("", "m")]
    # "video_opacity": 0.1 → all of that again (without the fades) this transparent, from
    # variant faint_at on: shown while a video plays
    faint = None if directions else sdef.get("video_opacity")
    faint_at = len(variants) if faint is not None else None
    if faint is not None:
        variants = variants + ["faint:" + v for v in variants if not v.startswith("fade")]
    frames = _cells(frames, square=directions)

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".tmp")
    with tmp.open("wb") as fh:
        for v in variants:
            o = opacity * (1 - int(v[4:]) / (fades + 1)) if v.startswith("fade") else opacity
            if v.startswith("faint:"):
                v, o = v[6:], float(faint)
            for f in frames:
                fh.write(_premultiplied_bgra(_variant(f, v), o))
    tmp.replace(out)
    # drop atlases of older versions of this sprite (baked animations are ~100 MB each)
    for old in CACHE_DIR.glob(f"{theme_dir.name}_{name}_*"):
        if old.stem != out.stem:
            old.unlink(missing_ok=True)

    # "solid": things the cat can climb onto: the top edge per column (fraction of the height)
    profile = None
    if sdef.get("solid"):
        a = frames[0].getchannel("A").point(lambda v: 255 if v > 128 else 0)
        n = 32
        profile = []
        for i in range(n):
            x0 = i * a.width // n
            b = a.crop((x0, 0, max(x0 + 1, (i + 1) * a.width // n), a.height)).getbbox()
            profile.append(round(b[1] / a.height, 3) if b else 1.0)

    meta = {
        "file": str(out),
        "w": frames[0].width,
        "h": frames[0].height,
        "frames": len(frames),
        "variants": variants,
        "fps": float(sdef.get("fps", 0)),
        "spin": int(sdef.get("spin", 0)),
        "fades": fades,
        "sizes": sizes,
        "faint_at": faint_at,
        "clips": clips,
        "origin": origin,
        "unit": float(sdef["unit"]) if origin else None,
        "profile": profile,
    }
    meta_path.write_text(json.dumps(meta), encoding="utf-8")
    return meta


def build_manifest(theme: str, level: int, screen_w: int, screen_h: int, text: bool = False) -> Path:
    """Prepare all sprites of a theme and write the manifest the Lua engine loads."""
    theme_dir = THEMES_DIR / theme
    tdef = json.loads((theme_dir / "theme.json").read_text(encoding="utf-8"))
    sprites = {}
    for name, sdef in (tdef.get("sprites") or {}).items():
        if level < int(sdef.get("flicker_min", 0)):
            sdef = {k: v for k, v in sdef.items() if k not in ("flicker", "flicker_min")}
        try:
            sprites[name] = build_sprite(theme_dir, name, sdef, screen_h)
        except Exception as e:
            print(f"[themes] sprite {theme}/{name} failed: {e!r}")
    manifest = {
        "theme": theme,
        "level": int(level),
        "screen": [screen_w, screen_h],
        "sprites": sprites,
        "elements": tdef.get("elements") or [],
        "text": bool(text),
        "jokes": tdef.get("jokes") or [],
        "shouts": tdef.get("shouts") or [],
    }
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    path = CACHE_DIR / f"manifest_{theme}.json"
    path.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    return path


def build_watermark(cfg: dict[str, Any], screen_h: int) -> Optional[dict[str, Any]]:
    img = str(cfg.get("watermark_image") or "").strip()
    if not img:
        return None
    p = Path(img).expanduser()
    if not p.is_absolute():
        p = Path(__file__).resolve().parent / p
    if not p.exists():
        print(f"[themes] watermark image missing: {p}")
        return None
    sdef = {"file": p.name, "height": float(cfg.get("watermark_height", 0.08)),
            "opacity": float(cfg.get("watermark_opacity", 0.6)),
            "style": str(cfg.get("watermark_style", "white")).lower()}
    meta = build_sprite(p.parent, "watermark", sdef, screen_h)
    meta["position"] = str(cfg.get("watermark_position", "top-right")).lower()
    meta["margin"] = float(cfg.get("watermark_margin", 0.025))
    return meta


# ─────────────────────────────────────────────────────────────────────────────
# Room: hand-overs between the engines of neighbouring screens (over roombus)
# ─────────────────────────────────────────────────────────────────────────────

class ThemeRoom:
    """The theme engine's link with the other screens in the room (over roombus).

    Hand-overs: layout = node names left to right as a visitor sees the screens (config
    room.layout), or a list of such rows (screens above each other: no hand-over between rows,
    nothing wraps around); an actor crossing an edge towards a neighbour goes on there, gap_px
    further.
    The engine says theme-room-out {side, ...}; we publish theme/handoff {to: <that neighbour>,
    sent: wall ms}; the neighbour's ThemeRoom gives it to its engine as theme-room-in {late: s}.

    Claims: no two screens show the same thing. The engine says theme-room-claims-out {claims}
    (sprite keys of its decor and unique actors); we announce them (theme/claims, every few
    seconds, with the time each was first shown) and tell the engine theme-room-claims
    {ready, taken}: keys other screens show, including ones we show too but they had first (the
    engine then gives those up).

    Starting takes turns, so screens started together don't pick the same things at once: ready
    (the engine may show things) once we listened LISTEN_S and every live screen before us in the
    room order (layout, then name) is on: it started SETTLE_S ago, so its claims are out. Our
    state goes along with the claims as "_state": wait / start / on.
    """

    ANNOUNCE_S = 2.0
    LISTEN_S = 2.5          # hear the room before deciding anything
    SETTLE_S = 2.0          # after starting: our decor and first actors are claimed by then
    MAX_WAIT_S = 25.0       # a screen before us that never gets going doesn't hold us forever

    def __init__(self, bus: Any, layout: list[str], gap_px: float, send: Callable[..., Any],
                 log: Callable[[str], None] = print):
        import random
        self.bus, self.send, self.log = bus, send, log
        self.gap_px = float(gap_px)
        rows = [[str(n) for n in r] if isinstance(r, list) else [str(r)] for r in layout or []]
        if rows and all(len(r) == 1 for r in rows):
            rows = [[r[0] for r in rows]]                   # a plain list: one row
        self.order = [n for r in rows for n in r]
        row = next((r for r in rows if bus.node in r), [])
        i = row.index(bus.node) if row else -1
        self.left = row[i - 1] if i > 0 else None
        self.right = row[i + 1] if 0 <= i < len(row) - 1 else None
        if i < 0 and rows:
            log(f"room: {bus.node} is not in the layout {rows}; no hand-overs")
        self._lock = threading.Lock()
        self.mine: dict[str, int] = {}                      # key → wall ms first shown
        self.others: dict[str, tuple[float, dict]] = {}     # node → (monotonic heard, {key: ms})
        self.states: dict[str, str] = {}                    # node → its "_state"
        t0 = time.monotonic()
        self._listen_until = t0 + self.LISTEN_S + random.uniform(0, 0.5)
        self._give_up_at = t0 + self.MAX_WAIT_S
        self._started: Optional[float] = None               # monotonic, when we became ready
        self._told: Optional[str] = None
        bus.subscribe("theme/handoff", self._handoff_from_bus)
        bus.subscribe("theme/claims", self._claims_from_bus)
        threading.Thread(target=self._loop, daemon=True, name="themeroom").start()

    @property
    def ready(self) -> bool:
        return self._started is not None

    def state(self) -> str:
        if self._started is None:
            return "wait"
        return "on" if time.monotonic() - self._started >= self.SETTLE_S else "start"

    def _rank(self, node: str) -> tuple[int, str]:
        return (self.order.index(node) if node in self.order else len(self.order), node)

    def _my_turn(self) -> Optional[str]:
        """None when we may start, else the screen we wait for."""
        now = time.monotonic()
        if now < self._listen_until:
            return "listening"
        if now >= self._give_up_at:
            return None
        me = self._rank(self.bus.node)
        alive_s = self.ANNOUNCE_S * 3.5
        with self._lock:
            for node, (heard, _) in sorted(self.others.items()):
                if now - heard <= alive_s and self._rank(node) < me and self.states.get(node, "on") != "on":
                    return node
        return None

    def _step(self) -> None:
        """Start when it's our turn; tell the room when our state changes."""
        before = self.state()
        if self._started is None:
            waiting = self._my_turn()
            if waiting is None:
                self._started = time.monotonic()
                self.log("room: our turn, starting")
        if self.state() != before:
            self._publish_claims()
            self._tell_engine()

    def announce(self) -> None:
        """Tell the engine about the room (after mpv or the engine started)."""
        self._told = None
        self.send("script-message", "theme-room", json.dumps(
            {"active": True, "left": bool(self.left), "right": bool(self.right),
             "gap_px": self.gap_px, "ready": self.ready}))
        self._tell_engine(force=True)

    # ── from the engine ──
    def from_engine(self, name: str, js: str) -> None:
        try:
            v = json.loads(js)
        except ValueError:
            return
        if name == "theme-room-out":
            to = self.right if v.get("side") == "right" else self.left if v.get("side") == "left" else None
            if to:
                v["to"], v["sent"] = to, int(time.time() * 1000)
                self.bus.publish("theme/handoff", v)
        elif name == "theme-room-claims-out":
            keys = v.get("claims") if isinstance(v, dict) else None
            keys = [str(k) for k in keys] if isinstance(keys, list) else []
            now = int(time.time() * 1000)
            with self._lock:
                self.mine = {k: self.mine.get(k, now) for k in keys}
            self._publish_claims()
            self._tell_engine()

    # ── from the room ──
    def _handoff_from_bus(self, topic: str, h: Any, env: dict) -> None:
        if isinstance(h, dict) and h.get("to") == self.bus.node:
            sent = h.pop("sent", None)
            if isinstance(sent, (int, float)):
                h["late"] = max(0.0, min(1.0, (time.time() * 1000 - sent) / 1000.0))
            self.send("script-message", "theme-room-in", json.dumps(h))

    def _claims_from_bus(self, topic: str, p: Any, env: dict) -> None:
        if isinstance(p, dict):
            with self._lock:
                node = str(env.get("n"))
                self.others[node] = (time.monotonic(), {str(k): int(v) for k, v in p.items()
                                                        if isinstance(v, (int, float))})
                if isinstance(p.get("_state"), str):
                    self.states[node] = p["_state"]
            self._step()
            self._tell_engine()

    # ── bookkeeping ──
    def taken(self) -> list[str]:
        """Keys other (live) screens show; for one we show too, the earliest wins (then node name)."""
        now = time.monotonic()
        alive_s = self.ANNOUNCE_S * 3.5
        with self._lock:
            out = set()
            for node, (heard, claims) in self.others.items():
                if now - heard > alive_s:
                    continue                      # gone (switched off, rebooted): its claims too
                for k, ms in claims.items():
                    mine = self.mine.get(k)
                    if mine is None or (ms, node) < (mine, self.bus.node):
                        out.add(k)
        return sorted(out)

    def _publish_claims(self) -> None:
        with self._lock:
            claims: dict[str, Any] = dict(self.mine)
        claims["_state"] = self.state()
        self.bus.publish("theme/claims", claims)

    def _tell_engine(self, force: bool = False) -> None:
        msg = json.dumps({"ready": self.ready, "taken": self.taken()})
        if force or msg != self._told:
            self._told = msg
            self.send("script-message", "theme-room-claims", msg)

    def _loop(self) -> None:
        k = 0
        while True:
            time.sleep(0.25)
            self._step()
            k += 1
            if k % 8 == 0:
                self._publish_claims()        # repeated: lost packets, screens that come later
            if k % 4 == 0:
                self._tell_engine()           # silent screens drop out


# ─────────────────────────────────────────────────────────────────────────────
# Controller used by kioskplayer.App
# ─────────────────────────────────────────────────────────────────────────────

class ThemeController:
    """
    Keeps the Lua engine in sync: active theme + level (re-checked every minute),
    display mode (idle / video / hidden) and the watermark.
    `send` is a callable taking mpv command args (fire-and-forget).
    """

    CHECK_EVERY_S = 60.0

    def __init__(self, send: Callable[..., Any], get_prop: Callable[[str], Any], log: Callable[[str], None]):
        self.send = send
        self.get_prop = get_prop
        self.log = log
        self.cfg: dict[str, Any] = {}
        self._active: Optional[tuple[str, float]] = None
        self._loaded_key: Optional[tuple[Any, ...]] = None
        self._wm_key: Optional[tuple[Any, ...]] = None
        self._overscan: Any = None
        self._next_check = 0.0
        self._mode = "hidden"
        self._busy = threading.Lock()
        self.room: Optional[ThemeRoom] = None

    def message(self, args: list[Any]) -> None:
        """A script-message from the engine (mpv client-message event)."""
        if args and args[0] == "theme-resized":
            self._next_check = 0.0          # new screen size: sprites for it on the next tick
            return
        if len(args) >= 2 and str(args[0]).startswith("theme-room-") and self.room:
            self.room.from_engine(str(args[0]), str(args[1]))

    def configure(self, cfg: dict[str, Any]) -> None:
        self.cfg = cfg
        self._next_check = 0.0  # re-evaluate on next tick

    def reset(self) -> None:
        """mpv (re)started: the engine knows nothing yet, so resend everything."""
        self._loaded_key = None
        self._wm_key = None
        self._overscan = None
        self._next_check = 0.0
        mode, self._mode = self._mode, ""
        self.set_mode(mode)

    def set_mode(self, mode: str) -> None:
        if mode == self._mode:
            return
        self._mode = mode
        self.send("script-message", "theme-mode", mode)

    def tick(self, now: float) -> None:
        if now < self._next_check:
            return
        self._next_check = now + self.CHECK_EVERY_S
        if Image is None:
            self.log("themes: PIL not available; themes and watermark disabled")
            self._next_check = now + 3600
            return
        # Sprite preparation can take a few seconds on a Pi: keep it off the main loop.
        if self._busy.acquire(blocking=False):
            threading.Thread(target=self._refresh, daemon=True).start()

    def _screen(self) -> tuple[int, int]:
        try:
            w = int(self.get_prop("osd-width") or 0)
            h = int(self.get_prop("osd-height") or 0)
            return w, h
        except Exception:
            return 0, 0

    def _refresh(self) -> None:
        try:
            w, h = self._screen()
            if w <= 0 or h <= 0:
                self._next_check = 0.0
                return

            # Watermark
            wm_on = bool(self.cfg.get("watermark_enabled", True))
            wm_key = (wm_on, w, h) + tuple(str(self.cfg.get(k)) for k in (
                "watermark_image", "watermark_height", "watermark_opacity", "watermark_style",
                "watermark_position", "watermark_margin"))
            if wm_key != self._wm_key:
                self._wm_key = wm_key
                meta = build_watermark(self.cfg, h) if wm_on else None
                self.send("script-message", "watermark", json.dumps(meta) if meta else "")
                self.log(f"themes: watermark {'on' if meta else 'off'}")

            # TV overscan: the engine keeps everything inside what the screen really shows
            ov = self.cfg.get("screen_overscan") or 0
            if ov != self._overscan:
                self._overscan = ov
                self.send("script-message", "theme-overscan", json.dumps(ov))

            # Theme
            pick = pick_theme(self.cfg, today_for(self.cfg))
            text = bool(self.cfg.get("themes_text", False))
            key = (pick[0], pick[1], w, h, text) if pick else None
            if key == self._loaded_key:
                return
            self._loaded_key = key
            if pick is None:
                self.send("script-message", "theme-off")
                self.log("themes: no active theme")
                return
            theme, level = pick
            manifest = build_manifest(theme, level, w, h, text)
            if self.room:
                self.room.announce()
            self.send("script-message", "theme-load", str(manifest))
            self.log(f"themes: loaded {theme} level={level}")
        except Exception as e:
            self.log(f"themes: refresh failed: {e!r}")
        finally:
            self._busy.release()


if __name__ == "__main__":
    # Quick calendar preview: python3 themes.py [YYYY-MM-DD] [days]
    import sys
    start = dt.date.fromisoformat(sys.argv[1]) if len(sys.argv) > 1 else dt.date.today()
    days = int(sys.argv[2]) if len(sys.argv) > 2 else 21
    for n in range(days):
        d = start + dt.timedelta(days=n)
        p = pick_theme({}, d)
        print(d.isoformat(), d.strftime("%a"), f"{p[0]:<12} {p[1]} " + "#" * (p[1] * 4) if p else "-")
