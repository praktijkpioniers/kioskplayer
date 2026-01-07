#!/usr/bin/env python3
"""
web_control.py — standalone web UI for museum_player

Responsibilities:
- Read / edit config.json
- Mirror menu options in a web form
- Send CONFIG_CHANGED hint to the running app
- Provide SHORT / LONG button emulation
- Provide SUBTITLE button emulation
- Toggle default subtitle mode (off/on) in config
- Scan video_dir and allow selecting active_video
- NEW:
  - Color preset dropdown (names only)
  - File management page (basic auth protected):
      - upload videos/subtitles/images -> auto place in correct directory
      - list + delete files
"""

from __future__ import annotations

import base64
import cgi
import hashlib
import html
import json
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

# ─────────────────────────────────────────────
# Paths / constants
# ─────────────────────────────────────────────

CONFIG_PATH = Path(__file__).resolve().with_name("config.json")

DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8080

# How we notify the main app.
# This is intentionally stupid and robust.
CONTROL_UDP_ADDR = ("127.0.0.1", 9999)
CONTROL_MAGIC = b"CONFIG_CHANGED\n"

VIDEO_EXTS = {".mp4", ".mkv", ".mov", ".avi", ".webm", ".m4v"}
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp"}
SUB_EXTS = {".srt", ".vtt", ".ass", ".ssa"}

# Names only (UI), keep actual numeric mapping elsewhere in your app.
COLOR_PRESET_NAMES = [
    "NEUTRAL",
    "VIVID",
    "PUNCHY",
    "CRAZY",
    "BLACK&WHITE",
    "B&W FLAT",
    "B&W CINEMA",
    "SEPIA",
    "SEPIA SUBTLE",
]

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

def load_config() -> dict:
    if CONFIG_PATH.exists():
        try:
            data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
        except Exception:
            pass
    return {}

def save_config(cfg: dict) -> None:
    tmp = CONFIG_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(CONFIG_PATH)

def notify_config_changed() -> None:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.sendto(CONTROL_MAGIC, CONTROL_UDP_ADDR)
        s.close()
    except Exception:
        pass

def send_button(kind: str) -> None:
    """
    Send one-line UDP command to kioskplayer.
    Existing: "short", "long"
    NEW:      "sub"
    """
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.sendto(kind.encode("ascii") + b"\n", CONTROL_UDP_ADDR)
        s.close()
    except Exception:
        pass

def scan_videos(cfg: dict) -> list[Path]:
    video_dir = cfg.get("video_dir")
    if not video_dir:
        return []
    d = Path(str(video_dir)).expanduser()
    if not d.exists() or not d.is_dir():
        return []
    try:
        vids = [p for p in d.iterdir() if p.is_file() and p.suffix.lower() in VIDEO_EXTS]
        return sorted(vids)
    except Exception:
        return []

def _safe_basename(name: str) -> str:
    # Strip any path components and weird null bytes.
    name = (name or "").replace("\x00", "")
    name = os.path.basename(name)
    return name.strip()

def _pick_dest_dir(cfg: dict, suffix: str) -> Path | None:
    suffix = (suffix or "").lower()

    video_dir = cfg.get("video_dir")
    image_dir = cfg.get("image_dir")

    if suffix in VIDEO_EXTS:
        if not video_dir:
            return None
        return Path(str(video_dir)).expanduser()

    if suffix in IMAGE_EXTS:
        if not image_dir:
            return None
        return Path(str(image_dir)).expanduser()

    if suffix in SUB_EXTS:
        # Prefer explicit subtitle_dir if you add it later; fallback to video_dir.
        subtitle_dir = cfg.get("subtitle_dir") or cfg.get("video_dir")
        if not subtitle_dir:
            return None
        return Path(str(subtitle_dir)).expanduser()

    return None

def _ensure_dir(d: Path) -> bool:
    try:
        d.mkdir(parents=True, exist_ok=True)
        return d.exists() and d.is_dir()
    except Exception:
        return False

def _unique_path(dest_dir: Path, filename: str) -> Path:
    """
    If filename exists, append _1, _2, ...
    """
    p = dest_dir / filename
    if not p.exists():
        return p
    stem = p.stem
    suf = p.suffix
    for i in range(1, 10_000):
        cand = dest_dir / f"{stem}_{i}{suf}"
        if not cand.exists():
            return cand
    # Worst case: include hash
    h = hashlib.sha256(filename.encode("utf-8", "ignore")).hexdigest()[:8]
    return dest_dir / f"{stem}_{h}{suf}"

def _iter_dir_files(d: Path, exts: set[str]) -> list[Path]:
    if not d.exists() or not d.is_dir():
        return []
    try:
        out = [p for p in d.iterdir() if p.is_file() and p.suffix.lower() in exts]
        return sorted(out, key=lambda p: p.name.lower())
    except Exception:
        return []

def _basic_auth_expected(cfg: dict) -> tuple[str, str]:
    # Default credentials (change in config.json!)
    user = str(cfg.get("webui_user", "admin"))
    pw = str(cfg.get("webui_pass", "museum"))
    return (user, pw)

def _parse_basic_auth(header_value: str | None) -> tuple[str, str] | None:
    if not header_value:
        return None
    hv = header_value.strip()
    if not hv.lower().startswith("basic "):
        return None
    b64 = hv.split(None, 1)[1].strip()
    try:
        raw = base64.b64decode(b64).decode("utf-8", "replace")
    except Exception:
        return None
    if ":" not in raw:
        return None
    user, pw = raw.split(":", 1)
    return (user, pw)

# ─────────────────────────────────────────────
# HTML
# ─────────────────────────────────────────────

def render_page(cfg: dict, msg: str = "") -> str:
    def sel(name, val):
        return "selected" if str(cfg.get(name, "")) == str(val) else ""

    def esc(s) -> str:
        return html.escape(str(s), quote=True)

    vids = scan_videos(cfg)
    active_video = 0
    try:
        active_video = int(cfg.get("active_video", 0) or 0)
    except Exception:
        active_video = 0

    subtitle_default_on = bool(cfg.get("subtitle_default_on", False))

    if vids:
        if active_video < 0:
            active_video = 0
        if active_video >= len(vids):
            active_video = 0

    video_opts = []
    if vids:
        for i, p in enumerate(vids):
            s = "selected" if i == active_video else ""
            video_opts.append(f'<option value="{i}" {s}>{i+1}: {esc(p.name)}</option>')
        video_opts_html = "\n".join(video_opts)
    else:
        video_opts_html = '<option value="0">(no videos found)</option>'

    # Color preset dropdown (names only)
    cur_preset = str(cfg.get("color_preset", "") or "")
    preset_opts = []
    all_presets = list(COLOR_PRESET_NAMES)
    if cur_preset and cur_preset not in all_presets:
        all_presets = [cur_preset] + all_presets

    for name in all_presets:
        s = "selected" if name == cur_preset else ""
        preset_opts.append(f'<option value="{esc(name)}" {s}>{esc(name)}</option>')
    preset_opts_html = "\n".join(preset_opts) if preset_opts else '<option value="">(none)</option>'

    # New fields
    expo_mode = bool(cfg.get("expo_mode", False))
    play_mode = str(cfg.get("play_mode", "VIDEO") or "VIDEO").upper()
    slideshow_interval_s = cfg.get("slideshow_interval_s", 10.0)

    screensaver_window_enable = bool(cfg.get("screensaver_window_enable", True))
    screensaver_start_hhmm = str(cfg.get("screensaver_start_hhmm", "17:00") or "17:00")
    screensaver_end_hhmm = str(cfg.get("screensaver_end_hhmm", "09:00") or "09:00")

    return f"""<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Museum Control</title>
<style>
body {{ font-family: sans-serif; margin: 16px; }}
h1 {{ font-size: 20px; }}
button {{ padding: 12px; font-size: 16px; margin: 4px 0; width: 100%; }}
select, input {{ width: 100%; padding: 6px; font-size: 14px; }}
fieldset {{ margin: 12px 0; }}
.ok {{ color: #060; }}
.small {{ font-size: 12px; opacity: 0.8; }}
a.buttonlink {{
  display: block; text-decoration: none; text-align: center;
  padding: 12px; margin: 8px 0; border: 1px solid #ccc; border-radius: 6px;
  color: inherit;
}}
</style>
</head>
<body>

<h1>Museum Control</h1>
<div class="ok">{esc(msg)}</div>

<form method="POST" action="/btn/short">
  <button type="submit">Short press</button>
</form>

<form method="POST" action="/btn/long">
  <button type="submit">Long press</button>
</form>

<form method="POST" action="/btn/sub">
  <button type="submit">Subtitle button</button>
</form>

<a class="buttonlink" href="/files">File management</a>

<form method="POST" action="/">

<fieldset>
<legend>Paths</legend>
<label>Video directory</label>
<input name="video_dir" value="{esc(cfg.get("video_dir",""))}">
<label>Image directory</label>
<input name="image_dir" value="{esc(cfg.get("image_dir",""))}">
<label>Subtitle directory (optional; defaults to video_dir)</label>
<input name="subtitle_dir" value="{esc(cfg.get("subtitle_dir",""))}">
</fieldset>

<fieldset>
<legend>Video selection</legend>
<div class="small">Scanned from: {esc(cfg.get("video_dir","(unset)"))}</div>
<label>Active video</label>
<select name="active_video">
{video_opts_html}
</select>
</fieldset>

<fieldset>
<legend>Subtitles</legend>
<label>Default subtitles</label>
<select name="subtitle_default_on">
  <option value="0" {"selected" if not subtitle_default_on else ""}>OFF</option>
  <option value="1" {"selected" if subtitle_default_on else ""}>ON</option>
</select>
</fieldset>

<fieldset>
<legend>Playback</legend>

<label>Play mode</label>
<select name="play_mode">
  <option value="VIDEO" {"selected" if play_mode == "VIDEO" else ""}>VIDEO</option>
  <option value="SLIDESHOW" {"selected" if play_mode == "SLIDESHOW" else ""}>SLIDESHOW (image gallery)</option>
</select>

<label>Expo mode (auto-start after idle timeout)</label>
<select name="expo_mode">
  <option value="0" {"selected" if not expo_mode else ""}>OFF</option>
  <option value="1" {"selected" if expo_mode else ""}>ON</option>
</select>

<label>Slideshow interval (seconds)</label>
<input name="slideshow_interval_s" value="{esc(slideshow_interval_s)}">

<label>Loop mode</label>
<select name="loop_mode">
  <option {sel("loop_mode","OFF")}>OFF</option>
  <option {sel("loop_mode","SINGLE")}>SINGLE</option>
  <option {sel("loop_mode","ALL")}>ALL</option>
  <option {sel("loop_mode","RANDOM")}>RANDOM</option>
</select>
</fieldset>

<fieldset>
<legend>Timing</legend>
<label>Idle timeout (s)</label>
<input name="idle_timeout_s" value="{esc(cfg.get("idle_timeout_s", ""))}">
<label>Powersave after (s)</label>
<input name="powersave_after_s" value="{esc(cfg.get("powersave_after_s", ""))}">
</fieldset>

<fieldset>
<legend>Screensaver schedule</legend>
<div class="small">Controls when the *idle blanking/sleep* is allowed. Window may cross midnight (e.g., 17:00 → 09:00).</div>

<label>Enable schedule gating</label>
<select name="screensaver_window_enable">
  <option value="0" {"selected" if not screensaver_window_enable else ""}>OFF (always allow)</option>
  <option value="1" {"selected" if screensaver_window_enable else ""}>ON (use window)</option>
</select>

<label>Start (HH:MM)</label>
<input name="screensaver_start_hhmm" value="{esc(screensaver_start_hhmm)}">

<label>End (HH:MM)</label>
<input name="screensaver_end_hhmm" value="{esc(screensaver_end_hhmm)}">
</fieldset>

<fieldset>
<legend>Display</legend>
<label>Blank mode</label>
<select name="blank_mode">
  <option {sel("blank_mode","NONE")}>NONE</option>
  <option {sel("blank_mode","BLACK")}>BLACK</option>
  <option {sel("blank_mode","XSET")}>XSET</option>
  <option {sel("blank_mode","VCGENCMD")}>VCGENCMD</option>
</select>

<label>Color preset</label>
<select name="color_preset">
{preset_opts_html}
</select>
</fieldset>

<fieldset>
<legend>UI</legend>
<label>Background image</label>
<input name="ui_background_image" value="{esc(cfg.get("ui_background_image",""))}">
</fieldset>

<button type="submit">Save config</button>
</form>

</body>
</html>
"""

def render_files_page(cfg: dict, msg: str = "") -> str:
    def esc(s) -> str:
        return html.escape(str(s), quote=True)

    video_dir = Path(str(cfg.get("video_dir", ""))).expanduser()
    image_dir = Path(str(cfg.get("image_dir", ""))).expanduser()
    subtitle_dir = Path(str((cfg.get("subtitle_dir") or cfg.get("video_dir") or ""))).expanduser()

    vids = _iter_dir_files(video_dir, VIDEO_EXTS) if str(video_dir) else []
    subs = _iter_dir_files(subtitle_dir, SUB_EXTS) if str(subtitle_dir) else []
    imgs = _iter_dir_files(image_dir, IMAGE_EXTS) if str(image_dir) else []

    def list_block(title: str, items: list[Path], kind: str, dir_label: str) -> str:
        rows = []
        if not items:
            rows.append("<div class='small'>(none)</div>")
        else:
            for p in items:
                rows.append(
                    f"""
                    <div class="row">
                      <div class="name">{esc(p.name)}</div>
                      <form method="POST" action="/files/delete" class="del">
                        <input type="hidden" name="kind" value="{esc(kind)}">
                        <input type="hidden" name="name" value="{esc(p.name)}">
                        <button type="submit" onclick="return confirm('Delete this file? This cannot be undone.')">Delete</button>
                      </form>
                    </div>
                    """
                )
        rows_html = "\n".join(rows)
        return f"""
        <fieldset>
          <legend>{esc(title)}</legend>
          <div class="small">{esc(dir_label)}</div>
          {rows_html}
        </fieldset>
        """

    return f"""<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>File management</title>
<style>
body {{ font-family: sans-serif; margin: 16px; }}
h1 {{ font-size: 20px; }}
a {{ color: inherit; }}
.small {{ font-size: 12px; opacity: 0.8; }}
.ok {{ color: #060; }}
fieldset {{ margin: 12px 0; }}
button {{ padding: 10px; font-size: 14px; }}
.row {{
  display: flex; gap: 8px; align-items: center;
  border-top: 1px solid #eee; padding: 8px 0;
}}
.name {{ flex: 1; overflow: hidden; text-overflow: ellipsis; }}
.del {{ margin: 0; }}
input[type=file] {{ width: 100%; }}
</style>
</head>
<body>

<h1>File management</h1>
<div class="ok">{esc(msg)}</div>

<div style="margin: 8px 0;">
  <a href="/">← Back</a>
</div>

<fieldset>
  <legend>Upload</legend>
  <div class="small">
    Videos → {esc(video_dir) if str(video_dir) else "(video_dir unset)"}<br>
    Subtitles → {esc(subtitle_dir) if str(subtitle_dir) else "(subtitle_dir/video_dir unset)"}<br>
    Images → {esc(image_dir) if str(image_dir) else "(image_dir unset)"}
  </div>
  <form method="POST" action="/files/upload" enctype="multipart/form-data">
    <input type="file" name="file" required>
    <button type="submit">Upload</button>
  </form>
</fieldset>

{list_block("Videos", vids, "video", f"Directory: {video_dir}" if str(video_dir) else "Directory: (unset)")}
{list_block("Subtitles", subs, "subtitle", f"Directory: {subtitle_dir}" if str(subtitle_dir) else "Directory: (unset)")}
{list_block("Images", imgs, "image", f"Directory: {image_dir}" if str(image_dir) else "Directory: (unset)")}

</body>
</html>
"""


# ─────────────────────────────────────────────
# HTTP handler
# ─────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: str, content_type: str = "text/html; charset=utf-8") -> None:
        data = body.encode("utf-8", "replace")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _redirect(self, location: str) -> None:
        self.send_response(303)
        self.send_header("Location", location)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def _require_files_auth(self, cfg: dict) -> bool:
        """
        Returns True if authorized, otherwise sends 401 and returns False.
        Only used for /files routes.
        """
        expected_user, expected_pass = _basic_auth_expected(cfg)
        got = _parse_basic_auth(self.headers.get("Authorization"))
        if got and got[0] == expected_user and got[1] == expected_pass:
            return True

        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="File management"')
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b"Authentication required.\n")
        return False

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        cfg = load_config()

        if path == "/":
            self._send(200, render_page(cfg))
            return

        if path == "/files":
            if not self._require_files_auth(cfg):
                return
            self._send(200, render_files_page(cfg))
            return

        self._send(404, "Not found", content_type="text/plain; charset=utf-8")

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        cfg = load_config()

        # ── button emulation (separate endpoints) ──────────────────────────────
        if path in ("/btn/short", "/btn/long", "/btn/sub"):
            # Consume body if present (clients may send it)
            length = int(self.headers.get("Content-Length", "0"))
            if length:
                _ = self.rfile.read(length)

            if path == "/btn/short":
                send_button("short")
                self._send(200, render_page(cfg, "Short press sent"))
                return
            if path == "/btn/long":
                send_button("long")
                self._send(200, render_page(cfg, "Long press sent"))
                return
            if path == "/btn/sub":
                send_button("sub")
                self._send(200, render_page(cfg, "Subtitle button sent"))
                return

        # ── file management endpoints (auth protected) ─────────────────────────
        if path.startswith("/files"):
            if not self._require_files_auth(cfg):
                return

            if path == "/files/upload":
                ctype = self.headers.get("Content-Type", "")
                if "multipart/form-data" not in ctype.lower():
                    self._send(400, render_files_page(cfg, "Upload failed: expected multipart/form-data"))
                    return

                form = cgi.FieldStorage(
                    fp=self.rfile,
                    headers=self.headers,
                    environ={
                        "REQUEST_METHOD": "POST",
                        "CONTENT_TYPE": self.headers.get("Content-Type"),
                    },
                )

                if "file" not in form:
                    self._send(400, render_files_page(cfg, "Upload failed: no file field"))
                    return

                field = form["file"]
                if isinstance(field, list):
                    field = field[0]

                filename = _safe_basename(getattr(field, "filename", "") or "")
                if not filename:
                    self._send(400, render_files_page(cfg, "Upload failed: empty filename"))
                    return

                suf = Path(filename).suffix.lower()
                dest_dir = _pick_dest_dir(cfg, suf)
                if dest_dir is None:
                    self._send(400, render_files_page(cfg, f"Upload failed: unsupported extension '{html.escape(suf)}'"))
                    return
                if not _ensure_dir(dest_dir):
                    self._send(500, render_files_page(cfg, f"Upload failed: cannot access/create dir {dest_dir}"))
                    return

                dest_path = _unique_path(dest_dir, filename)

                try:
                    # Stream copy
                    with open(dest_path, "wb") as f:
                        while True:
                            chunk = field.file.read(1024 * 1024)
                            if not chunk:
                                break
                            f.write(chunk)
                except Exception as e:
                    try:
                        if dest_path.exists():
                            dest_path.unlink()
                    except Exception:
                        pass
                    self._send(500, render_files_page(cfg, f"Upload failed: {html.escape(str(e))}"))
                    return

                self._send(200, render_files_page(cfg, f"Uploaded: {dest_path.name}"))
                return

            if path == "/files/delete":
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length).decode("utf-8", "replace") if length else ""
                data = parse_qs(raw)

                kind = (data.get("kind", [""])[0] or "").strip().lower()
                name = _safe_basename(data.get("name", [""])[0] or "")
                if not kind or not name:
                    self._send(400, render_files_page(cfg, "Delete failed: missing parameters"))
                    return

                # Decide directory by kind (still enforce extension set below).
                if kind == "video":
                    d = Path(str(cfg.get("video_dir", ""))).expanduser()
                    allowed_exts = VIDEO_EXTS
                elif kind == "image":
                    d = Path(str(cfg.get("image_dir", ""))).expanduser()
                    allowed_exts = IMAGE_EXTS
                elif kind == "subtitle":
                    d = Path(str((cfg.get("subtitle_dir") or cfg.get("video_dir") or ""))).expanduser()
                    allowed_exts = SUB_EXTS
                else:
                    self._send(400, render_files_page(cfg, "Delete failed: unknown kind"))
                    return

                if not str(d):
                    self._send(400, render_files_page(cfg, "Delete failed: target directory unset"))
                    return

                target = d / name
                if target.suffix.lower() not in allowed_exts:
                    self._send(400, render_files_page(cfg, "Delete failed: extension not allowed"))
                    return

                try:
                    # Ensure we don't delete outside target dir via weird paths (basename already helps)
                    if not target.exists() or not target.is_file():
                        self._send(404, render_files_page(cfg, "Delete failed: file not found"))
                        return
                    target.unlink()
                except Exception as e:
                    self._send(500, render_files_page(cfg, f"Delete failed: {html.escape(str(e))}"))
                    return

                self._send(200, render_files_page(cfg, f"Deleted: {name}"))
                return

            # Unknown /files POST
            self._send(404, "Not found", content_type="text/plain; charset=utf-8")
            return

        # ── config updates (default POST target, e.g. "/") ─────────────────────
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        data = parse_qs(raw)

        def get(name, cast=str):
            if name in data:
                try:
                    return cast(data[name][0])
                except Exception:
                    pass
            return cfg.get(name)

        # paths
        cfg["video_dir"] = get("video_dir")
        cfg["image_dir"] = get("image_dir")
        subdir = (data.get("subtitle_dir", [""])[0] or "").strip()
        if subdir:
            cfg["subtitle_dir"] = subdir
        else:
            # if user cleared it, remove key to fall back to video_dir behavior
            if "subtitle_dir" in cfg:
                del cfg["subtitle_dir"]

        # playback flags
        cfg["play_mode"] = str(get("play_mode") or "VIDEO").upper()

        expo_raw = str(get("expo_mode", str) or "0").strip()
        cfg["expo_mode"] = (expo_raw == "1")

        cfg["slideshow_interval_s"] = get("slideshow_interval_s", float)

        # schedule gating
        win_raw = str(get("screensaver_window_enable", str) or "1").strip()
        cfg["screensaver_window_enable"] = (win_raw == "1")
        cfg["screensaver_start_hhmm"] = str(get("screensaver_start_hhmm") or "17:00").strip()
        cfg["screensaver_end_hhmm"] = str(get("screensaver_end_hhmm") or "09:00").strip()

        # existing fields
        cfg["loop_mode"] = get("loop_mode")
        cfg["idle_timeout_s"] = get("idle_timeout_s", float)
        cfg["powersave_after_s"] = get("powersave_after_s", float)
        cfg["blank_mode"] = get("blank_mode")
        cfg["color_preset"] = get("color_preset")
        cfg["ui_background_image"] = get("ui_background_image")

        # active video from scanned list
        cfg["active_video"] = get("active_video", int)

        # default subtitle mode (0/1)
        subdef = str(get("subtitle_default_on", str)).strip()
        cfg["subtitle_default_on"] = (subdef == "1")

        save_config(cfg)
        notify_config_changed()

        self._send(200, render_page(cfg, "Config saved & applied"))


    def log_message(self, fmt: str, *args) -> None:
        return


# ─────────────────────────────────────────────
# Server
# ─────────────────────────────────────────────

def _parse_hostport(s: str, default_port: int) -> tuple[str, int]:
    s = (s or "").strip()
    if not s:
        return ("127.0.0.1", default_port)

    if ":" in s:
        host, port_s = s.rsplit(":", 1)
        host = host.strip() or "127.0.0.1"
        try:
            port = int(port_s.strip())
        except Exception:
            port = default_port
        return (host, port)

    return (s, default_port)


def main() -> None:
    import sys

    # argv[1] optionally sets where we send UDP control packets (short/long/sub/config-changed)
    global CONTROL_UDP_ADDR
    if len(sys.argv) >= 2 and sys.argv[1].strip():
        CONTROL_UDP_ADDR = _parse_hostport(sys.argv[1], CONTROL_UDP_ADDR[1])

    srv = ThreadingHTTPServer((DEFAULT_HOST, DEFAULT_PORT), Handler)
    print(f"Web control listening on http://{DEFAULT_HOST}:{DEFAULT_PORT}")
    print(f"Sending UDP control to {CONTROL_UDP_ADDR[0]}:{CONTROL_UDP_ADDR[1]}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
