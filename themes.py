#!/usr/bin/env python3
# themes.py — seasonal theme calendar + sprite preparation for the mpv theme engine (themes/engine.lua)
#
# Python decides *which* theme is active and *how strong* (intensity 0..1, 1.0 = prime day).
# The Lua script inside mpv does all drawing/animation; we only send it script-messages.
#
#   themes/events.json        calendar: when each event runs, its prime day(s), lead-in ramp
#   themes/<theme>/theme.json sprites + elements (what to draw, from which intensity on)
#   themes/<theme>/*.png      artwork (transparent PNG)
#
# Sprites are converted once to premultiplied BGRA atlases (what mpv overlay-add wants),
# scaled for the current screen height, and cached under ~/.cache/kioskplayer/sprites.

from __future__ import annotations

import datetime as dt
import hashlib
import json
import threading
from pathlib import Path
from typing import Any, Callable, Optional

try:
    from PIL import Image, ImageChops  # type: ignore
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


def event_intensity(ev: dict[str, Any], today: dt.date) -> Optional[float]:
    """
    None when the event is not running. Prime day(s) → 1.0.
    Lead-in ramps from lead_min to lead_max, non-linear: (progress ** curve), so the first days stay
    light and it builds up faster near the prime day. After the prime day it fades out the same way.
    """
    # Events can wrap into the next year (e.g. new year), so check last year's occurrence too.
    for year in (today.year, today.year - 1):
        start, p1, p2, end = event_window(ev, year)
        if not (start <= today <= end):
            continue
        if p1 <= today <= p2:
            return 1.0
        lo = float(ev.get("lead_min", 0.1))
        hi = float(ev.get("lead_max", 0.7))
        curve = float(ev.get("curve", 2.0))
        if today < p1:
            span = (p1 - start).days
            progress = 1.0 - (p1 - today).days / span if span > 0 else 1.0
        else:
            span = (end - p2).days
            progress = 1.0 - (today - p2).days / span if span > 0 else 1.0
        return lo + (hi - lo) * max(0.0, min(1.0, progress)) ** curve
    return None


def load_events() -> list[dict[str, Any]]:
    try:
        data = json.loads(EVENTS_PATH.read_text(encoding="utf-8"))
        return [e for e in data.get("events", []) if isinstance(e, dict)]
    except Exception:
        return []


def pick_theme(cfg: dict[str, Any], today: dt.date) -> Optional[tuple[str, float]]:
    """(theme_name, intensity) for today, honouring config switches, or None."""
    force = str(cfg.get("themes_force") or "").strip()
    if force:
        fi = cfg.get("themes_force_intensity")
        return force, float(fi) if fi is not None else 1.0

    if not bool(cfg.get("themes_enabled", True)):
        return None
    disabled = {str(t).lower() for t in (cfg.get("themes_disabled_types") or [])}

    best: Optional[tuple[int, float, str]] = None
    for ev in load_events():
        if str(ev.get("type", ev.get("id", ""))).lower() in disabled:
            continue
        if not (THEMES_DIR / str(ev.get("theme", ev.get("id"))) / "theme.json").exists():
            continue
        try:
            inten = event_intensity(ev, today)
        except Exception:
            continue
        if inten is None:
            continue
        # Overlaps: a prime day always wins, then higher priority, then higher intensity.
        key = (int(inten >= 1.0), int(ev.get("priority", 0)), inten, str(ev.get("theme", ev.get("id"))))
        if best is None or key > best:
            best = key
    if best is None:
        return None
    return best[3], best[2]


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

    # All frames share one cell size (largest), centred horizontally, bottom-aligned.
    cw = max(f.width for f in frames)
    ch = max(f.height for f in frames)
    cells = []
    for f in frames:
        cell = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
        cell.paste(f, ((cw - f.width) // 2, ch - f.height))
        cells.append(cell)
    return cells


def build_sprite(theme_dir: Path, name: str, sdef: dict[str, Any], screen_h: int) -> dict[str, Any]:
    """Atlas layout: [frames..., mirrored frames...] stacked vertically → frame k at offset k*w*h*4."""
    height_px = max(4, round(float(sdef.get("height", 0.1)) * screen_h))
    opacity = float(sdef.get("opacity", 1.0))

    src_files = sdef.get("frames") or [sdef["file"]]
    h = hashlib.sha1()
    h.update(json.dumps([sdef, screen_h], sort_keys=True).encode())
    for f in src_files:
        p = theme_dir / f
        h.update(str(p.stat().st_mtime_ns).encode())
    key = h.hexdigest()[:16]

    out = CACHE_DIR / f"{theme_dir.name}_{name}_{key}.bgra"
    meta_path = out.with_suffix(".json")
    if out.exists() and meta_path.exists():
        return json.loads(meta_path.read_text(encoding="utf-8"))

    frames = _sprite_frames(theme_dir, sdef, height_px)
    mirrored = [f.transpose(Image.FLIP_LEFT_RIGHT) for f in frames]
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".tmp")
    with tmp.open("wb") as fh:
        for f in frames + mirrored:
            fh.write(_premultiplied_bgra(f, opacity))
    tmp.replace(out)

    meta = {
        "file": str(out),
        "w": frames[0].width,
        "h": frames[0].height,
        "frames": len(frames),
        "fps": float(sdef.get("fps", 0)),
        "spin": int(sdef.get("spin", 0)),
    }
    meta_path.write_text(json.dumps(meta), encoding="utf-8")
    return meta


def build_manifest(theme: str, intensity: float, screen_w: int, screen_h: int) -> Path:
    """Prepare all sprites of a theme and write the manifest the Lua engine loads."""
    theme_dir = THEMES_DIR / theme
    tdef = json.loads((theme_dir / "theme.json").read_text(encoding="utf-8"))
    sprites = {}
    for name, sdef in (tdef.get("sprites") or {}).items():
        try:
            sprites[name] = build_sprite(theme_dir, name, sdef, screen_h)
        except Exception as e:
            print(f"[themes] sprite {theme}/{name} failed: {e!r}")
    manifest = {
        "theme": theme,
        "intensity": round(float(intensity), 3),
        "screen": [screen_w, screen_h],
        "sprites": sprites,
        "elements": tdef.get("elements") or [],
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
# Controller used by kioskplayer.App
# ─────────────────────────────────────────────────────────────────────────────

class ThemeController:
    """
    Keeps the Lua engine in sync: active theme + intensity (re-checked every minute),
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
        self._next_check = 0.0
        self._mode = "hidden"
        self._busy = threading.Lock()

    def configure(self, cfg: dict[str, Any]) -> None:
        self.cfg = cfg
        self._next_check = 0.0  # re-evaluate on next tick

    def reset(self) -> None:
        """mpv (re)started: the engine knows nothing yet, so resend everything."""
        self._loaded_key = None
        self._wm_key = None
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

            # Theme
            pick = pick_theme(self.cfg, today_for(self.cfg))
            key = (pick[0], round(pick[1], 2), w, h) if pick else None
            if key == self._loaded_key:
                return
            self._loaded_key = key
            if pick is None:
                self.send("script-message", "theme-off")
                self.log("themes: no active theme")
                return
            theme, inten = pick
            manifest = build_manifest(theme, inten, w, h)
            self.send("script-message", "theme-load", str(manifest))
            self.log(f"themes: loaded {theme} intensity={inten:.2f}")
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
        print(d.isoformat(), d.strftime("%a"), f"{p[0]:<12} {p[1]:.2f} " + "#" * round(p[1] * 30) if p else "-")
