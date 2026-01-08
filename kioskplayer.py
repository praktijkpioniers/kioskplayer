#!/usr/bin/env python3
# museum_player.py — mpv renders everything (idle image + OSD + video), menu + color presets + sleep / blank modes
# Logs: /tmp/museum_player.log + /tmp/museum_mpv.log

from __future__ import annotations

import json
import os
import queue
import random
import signal
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

# ─────────────────────────────────────────────────────────────────────────────
# Hardware blank test knobs (CONFIGURABLE HERE, NOT IN MENU)
# ─────────────────────────────────────────────────────────────────────────────
#
# When blank_mode is XSET/VCGENCMD, you discovered mpv/OpenGL can wake DPMS.
# Choose one strategy for the test team (you):
#
#   "IGNORE"    : just issue dpms off/on; accept possible wake-ups
#   "KILL_MPV"  : quit mpv before DPMS off; restart mpv after DPMS on
#   "SIGSTOP"   : SIGSTOP mpv before DPMS off; SIGCONT after DPMS on (most deterministic)
#   "SOFT_IPC"  : try mpv IPC stop/pause/osd-off to reduce redraw before DPMS off
#   "SPAM_DPMS" : keep re-issuing dpms off periodically while in SLEEP
#
HARDWARE_SLEEP_STRATEGY = "SIGSTOP" #"SOFT_IPC" #"IGNORE" #"KILL_MPV" #"SPAM_DPMS" #"KILL_MPV" #"SIGSTOP"   # <- change me

# For SPAM_DPMS:
SPAM_DPMS_INTERVAL_S = 0.7            # seconds between "force off" commands
SPAM_DPMS_MAX_RUNTIME_S = 0.0         # 0.0 = run until wake, else stop after N seconds

#web control
CONTROL_UDP_HOST = "127.0.0.1"
CONTROL_UDP_PORT = 9999
CONTROL_MAGIC = b"CONFIG_CHANGED\n"

# Subtitle sidecars we consider while scanning the video directory
SUB_EXTS = (".srt", ".vtt", ".ass", ".ssa")


# ─────────────────────────────────────────────────────────────────────────────


# GPIO optional (PC dev mode)
try:
    from gpiozero import Button as GpioButton, LED as GpioLED  # type: ignore
except Exception:
    GpioButton = None
    GpioLED = None


LOG_PATH = Path("/tmp/museum_player.log")
MPV_LOG_PATH = Path("/tmp/museum_mpv.log")

SKIP_LOG = True


def log(msg: str) -> None:
    if SKIP_LOG:
        print(msg)
        return
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%F %T')} {msg}\n")
    except Exception:
        pass


CONFIG_PATH = Path("./config.json")
VERBOSE = False
SHOW_PASS_HINT = True


# Blank/sleep behaviour:
#   NONE     : do nothing (screen never blanked by us)
#   BLACK    : fake black (no wake delay)
#   XSET     : X11 DPMS off/on via xset (wake delay ~2s)
#   VCGENCMD : legacy display_power 0/1 (wake delay ~2s)
#   WAYLAND  : placeholder (not implemented yet; we fall back to BLACK)
DEFAULT_CONFIG: dict[str, Any] = {
    "video_dir": str(Path("~/Videos").expanduser().resolve()),
    "image_dir": "./images",

    "active_video": 0,
    "loop_mode": "OFF",  # OFF | SINGLE | ALL | RANDOM

    "button_pin": 17,
    "led_pin": None,
    "button_bounce_s": 0.05,
    "long_press_s": 1.0,

    "passkey": ".--..-",
    "passkey_timeout_s": 3.0,

    "menu_timeout_s": 60.0,

    # Screen timeout (menu-cyclable)
    "idle_timeout_s": 60.0,       # <- default 60 as requested
    "monitor_wake_s": 2.0,        # <- only for hardware blank modes

    # NEW: after going fake-black, transition into real powersave after N seconds (default 300 = 5min)
    "powersave_after_s": 300.0,

    # Unified blank mode (single source of truth)
    "blank_mode": "XSET",         # NONE | BLACK | XSET | VCGENCMD | WAYLAND

    # Fake-black options
    "sleep_black_image": "./images/black.png",

    "ui_title": "Waterlinie Museum",
    "ui_subtitle": "Druk op de start knop",
    "ui_loading": "Afspelen…",
    "ui_background_image": "./images/logo1.png",

    "mpv_ipc_path": "/tmp/museum_player_mpv.sock",
    "mpv_binary": "mpv",
    "mpv_hwdec": "no",

    "osd_idle_ms": 120000,
    "osd_menu_ms": 1500,
    "osd_pass_ms": 1500,

    "color_preset": "VIVID",  # NEUTRAL | VIVID | PUNCHY | CRAZY | CUSTOM
    "color_saturation": 1.35,
    "color_brightness": 0.00,
    "color_gamma": 1.00,
    "color_contrast": 1.00,

    "web_port": 8080,

    # Gallery mode switch
    "play_mode": "VIDEO",  # VIDEO | SLIDESHOW

    # NEW: expo/continuous mode (auto-start after idle timeout even if loop_mode is OFF)
    "expo_mode": False,

    # NEW: slideshow timing (seconds per image) when play_mode=SLIDESHOW
    "slideshow_interval_s": 10.0,

    # NEW: screensaver schedule gating (when idle blanking is allowed)
    # window may cross midnight (e.g., 17:00 -> 09:00)
    "screensaver_window_enable": True,
    "screensaver_start_hhmm": "17:00",
    "screensaver_end_hhmm": "09:00",

    # Subtitle control (2nd button)
    "subtitle_button_pin": 27,          # pick your GPIO
    "subtitle_button_bounce_s": 0.05,
    "subtitle_restart_window_s": 3.0,   # "reasonable time limit"
    "subtitle_lang_prefer": ["nl", "en", "de", "fr", "es"],

    "subtitle_remember_s": 120.0,  # remember selection for 2 minutes
    "subtitle_default_on": False,
}



def load_config() -> dict[str, Any]:
    merged = dict(DEFAULT_CONFIG)
    changed = False

    if CONFIG_PATH.exists():
        try:
            data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                merged.update(data)
                for k in DEFAULT_CONFIG:
                    if k not in data:
                        changed = True
            else:
                changed = True
        except Exception as e:
            log(f"CONFIG parse failed: {e!r}")
            changed = True
    else:
        changed = True

    if changed:
        try:
            save_config(merged)
            log("CONFIG auto-filled missing keys")
        except Exception as e:
            log(f"CONFIG auto-save failed: {e!r}")

    return merged



def save_config(cfg: dict[str, Any]) -> None:
    tmp = CONFIG_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(CONFIG_PATH)



class DisplayBlanker:
    """One place that knows how to blank/unblank for the chosen blank_mode."""

    def __init__(self, cfg: dict[str, Any]):
        self.cfg = cfg

    def blank_mode(self) -> str:
        return str(self.cfg.get("blank_mode", "BLACK")).upper()

    def hw_blank_off(self) -> None:
        mode = self.blank_mode()
        if mode == "XSET":
            self._run(["xset", "dpms", "force", "off"])
        elif mode == "VCGENCMD":
            self._run(["vcgencmd", "display_power", "0"])
        else:
            pass

    def hw_blank_on(self) -> None:
        mode = self.blank_mode()
        if mode == "XSET":
            self._run(["xset", "dpms", "force", "on"])
        elif mode == "VCGENCMD":
            self._run(["vcgencmd", "display_power", "1"])
        else:
            pass

    def is_hardware_mode(self) -> bool:
        return self.blank_mode() in ("XSET", "VCGENCMD")

    def _run(self, argv: list[str]) -> None:
        try:
            p = subprocess.run(argv, check=False, capture_output=True, text=True)
            log(f"blank cmd rc={p.returncode} argv={argv!r} out={p.stdout[-200:]!r} err={p.stderr[-200:]!r}")
        except Exception as e:
            log(f"blank cmd exception argv={argv!r} err={e!r}")


@dataclass
class BtnEvent:
    kind: str   # "down" | "up" | "config"
    t: float



class ButtonIO:
    """
    GPIO if available. Otherwise reads stdin:
      - press 's' + Enter for short, 'l' + Enter for long
    """

    def __init__(self, pin: int, led_pin: Optional[int], bounce_s: float, enable_stdin: bool = True):
        self.q: "queue.Queue[BtnEvent]" = queue.Queue()
        self.button = None
        self.led = None

        if GpioButton is not None:
            try:
                self.button = GpioButton(pin, pull_up=True, bounce_time=max(0.0, float(bounce_s)))
                self.button.when_pressed = self._on_down
                self.button.when_released = self._on_up
                log(f"GPIO enabled pin={pin} bounce={bounce_s}")
            except Exception as e:
                log(f"GPIO init failed: {e!r}")
                self.button = None

            if led_pin is not None and GpioLED is not None:
                try:
                    self.led = GpioLED(int(led_pin))
                except Exception:
                    self.led = None
        else:
            log("GPIO unavailable (gpiozero not installed)")

        if self.button is None and enable_stdin:
            thr = threading.Thread(target=self._stdin_loop, daemon=True)
            thr.start()
            log("stdin button emulation enabled (type 's' or 'l' + Enter)")

    def inject_config_changed(self) -> None:
        self.q.put(BtnEvent("config", time.time()))


    def _stdin_loop(self) -> None:
        while True:
            try:
                line = sys.stdin.readline()
                if not line:
                    time.sleep(0.1)
                    continue
                line = line.strip().lower()
                if line == "s":
                    t = time.time()
                    self.q.put(BtnEvent("down", t))
                    self.q.put(BtnEvent("up", t + 0.1))
                elif line == "l":
                    t = time.time()
                    self.q.put(BtnEvent("down", t))
                    self.q.put(BtnEvent("up", t + 2.0))
            except Exception:
                time.sleep(0.1)

    def _on_down(self) -> None:
        self.q.put(BtnEvent("down", time.time()))

    def _on_up(self) -> None:
        self.q.put(BtnEvent("up", time.time()))

    def led_set(self, on: bool) -> None:
        if self.led is None:
            return
        try:
            self.led.on() if on else self.led.off()
        except Exception:
            pass


class MpvIpc:
    def __init__(self, ipc_path: str):
        self.ipc_path = ipc_path
        self._sock: Optional[socket.socket] = None
        self._rbuf = b""
        self._next_id = 1
        self.events: "queue.Queue[dict[str, Any]]" = queue.Queue()
        self._reader_thr: Optional[threading.Thread] = None
        self._stop_reader = False
        self._replies: dict[int, dict[str, Any]] = {}
        self._reply_cv = threading.Condition()


    def connect(self, timeout_s: float = 5.0) -> None:
        t0 = time.time()
        while True:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(self.ipc_path)
                self._sock = s
                log(f"IPC connected {self.ipc_path}")
                break
            except Exception:
                if time.time() - t0 > timeout_s:
                    raise
                time.sleep(0.05)

        self._stop_reader = False
        self._reader_thr = threading.Thread(target=self._reader_loop, daemon=True)
        self._reader_thr.start()

    def close(self) -> None:
        self._stop_reader = True
        if self._sock:
            try:
                self._sock.close()
            except Exception:
                pass
        self._sock = None

    def get_property(self, name: str, timeout_s: float = 1.0) -> Any:
        rep = self.command_reply_wait("get_property", name, timeout_s=timeout_s)
        if rep.get("error") == "success":
            return rep.get("data")
        return None

    def command_reply_wait(self, *args: Any, timeout_s: float = 1.0) -> dict[str, Any]:
        if self._sock is None:
            raise RuntimeError("mpv IPC not connected")

        req_id = self._next_id
        self._next_id += 1
        req = {"command": list(args), "request_id": req_id}
        self._sock.sendall((json.dumps(req) + "\n").encode("utf-8"))

        deadline = time.time() + max(0.05, float(timeout_s))
        with self._reply_cv:
            while True:
                if req_id in self._replies:
                    return self._replies.pop(req_id)
                now = time.time()
                if now >= deadline:
                    return {"request_id": req_id, "error": "timeout"}
                self._reply_cv.wait(timeout=deadline - now)


    def _reader_loop(self) -> None:
        while not self._stop_reader and self._sock is not None:
            try:
                chunk = self._sock.recv(4096)
                if not chunk:
                    time.sleep(0.05)
                    continue
                self._rbuf += chunk
                while b"\n" in self._rbuf:
                    line, self._rbuf = self._rbuf.split(b"\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        msg = json.loads(line.decode("utf-8", "replace"))
                        if not isinstance(msg, dict):
                            continue

                        # Event messages
                        if "event" in msg:
                            self.events.put(msg)
                            continue

                        # Reply messages
                        if "request_id" in msg:
                            rid = int(msg.get("request_id") or 0)
                            if rid:
                                with self._reply_cv:
                                    self._replies[rid] = msg
                                    self._reply_cv.notify_all()

                    except Exception:
                        pass
            except Exception:
                time.sleep(0.05)

    def command(self, *args: Any) -> None:
        self.command_reply(*args)

    def command_reply(self, *args: Any) -> dict[str, Any]:
        if self._sock is None:
            raise RuntimeError("mpv IPC not connected")
        req_id = self._next_id
        self._next_id += 1
        req = {"command": list(args), "request_id": req_id}
        data = (json.dumps(req) + "\n").encode("utf-8")
        self._sock.sendall(data)
        return {"request_id": req_id}

    def set_property(self, name: str, value: Any) -> None:
        self.command("set_property", name, value)

    def show_text(self, text: str, duration_ms: int = 2000) -> None:
        self.command("show-text", text, duration_ms)


class MpvRenderer:
    VIDEO_EXTS = (".mp4", ".mkv", ".avi", ".mov", ".webm")
    IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".bmp", ".gif", ".webp")

    COLOR_PRESETS: dict[str, dict[str, float]] = {
        "NEUTRAL": {"saturation": 1.00, "brightness": 0.00, "contrast": 1.00, "gamma": 1.00},
        "VIVID": {"saturation": 1.35, "brightness": 0.00, "contrast": 1.05, "gamma": 1.00},
        "PUNCHY": {"saturation": 1.25, "brightness": 0.03, "contrast": 1.15, "gamma": 0.95},
        "CRAZY": {"saturation": 1.70, "brightness": 0.05, "contrast": 1.20, "gamma": 0.90},
        "BLACK&WHITE": {"saturation": 0.0, "brightness": -0.15, "contrast": 1.10, "gamma": 1.00},
        "B&W FLAT": {"saturation": 0.0, "brightness": 0.00, "contrast": 1.00, "gamma": 1.00},
        "B&W CINEMA": {"saturation": 0.0, "brightness": 0.02, "contrast": 1.12, "gamma": 0.95},
        "SEPIA": {"saturation": 0.35, "brightness": 0.05, "contrast": 1.05, "gamma": 0.90},
        "SEPIA SUBTLE": {"saturation": 0.50, "brightness": 0.03, "contrast": 1.03, "gamma": 0.95},
    }

    def __init__(self, cfg: dict[str, Any]):
        self.cfg = cfg
        self.ipc_path = str(cfg.get("mpv_ipc_path", "/tmp/museum_player_mpv.sock"))
        self.mpv_bin = str(cfg.get("mpv_binary", "mpv"))
        self.hwdec = str(cfg.get("mpv_hwdec", "no"))

        self.proc: Optional[subprocess.Popen] = None
        self.ipc = MpvIpc(self.ipc_path)

        self._idle_path: Optional[Path] = None
        self._showing_idle: bool = False

    def start(self) -> None:
        try:
            LOG_PATH.write_text("", encoding="utf-8")
        except Exception:
            pass
        try:
            MPV_LOG_PATH.write_text("", encoding="utf-8")
        except Exception:
            pass

        ipc_parent = Path(self.ipc_path).parent
        try:
            ipc_parent.mkdir(parents=True, exist_ok=True)
        except Exception as e:
            log(f"IPC parent mkdir failed {ipc_parent}: {e!r}")

        try:
            if os.path.exists(self.ipc_path):
                os.unlink(self.ipc_path)
        except Exception as e:
            log(f"IPC unlink failed: {e!r}")

        args = [
            self.mpv_bin,
            "--fs",
            "--no-border",
            "--no-terminal",
            "--force-window=yes",
            "--vo=gpu",
            "--gpu-api=opengl",
            f"--hwdec={self.hwdec}",
            "--osd-align-x=center",
            "--osd-align-y=top",
            "--osd-level=1",
            "--osd-font-size=36",
            "--no-osc",
            #"--video-sync=display-vdrop",
            "--video-sync=audio",
            "--cursor-autohide=always",
            "--input-default-bindings=no",
            "--input-vo-keyboard=no",
            f"--input-ipc-server={self.ipc_path}",
            "--idle=yes",
            "--image-display-duration=inf",
            "--loop-file=no",
            f"--log-file={str(MPV_LOG_PATH)}",
        ]

        log(f"Starting mpv: {' '.join(args)}")
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        t0 = time.time()
        while not os.path.exists(self.ipc_path):
            if self.proc.poll() is not None:
                log("ERROR: mpv exited before creating IPC socket")
                raise RuntimeError("mpv exited early; see /tmp/museum_mpv.log")
            if time.time() - t0 > 5.0:
                log("ERROR: IPC socket did not appear in time")
                raise RuntimeError("mpv IPC socket not created; check mpv_ipc_path and /tmp/museum_mpv.log")
            time.sleep(0.05)

        self.ipc.connect(timeout_s=5.0)
        self.ipc.command("enable_event", "end-file")
        self.ipc.command("enable_event", "file-loaded")
        self.ipc.set_property("osd-fractions", False)

        self.apply_color_from_cfg()

    def stop(self) -> None:
        try:
            self.ipc.command("quit")
        except Exception:
            pass
        self.ipc.close()
        if self.proc is not None:
            try:
                self.proc.terminate()
            except Exception:
                pass
            self.proc = None

    def freeze(self) -> None:
        # Hard stop: mpv cannot repaint, cannot wake DPMS.
        if self.proc is None:
            return
        try:
            os.kill(self.proc.pid, signal.SIGSTOP)
            log(f"mpv SIGSTOP pid={self.proc.pid}")
        except Exception as e:
            log(f"mpv SIGSTOP failed: {e!r}")

    def thaw(self) -> None:
        if self.proc is None:
            return
        try:
            os.kill(self.proc.pid, signal.SIGCONT)
            log(f"mpv SIGCONT pid={self.proc.pid}")
        except Exception as e:
            log(f"mpv SIGCONT failed: {e!r}")

    def ipc_soft_sleep(self) -> None:
        # Best-effort: reduce redraw sources before DPMS off.
        # (Not guaranteed — mpv may still present frames.)
        try:
            self.ipc.set_property("osd-level", 0)
        except Exception:
            pass
        try:
            self.ipc.set_property("pause", True)
        except Exception:
            pass
        try:
            self.ipc.command("stop")
        except Exception:
            pass

    def ipc_soft_wake(self) -> None:
        # Restore basic OSD; visuals will be reloaded by enter_idle() anyway.
        try:
            self.ipc.set_property("osd-level", 1)
        except Exception:
            pass
        try:
            self.ipc.set_property("pause", False)
        except Exception:
            pass

    def is_alive(self) -> bool:
        return self.proc is not None and (self.proc.poll() is None)

    def apply_color_from_cfg(self) -> None:
        preset = str(self.cfg.get("color_preset", "VIVID")).upper()
        sat = float(self.cfg.get("color_saturation", 1.35))
        bri = float(self.cfg.get("color_brightness", 0.0))
        con = float(self.cfg.get("color_contrast", 1.0))
        gam = float(self.cfg.get("color_gamma", 1.0))
        self.set_color(preset, sat, bri, con, gam)

    def set_color(self, preset: str, sat: float, bri: float, con: float, gam: float) -> None:
        preset = preset.upper()
        if preset != "CUSTOM" and preset in self.COLOR_PRESETS:
            p = self.COLOR_PRESETS[preset]
            sat = float(p["saturation"])
            bri = float(p["brightness"])
            con = float(p.get("contrast", 1.0))
            gam = float(p["gamma"])

        vf = f"eq=saturation={sat:.3f}:brightness={bri:.3f}:contrast={con:.3f}:gamma={gam:.3f}"
        log(f"apply vf: {vf} preset={preset}")
        try:
            self.ipc.set_property("vf", vf)
        except Exception as e:
            log(f"set_property vf failed: {e!r}")

    def force_black(self, on: bool) -> None:
        if on:
            try:
                self.ipc.set_property("vf", "eq=brightness=-1.000")
            except Exception as e:
                log(f"force_black ON failed: {e!r}")
        else:
            self.apply_color_from_cfg()

    def load_idle(self, img: Optional[Path], force: bool = False) -> None:
        if (not force) and self._showing_idle and (img == self._idle_path):
            return

        self._idle_path = img
        self._showing_idle = True
        try:
            self.ipc.show_text("", 1)
        except Exception:
            pass

        if img and img.exists():
            log(f"mpv idle loadfile {img}")
            self.ipc.command("loadfile", str(img), "replace")
            self.ipc.set_property("loop-file", "no")
        else:
            log("mpv idle stop (no background image)")
            self.ipc.command("stop")
            try:
                self.ipc.show_text("", 1)
            except Exception:
                pass

    def play_video(self, path: Path, loop_inf: bool) -> None:
        self._showing_idle = False
        log(f"mpv loadfile {path} loop_inf={loop_inf}")
        self.ipc.command("loadfile", str(path), "replace")
        self.ipc.set_property("loop-file", "inf" if loop_inf else "no")

    def stop_video(self) -> None:
        log("mpv stop_video")
        self.ipc.command("stop")
        self.load_idle(self._idle_path, force=True)

    def osd(self, lines: list[str], duration_ms: int = 1000) -> None:
        txt = "\n".join(lines)
        log(f"osd {duration_ms}ms: {txt.replace(chr(10), ' | ')}")
        self.ipc.show_text(txt, duration_ms)


class App:
    LOOP_LABELS = ["OFF", "SINGLE", "ALL", "RANDOM"]
    BLANK_LABELS = ["NONE", "BLACK", "XSET", "VCGENCMD", "WAYLAND"]
    TIMEOUT_CHOICES = [5, 10, 30, 60, 90, 180, 300, 600]
    COLOR_LABELS = list(MpvRenderer.COLOR_PRESETS.keys()) + ["CUSTOM"]

    # NEW: menu-cyclable deep-powersave delay; 300s default is “5 min then powersave”
    POWERSAVE_CHOICES = [0, 300, 600, 1800]  # OFF, 5m, 10m, 30m

    def __init__(self, cfg: dict[str, Any]):
        self.cfg = cfg
        self.blanker = DisplayBlanker(cfg)

        self.video_dir = Path(str(cfg.get("video_dir", DEFAULT_CONFIG["video_dir"]))).expanduser().resolve()
        self.image_dir = Path(str(cfg.get("image_dir", DEFAULT_CONFIG["image_dir"]))).expanduser()

        self.long_press_s = float(cfg.get("long_press_s", 1.0))
        self.passkey = str(cfg.get("passkey", ".--..-"))
        self.passkey_timeout_s = float(cfg.get("passkey_timeout_s", 3.0))
        self.menu_timeout_s = float(cfg.get("menu_timeout_s", 60.0))

        self.idle_timeout_s = float(cfg.get("idle_timeout_s", 60.0))
        self.monitor_wake_s = float(cfg.get("monitor_wake_s", 2.0))

        # NEW
        self.powersave_after_s = float(cfg.get("powersave_after_s", 300.0))

        self.osd_idle_ms = int(cfg.get("osd_idle_ms", 120000))
        self.osd_menu_ms = int(cfg.get("osd_menu_ms", 1500))
        self.osd_pass_ms = int(cfg.get("osd_pass_ms", 1500))

        self.loop_mode = str(cfg.get("loop_mode", "OFF")).upper()
        if self.loop_mode not in self.LOOP_LABELS:
            self.loop_mode = "OFF"

        self.active_video = int(cfg.get("active_video", 0))

        self.blank_mode = str(cfg.get("blank_mode", "BLACK")).upper()
        if self.blank_mode not in self.BLANK_LABELS:
            self.blank_mode = "BLACK"
        self.sleep_black_image = Path(str(cfg.get("sleep_black_image", "./images/black.png"))).expanduser()

        self.color_preset = str(cfg.get("color_preset", "VIVID")).upper()
        if self.color_preset not in self.COLOR_LABELS:
            self.color_preset = "VIVID"
        self.color_saturation = float(cfg.get("color_saturation", 1.35))
        self.color_brightness = float(cfg.get("color_brightness", 0.0))
        self.color_gamma = float(cfg.get("color_gamma", 1.0))
        self.color_contrast = float(cfg.get("color_contrast", 1.0))

        self.io = ButtonIO(
            int(cfg.get("button_pin", 17)),
            cfg.get("led_pin"),
            bounce_s=float(cfg.get("button_bounce_s", 0.05)),
        )

        self.sub_io = ButtonIO(
            int(cfg.get("subtitle_button_pin", 27)),
            led_pin=None,
            bounce_s=float(cfg.get("subtitle_button_bounce_s", 0.05)),
            enable_stdin=False,
        )

        self.subtitle_restart_window_s = float(cfg.get("subtitle_restart_window_s", 3.0))
        self.subtitle_lang_prefer = [str(x).lower() for x in cfg.get("subtitle_lang_prefer", ["nl","en","de","fr","es"])]

        self._subtitle_changed_t: Optional[float] = None

        self.subtitle_remember_s = float(cfg.get("subtitle_remember_s", 600.0))
        self._subtitle_pref_index: int = 0
        self._subtitle_pref_set_t: Optional[float] = None

        self.subtitle_default_on = bool(cfg.get("subtitle_default_on", False))




        self.renderer = MpvRenderer(cfg)

        self.state = "IDLE"  # SLEEP | IDLE | PASSKEY | MENU | PLAYING
        self.last_activity = time.time()
        self.idle_since = time.time()

        self.press_down_t: Optional[float] = None
        self._debounce_s = max(0.0, float(cfg.get("button_bounce_s", 0.05)))
        self._last_raw_event_t: float = 0.0
        self._logical_is_down: bool = False

        self.passkey_buf = ""
        self.passkey_last_input_t: Optional[float] = None
        self.passkey_started_t: Optional[float] = None

        self.menu_index = 0
        self.videos: list[Path] = []
        self.images: list[Path] = []

        # Track if we went into hardware blank (needs wake delay)
        self._slept_hardware_off: bool = False

        # NEW: in SLEEP we can do a “soft black phase” before real powersave
        self._sleep_soft_phase: bool = False
        self._sleep_soft_started_t: Optional[float] = None

        # Strategy bookkeeping
        self._mpv_frozen: bool = False
        self._mpv_killed: bool = False
        self._dpms_spam_stop = threading.Event()
        self._dpms_spam_thr: Optional[threading.Thread] = None


        # expo/continuous mode
        self.expo_mode = bool(cfg.get("expo_mode", False))

        # slideshow (fallback when no videos; or explicit enable)
        #self.slideshow_enable = bool(cfg.get("slideshow_enable", True)) #obsolete
        self.slideshow_interval_s = float(cfg.get("slideshow_interval_s", 10.0))
        self._slideshow_index = 0
        self._next_slide_t: Optional[float] = None

        # screensaver time window gating
        self.screensaver_window_enable = bool(cfg.get("screensaver_window_enable", True))
        self.screensaver_start_hhmm = str(cfg.get("screensaver_start_hhmm", "17:05"))
        self.screensaver_end_hhmm = str(cfg.get("screensaver_end_hhmm", "08:55"))

        #subtitles
        self._pending_preferred_lang: Optional[str] = None

        thr = threading.Thread(target=self._udp_control_loop, daemon=True)
        thr.start()

        log(f"App init done. HARDWARE_SLEEP_STRATEGY={HARDWARE_SLEEP_STRATEGY} powersave_after_s={self.powersave_after_s}")


    def _now(self) -> float:
        return time.time()

    def _primary_ip(self) -> str:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
            s.close()
            return ip
        except Exception:
            return "127.0.0.1"

    def _hex_ip(self, ip: str) -> str:
        try:
            return "".join(f"{int(p):02x}" for p in ip.split("."))
        except Exception:
            return "00000000"

    #subtitle scanning
    def _scan_subtitle_files(self) -> list[Path]:
        try:
            if not self.video_dir.exists() or not self.video_dir.is_dir():
                return []
            return sorted(
                p for p in self.video_dir.iterdir()
                if p.is_file() and p.suffix.lower() in self.SUB_EXTS
            )
        except Exception as e:
            log(f"scan_subtitles error: {e!r}")
            return []

    def _extract_lang_from_sub_filename(self, p: Path) -> Optional[str]:
        """
        Accepts common patterns:
          - movie.en.srt  -> "en"
          - movie.pt-BR.vtt -> "pt-br"
          - whatever.nl.ass -> "nl"
        Strategy: take last token of stem after '.', validate.
        """
        try:
            stem = p.stem  # filename without extension, e.g. "movie.en"
            if "." not in stem:
                return None
            tok = stem.split(".")[-1].strip().lower()
            if not tok:
                return None

            # Normalize separators
            tok = tok.replace("_", "-")

            # Very small sanity checks (avoid grabbing "final", "subtitles", etc.)
            # Allow: "en", "nl", "de", "fr", "es", "pt-br", "zh-hans", "sr-latn" (up to 8+ parts but short tokens)
            parts = tok.split("-")
            if any((not part.isalnum()) for part in parts):
                return None

            # Typical: 2-3 letters for language, optionally region/script pieces
            # Require first part to look like a language code.
            first = parts[0]
            if not (2 <= len(first) <= 3) or not first.isalpha():
                return None

            # Limit total token length so we don’t accept random long junk.
            if len(tok) > 16:
                return None

            return tok
        except Exception:
            return None

    def _discover_subtitle_languages(self) -> list[str]:
        langs: set[str] = set()
        for p in self._scan_subtitle_files():
            lang = self._extract_lang_from_sub_filename(p)
            if lang:
                langs.add(lang)

        # Return stable order for “extras”
        return sorted(langs)

    def _merge_subtitle_preferences_startup(self) -> None:
        """
        Startup-only:
          - keep configured prefer order
          - append discovered languages not already present
          - keep everything lowercase
        """
        base = [str(x).lower() for x in (self.subtitle_lang_prefer or [])]
        base = [x.replace("_", "-") for x in base if x]

        discovered = self._discover_subtitle_languages()

        merged: list[str] = []
        seen: set[str] = set()

        for x in base:
            if x not in seen:
                merged.append(x)
                seen.add(x)

        for x in discovered:
            if x not in seen:
                merged.append(x)
                seen.add(x)

        # If nothing at all, keep a safe default
        if not merged:
            merged = ["nl", "en"]

        if merged != self.subtitle_lang_prefer:
            log(f"subtitle_lang_prefer startup merge: {self.subtitle_lang_prefer} -> {merged}")
        self.subtitle_lang_prefer = merged



    def _udp_control_loop(self) -> None:
        # Receives:
        #   "short\n"  -> inject short press
        #   "long\n"   -> inject long press
        #   "CONFIG_CHANGED\n" -> inject config event
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind((CONTROL_UDP_HOST, CONTROL_UDP_PORT))
        log(f"UDP control listening on {CONTROL_UDP_HOST}:{CONTROL_UDP_PORT}")
        while True:
            try:
                data, _addr = s.recvfrom(1024)
                if not data:
                    continue

                if data == CONTROL_MAGIC:
                    self.io.inject_config_changed()
                    continue

                msg = data.decode("utf-8", "replace").strip().lower()
                if msg == "short":
                    t = time.time()
                    self.io.q.put(BtnEvent("down", t))
                    self.io.q.put(BtnEvent("up", t + 0.1))
                elif msg == "long":
                    t = time.time()
                    self.io.q.put(BtnEvent("down", t))
                    self.io.q.put(BtnEvent("up", t + 1.2))
                elif msg in ("sub", "subtitle"):
                    # emulate a full subtitle button press (down+up) using the *same* event kinds as GPIO
                    t = time.time()
                    self.sub_io.q.put(BtnEvent("down", t))
                    self.sub_io.q.put(BtnEvent("up", t + 0.1))

                elif msg in ("subdown", "subtitle_down"):
                    # optional: support explicit down (if you ever want it)
                    t = time.time()
                    self.sub_io.q.put(BtnEvent("down", t))

                elif msg in ("subup", "subtitle_up"):
                    # optional: support explicit up
                    t = time.time()
                    self.sub_io.q.put(BtnEvent("up", t))


            except Exception:
                time.sleep(0.1)

    def _apply_default_subtitle_mode(self) -> None:
        if self.subtitle_default_on:
            # pick first preferred language (whatever your existing code uses)
            self._subtitle_pref_index = 0
            self._pending_preferred_lang = self.subtitle_lang_prefer[0] if self.subtitle_lang_prefer else None
        else:
            # set to OFF state
            self._pending_preferred_lang = "off"



    def _idle_footer(self) -> str:
        ip = self._primary_ip()
        port = int(self.cfg.get("web_port", 0))
        host = socket.gethostname()
        return f"{self._hex_ip(ip)} {port:04x} {host}"

    def _parse_hhmm(self, s: str) -> int:
        # returns minutes since midnight; invalid -> 0
        try:
            parts = s.strip().split(":")
            hh = int(parts[0])
            mm = int(parts[1]) if len(parts) > 1 else 0
            hh = max(0, min(23, hh))
            mm = max(0, min(59, mm))
            return hh * 60 + mm
        except Exception:
            return 0

    def _screensaver_allowed_now(self) -> bool:
        if not self.screensaver_window_enable:
            return True

        start_m = self._parse_hhmm(self.screensaver_start_hhmm)
        end_m = self._parse_hhmm(self.screensaver_end_hhmm)

        lt = time.localtime()
        now_m = lt.tm_hour * 60 + lt.tm_min

        # window may cross midnight (e.g., 17:00 -> 09:00)
        if start_m <= end_m:
            return start_m <= now_m < end_m
        else:
            return (now_m >= start_m) or (now_m < end_m)

    def _is_slideshow_mode(self) -> bool:
        return str(self.cfg.get("play_mode", "VIDEO")).upper() == "SLIDESHOW"


    def _start_slideshow(self) -> None:
        # Uses self.images; falls back to idle if none
        if not self.images:
            self.enter_idle()
            return

        self._set_state("PLAYING")
        self._slideshow_index %= len(self.images)
        p = self.images[self._slideshow_index]
        self._slideshow_index = (self._slideshow_index + 1) % len(self.images)

        # display image as “video” in mpv
        try:
            self.renderer.ipc.show_text("", 1)
        except Exception:
            pass
        self.renderer.play_video(p, loop_inf=False)  # mpv can load images too
        self._next_slide_t = self._now() + max(0.5, float(self.slideshow_interval_s))

    def _cycle_preferred_language(self, t: float) -> str:
        # Cycle: OFF -> preferred languages -> OFF ...
        prefer = [str(x).lower() for x in self.subtitle_lang_prefer]
        options = ["off"] + prefer

        # Initial state = OFF, so first press selects first language
        if self._subtitle_pref_set_t is None:
            self._subtitle_pref_index = 0

        self._subtitle_pref_index = (self._subtitle_pref_index + 1) % len(options)
        self._subtitle_pref_set_t = t

        v = options[self._subtitle_pref_index]
        return "OFF" if v == "off" else v.upper()


    def _handle_subtitle_press(self, t: float) -> None:
        # Always cycle preferred language selection, even in IDLE.
        # In PLAYING (video), we also try to apply immediately.
        label = self._cycle_preferred_language(t)

        # Always show feedback
        try:
            self.renderer.ipc.show_text(f"Language: {label}", 1200)
        except Exception:
            pass

        if self.state == "PLAYING" and (not self._is_slideshow_mode()):
            if self._apply_preferred_subtitle_now():
                self._subtitle_changed_t = t


    def _select_next_subtitle_track(self) -> bool:
        # Uses mpv 'track-list' to find subtitle tracks and choose by language preference.
        tracks = self.renderer.ipc.get_property("track-list", timeout_s=1.0)
        if not isinstance(tracks, list):
            return False

        subs: list[dict[str, Any]] = []
        for tr in tracks:
            if isinstance(tr, dict) and tr.get("type") == "sub":
                subs.append(tr)

        if not subs:
            # No subtitles: show a tiny hint and do nothing
            try:
                self.renderer.ipc.show_text("No subtitles found", 1200)
            except Exception:
                pass
            return False

        cur_sid = self.renderer.ipc.get_property("sid", timeout_s=0.5)
        try:
            cur_sid_i = int(cur_sid)
        except Exception:
            cur_sid_i = -1

        # Build candidate list: preferred langs first, then others
        prefer = [x.lower() for x in self.subtitle_lang_prefer]
        preferred: list[int] = []
        other: list[int] = []

        def tr_lang(tr: dict[str, Any]) -> str:
            v = tr.get("lang")
            return str(v).lower() if v else ""

        for tr in subs:
            sid = tr.get("id")
            if not isinstance(sid, int):
                continue
            lang = tr_lang(tr)
            if lang in prefer:
                preferred.append(sid)
            else:
                other.append(sid)

        # Order preferred by prefer list; keep stable within lang
        def pref_key(sid: int) -> tuple[int, int]:
            lang = ""
            for tr in subs:
                if tr.get("id") == sid:
                    lang = tr_lang(tr)
                    break
            try:
                idx = prefer.index(lang)
            except ValueError:
                idx = 999
            return (idx, sid)

        preferred.sort(key=pref_key)
        other.sort()

        # Allow OFF as last option
        candidates = preferred + other + [0]

        # Pick next after current
        if cur_sid_i in candidates:
            i = candidates.index(cur_sid_i)
            nxt = candidates[(i + 1) % len(candidates)]
        else:
            nxt = candidates[0]

        # Apply
        if nxt == 0:
            self.renderer.ipc.set_property("sid", "no")
            msg = "Subtitles: OFF"
        else:
            self.renderer.ipc.set_property("sid", int(nxt))
            # Try to show language label
            lang = ""
            for tr in subs:
                if tr.get("id") == nxt:
                    lang = str(tr.get("lang") or "").upper()
                    break
            msg = f"Subtitles: {lang or 'ON'}"

        try:
            self.renderer.ipc.set_property("sub-visibility", True)
        except Exception:
            pass

        try:
            self.renderer.ipc.show_text(msg, 1200)
        except Exception:
            pass

        return True


    def _preferred_language_active(self, now: float) -> Optional[str]:
        if self._subtitle_pref_set_t is None:
            return None
        if (now - self._subtitle_pref_set_t) > self.subtitle_remember_s:
            return None

        prefer = [str(x).lower() for x in self.subtitle_lang_prefer]
        options = ["off"] + prefer
        if not options:
            return None

        idx = self._subtitle_pref_index % len(options)
        return options[idx]  # "off" or lang code



    def _apply_preferred_subtitle_now(self) -> bool:
        pref = self._preferred_language_active(time.time())
        if pref is None:
            return False

        tracks = self.renderer.ipc.get_property("track-list", timeout_s=1.0)
        if not isinstance(tracks, list):
            return False

        subs = [tr for tr in tracks if isinstance(tr, dict) and tr.get("type") == "sub"]
        if not subs:
            return False

        if pref == "off":
            try:
                self.renderer.ipc.set_property("sid", "no")
                self.renderer.ipc.set_property("sub-visibility", False)
            except Exception:
                pass
            return True

        # Find first subtitle track matching desired language code
        pref = pref.lower()
        for tr in subs:
            lang = str(tr.get("lang") or "").lower()
            if lang == pref:
                sid = tr.get("id")
                if isinstance(sid, int):
                    self.renderer.ipc.set_property("sid", sid)
                    try:
                        self.renderer.ipc.set_property("sub-visibility", True)
                    except Exception:
                        pass
                    return True

        # If preferred language not found: do nothing (keep current)
        return False




    def _set_state(self, st: str) -> None:
        log(f"STATE {self.state} -> {st}")
        self.state = st
        self.last_activity = self._now()
        if st in ("IDLE", "SLEEP"):
            self.idle_since = self._now()

    def _event_ok(self, t: float, want_kind: str) -> bool:
        if (t - self._last_raw_event_t) < self._debounce_s:
            return False

        if want_kind == "down":
            if self._logical_is_down:
                return False
            self._logical_is_down = True
        else:
            if not self._logical_is_down:
                return False
            self._logical_is_down = False

        self._last_raw_event_t = t
        return True

    def _is_long(self, dur_s: float) -> bool:
        return dur_s >= self.long_press_s

    def _scan_videos(self) -> list[Path]:
        exts = MpvRenderer.VIDEO_EXTS
        try:
            if not self.video_dir.exists() or not self.video_dir.is_dir():
                log(f"scan_videos: missing dir {self.video_dir}")
                return []
            return sorted(p for p in self.video_dir.iterdir() if p.is_file() and p.suffix.lower() in exts)
        except Exception as e:
            log(f"scan_videos error: {e!r}")
            return []

    def _scan_images(self) -> list[Path]:
        exts = MpvRenderer.IMAGE_EXTS
        try:
            if not self.image_dir.exists() or not self.image_dir.is_dir():
                log(f"scan_images: missing dir {self.image_dir}")
                return []
            return sorted(p for p in self.image_dir.iterdir() if p.is_file() and p.suffix.lower() in exts)
        except Exception as e:
            log(f"scan_images error: {e!r}")
            return []

    def _current_video_path(self) -> Optional[Path]:
        if not self.videos:
            return None
        self.active_video %= len(self.videos)
        return self.videos[self.active_video]

    def _bg_path(self) -> Optional[Path]:
        p = self.cfg.get("ui_background_image")
        if not p:
            return None
        return Path(str(p)).expanduser()

    def _render_idle(self) -> None:
        title = str(self.cfg.get("ui_title", ""))
        subtitle = str(self.cfg.get("ui_subtitle", ""))
        self.renderer.osd([title, "", subtitle], duration_ms=self.osd_idle_ms)

        # tiny footer, bottom-left
        footer = "{\\an1\\fs8}" + self._idle_footer()
        try:
            self.renderer.ipc.command("osd-overlay", 99, "ass-events", footer, self.osd_idle_ms)
        except Exception:
            pass


    def _render_passkey(self) -> None:
        title = str(self.cfg.get("ui_title", ""))
        loading = str(self.cfg.get("ui_loading", ""))
        hint = f"{self.passkey}{self.passkey_buf}" if SHOW_PASS_HINT else ""
        lines = [title, "", loading]
        if hint:
            lines += ["", hint]
        self.renderer.osd(lines, duration_ms=self.osd_pass_ms)

    def _menu_items(self) -> list[str]:
        loop_line = f"LOOP: {self.loop_mode}"

        if self.videos:
            p = self._current_video_path()
            name = p.name if p else "(?)"
            vid_line = f"VIDEO: {self.active_video+1}/{len(self.videos)}  {name}"
        else:
            vid_line = "VIDEO: (none)"

        bgp = self.cfg.get("ui_background_image")
        bg_line = f"BG: {Path(str(bgp)).name}" if bgp else "BG: (none)"

        color_line = f"COLOR: {self.color_preset}"
        if self.color_preset == "CUSTOM":
            sat_line = f"SAT: {self.color_saturation:.2f}"
            bri_line = f"BRI: {self.color_brightness:+.2f}"
            con_line = f"CON: {self.color_contrast:.2f}"
            gam_line = f"GAM: {self.color_gamma:.2f}"
        else:
            sat_line = "SAT: (preset)"
            bri_line = "BRI: (preset)"
            con_line = "CON: (preset)"
            gam_line = "GAM: (preset)"

        blank_line = f"BLANK: {self.blank_mode}"
        ps = int(round(float(self.powersave_after_s)))
        ps_line = f"POWERSAVE AFTER: {'OFF' if ps <= 0 else f'{ps}s'}"
        timeout_line = f"TIMEOUT: {int(self.idle_timeout_s)}s"
        blank_now = "BLANK NOW"

        return [
            loop_line,
            vid_line,
            bg_line,
            color_line,
            sat_line,
            bri_line,
            con_line,
            gam_line,
            blank_line,
            ps_line,         # NEW
            timeout_line,
            blank_now,
            "EXIT",
        ]

    def _render_menu(self) -> None:
        items = self._menu_items()
        shown: list[str] = ["MENU", ""]
        for i, s in enumerate(items):
            shown.append(("> " if i == self.menu_index else "  ") + s)
        shown += ["", "Short=next   Long=select"]
        self.renderer.osd(shown, duration_ms=self.osd_menu_ms)

    def enter_idle(self) -> None:
        self._set_state("IDLE")
        self.passkey_buf = ""
        self.passkey_last_input_t = None
        self.passkey_started_t = None
        self.renderer.apply_color_from_cfg()
        self.renderer.load_idle(self._bg_path(), force=True)
        self._render_idle()

    def enter_passkey(self) -> None:
        self._set_state("PASSKEY")
        self.passkey_buf = ""
        now = self._now()
        self.passkey_started_t = now
        self.passkey_last_input_t = now
        self._render_passkey()

    def enter_menu(self) -> None:
        self._set_state("MENU")
        self.menu_index = 0
        self.videos = self._scan_videos()
        self.images = self._scan_images()
        if self.videos:
            self.active_video %= len(self.videos)
        else:
            self.active_video = 0
        self._render_menu()

    def enter_playing(self) -> None:
        # Explicit play mode: VIDEO or SLIDESHOW.
        # No automatic fallback between them.

        # Clear idle footer overlay
        try:
            self.renderer.ipc.command("osd-overlay", 99, "ass-events", "", 1)
        except Exception:
            pass



        mode = str(self.cfg.get("play_mode", "VIDEO")).upper()

        # Refresh media lists once.
        self.videos = self._scan_videos()
        self.images = self._scan_images()

        if mode == "SLIDESHOW":
            self.videos = []
            self._start_slideshow()
            return


        # VIDEO mode
        if not self.videos:
            self.enter_idle()
            return

        self._set_state("PLAYING")

        # Keep using your existing current-video selection logic.
        path = self._current_video_path()
        if path is None:
            self.enter_idle()
            return

        self.renderer.ipc.show_text("", 1)
        loop_inf = (self.loop_mode == "SINGLE")

        # Apply remembered preferred language (if any) as soon as mpv loads tracks.
        # We do it after playback starts too, but setting intent here is useful.
        self._subtitle_changed_t = None

        #self._pending_preferred_lang = self._preferred_language_active(time.time())
        #keep undefined untill used
        self._pending_preferred_lang: Optional[str] = None



        self.renderer.play_video(path, loop_inf=loop_inf)


    # ─────────────────────────────────────────────────────────────────────────
    # DPMS spammer
    # ─────────────────────────────────────────────────────────────────────────
    def _dpms_spam_loop(self) -> None:
        t0 = time.time()
        log(f"DPMS spammer start interval={SPAM_DPMS_INTERVAL_S}s max_runtime={SPAM_DPMS_MAX_RUNTIME_S}")
        while not self._dpms_spam_stop.is_set():
            if SPAM_DPMS_MAX_RUNTIME_S > 0.0 and (time.time() - t0) > SPAM_DPMS_MAX_RUNTIME_S:
                break
            try:
                self.blanker.hw_blank_off()
            except Exception:
                pass
            time.sleep(max(0.1, float(SPAM_DPMS_INTERVAL_S)))
        log("DPMS spammer stop")

    def _dpms_spam_start(self) -> None:
        if self._dpms_spam_thr and self._dpms_spam_thr.is_alive():
            return
        self._dpms_spam_stop.clear()
        self._dpms_spam_thr = threading.Thread(target=self._dpms_spam_loop, daemon=True)
        self._dpms_spam_thr.start()

    def _dpms_spam_stop_now(self) -> None:
        self._dpms_spam_stop.set()

    # ─────────────────────────────────────────────────────────────────────────
    # Sleep/wake helpers
    # ─────────────────────────────────────────────────────────────────────────
    def _enter_soft_black(self) -> None:
        # Soft blank: keep HDMI alive, instant wake, no monitor "disconnect" OSD.
        if self.sleep_black_image.exists():
            self.renderer.load_idle(self.sleep_black_image, force=True)
            try:
                self.renderer.ipc.show_text("", 1)
            except Exception:
                pass
        else:
            self.renderer.force_black(True)

        self._sleep_soft_phase = True
        self._sleep_soft_started_t = self._now()
        self._slept_hardware_off = False
        log("SLEEP: entered soft-black phase")

    def _enter_hardware_powersave(self) -> None:
        # Transition from soft-black into real hardware blank.
        if self._slept_hardware_off:
            return
        if not self.blanker.is_hardware_mode():
            return

        self._sleep_soft_phase = False
        self._sleep_soft_started_t = None

        strat = str(HARDWARE_SLEEP_STRATEGY).upper()

        # Apply strategy BEFORE blanking (so nothing wakes DPMS afterwards).
        if strat == "KILL_MPV":
            try:
                self.renderer.stop()
                self._mpv_killed = True
            except Exception as e:
                log(f"KILL_MPV stop failed: {e!r}")
                self._mpv_killed = False

        elif strat == "SIGSTOP":
            try:
                self.renderer.freeze()
                self._mpv_frozen = True
            except Exception as e:
                log(f"SIGSTOP freeze failed: {e!r}")
                self._mpv_frozen = False

        elif strat == "SOFT_IPC":
            try:
                self.renderer.ipc_soft_sleep()
            except Exception as e:
                log(f"SOFT_IPC failed: {e!r}")

        elif strat == "SPAM_DPMS":
            pass

        elif strat == "IGNORE":
            pass
        else:
            log(f"Unknown HARDWARE_SLEEP_STRATEGY={HARDWARE_SLEEP_STRATEGY!r} -> IGNORE")

        self._slept_hardware_off = True
        self.blanker.hw_blank_off()

        if strat == "SPAM_DPMS":
            self._dpms_spam_start()

        log("SLEEP: transitioned to hardware powersave")

    # ─────────────────────────────────────────────────────────────────────────
    # Sleep/wake
    # ─────────────────────────────────────────────────────────────────────────
    def _sleep_display(self) -> None:
        self._set_state("SLEEP")
        self._dpms_spam_stop_now()

        # reset phase flags on entry
        self._sleep_soft_phase = False
        self._sleep_soft_started_t = None
        self._slept_hardware_off = False

        mode = self.blank_mode

        if mode == "NONE":
            return

        if mode == "WAYLAND":
            # Placeholder (menu option exists; no real solution yet)
            self.renderer.osd(["BLANK: WAYLAND", "Not implemented yet → using BLACK"], duration_ms=1500)
            mode = "BLACK"

        # If we *can* do hardware powersave, do soft-black first (if enabled) then transition later.
        if mode in ("XSET", "VCGENCMD") and float(self.powersave_after_s) > 0:
            self._enter_soft_black()
            return

        # Otherwise: current behaviour
        if mode in ("XSET", "VCGENCMD"):
            self._enter_hardware_powersave()
            return

        # BLACK (pure fake)
        self._enter_soft_black()

    def _wake_display(self) -> None:
        log(f"wake_display blank={self.blank_mode} slept_hardware={self._slept_hardware_off}")

        # Stop spam first (so it doesn't immediately turn it off again)
        self._dpms_spam_stop_now()

        # Clear soft-phase bookkeeping
        self._sleep_soft_phase = False
        self._sleep_soft_started_t = None

        if self._slept_hardware_off:
            self.blanker.hw_blank_on()
            time.sleep(float(self.monitor_wake_s))

        # Undo strategies
        strat = str(HARDWARE_SLEEP_STRATEGY).upper()

        if strat == "SIGSTOP" and self._mpv_frozen:
            try:
                self.renderer.thaw()
            except Exception as e:
                log(f"SIGSTOP thaw failed: {e!r}")
            self._mpv_frozen = False

        if strat == "KILL_MPV" and self._mpv_killed:
            # restart mpv so the rest of the app can render again
            try:
                self.renderer.start()
                self.renderer.load_idle(self._bg_path(), force=True)
            except Exception as e:
                log(f"KILL_MPV restart failed: {e!r}")
            self._mpv_killed = False

        if strat == "SOFT_IPC":
            try:
                self.renderer.ipc_soft_wake()
            except Exception:
                pass

        # Restore cosmetics if we forced black
        self.renderer.force_black(False)
        self._slept_hardware_off = False
        self.enter_idle()

    def _passkey_feed(self, sym: str) -> None:
        want = self.passkey
        buf = self.passkey_buf + sym

        if want.startswith(buf):
            self.passkey_buf = buf
        else:
            self.passkey_buf = sym if want.startswith(sym) else ""

        if self.passkey_buf == want:
            self.enter_menu()

    def _persist_cfg(self) -> None:
        self.cfg["active_video"] = int(self.active_video)
        self.cfg["loop_mode"] = self.loop_mode

        self.cfg["blank_mode"] = self.blank_mode
        self.cfg["idle_timeout_s"] = float(self.idle_timeout_s)
        self.cfg["monitor_wake_s"] = float(self.monitor_wake_s)

        # NEW
        self.cfg["powersave_after_s"] = float(self.powersave_after_s)

        self.cfg["color_preset"] = self.color_preset
        self.cfg["color_saturation"] = float(self.color_saturation)
        self.cfg["color_brightness"] = float(self.color_brightness)
        self.cfg["color_gamma"] = float(self.color_gamma)
        self.cfg["color_contrast"] = float(self.color_contrast)

        save_config(self.cfg)

    def _apply_color(self) -> None:
        self.renderer.cfg = self.cfg
        self.renderer.set_color(
            self.color_preset,
            self.color_saturation,
            self.color_brightness,
            self.color_contrast,
            self.color_gamma,
        )

    def _cycle_background(self) -> None:
        self.images = self._scan_images()
        cur = self.cfg.get("ui_background_image")
        options: list[Optional[str]] = [None] + [str(p) for p in self.images]

        try:
            pos = options.index(cur)  # type: ignore[arg-type]
        except Exception:
            pos = 0

        nxt = options[(pos + 1) % len(options)]
        self.cfg["ui_background_image"] = nxt
        self._persist_cfg()
        self.renderer.load_idle(self._bg_path(), force=True)

    def _cycle_timeout(self) -> None:
        cur = int(round(float(self.idle_timeout_s)))
        nearest = min(self.TIMEOUT_CHOICES, key=lambda x: abs(x - cur))
        i = self.TIMEOUT_CHOICES.index(nearest)
        nxt = self.TIMEOUT_CHOICES[(i + 1) % len(self.TIMEOUT_CHOICES)]
        self.idle_timeout_s = float(nxt)
        self._persist_cfg()

    def _cycle_powersave_after(self) -> None:
        cur = int(round(float(self.powersave_after_s)))
        nearest = min(self.POWERSAVE_CHOICES, key=lambda x: abs(x - cur))
        i = self.POWERSAVE_CHOICES.index(nearest)
        nxt = self.POWERSAVE_CHOICES[(i + 1) % len(self.POWERSAVE_CHOICES)]
        self.powersave_after_s = float(nxt)
        self._persist_cfg()

    def _menu_select(self) -> None:
        idx = self.menu_index

        if idx == 0:  # LOOP
            i = self.LOOP_LABELS.index(self.loop_mode) if self.loop_mode in self.LOOP_LABELS else 0
            self.loop_mode = self.LOOP_LABELS[(i + 1) % len(self.LOOP_LABELS)]
            self._persist_cfg()
            self._render_menu()
            return

        if idx == 1:  # VIDEO
            if self.videos:
                self.active_video = (self.active_video + 1) % len(self.videos)
                self._persist_cfg()
            self._render_menu()
            return

        if idx == 2:  # BG
            self._cycle_background()
            self._render_menu()
            return

        if idx == 3:  # COLOR preset
            i = self.COLOR_LABELS.index(self.color_preset) if self.color_preset in self.COLOR_LABELS else 0
            self.color_preset = self.COLOR_LABELS[(i + 1) % len(self.COLOR_LABELS)]
            self._persist_cfg()
            self._apply_color()
            self._render_menu()
            return

        if idx == 4 and self.color_preset == "CUSTOM":  # SAT
            steps = [0.0, 0.35, 0.50, 0.75, 0.90, 1.00, 1.10, 1.25, 1.35, 1.50, 1.70]
            cur = min(steps, key=lambda x: abs(x - self.color_saturation))
            j = steps.index(cur)
            self.color_saturation = steps[(j + 1) % len(steps)]
            self._persist_cfg()
            self._apply_color()
            self._render_menu()
            return

        if idx == 5 and self.color_preset == "CUSTOM":  # BRI
            steps = [-0.25, -0.10, -0.05, 0.00, 0.03, 0.06, 0.10, 0.25]
            cur = min(steps, key=lambda x: abs(x - self.color_brightness))
            j = steps.index(cur)
            self.color_brightness = steps[(j + 1) % len(steps)]
            self._persist_cfg()
            self._apply_color()
            self._render_menu()
            return

        if idx == 6 and self.color_preset == "CUSTOM":  # CON
            steps = [0.85, 0.90, 0.95, 1.00, 1.05, 1.10, 1.15, 1.20, 1.30]
            cur = min(steps, key=lambda x: abs(x - self.color_contrast))
            j = steps.index(cur)
            self.color_contrast = steps[(j + 1) % len(steps)]
            self._persist_cfg()
            self._apply_color()
            self._render_menu()
            return

        if idx == 7 and self.color_preset == "CUSTOM":  # GAM
            steps = [0.85, 0.90, 0.95, 1.00, 1.05, 1.10, 1.20, 1.5]
            cur = min(steps, key=lambda x: abs(x - self.color_gamma))
            j = steps.index(cur)
            self.color_gamma = steps[(j + 1) % len(steps)]
            self._persist_cfg()
            self._apply_color()
            self._render_menu()
            return

        if idx == 8:  # BLANK mode
            i = self.BLANK_LABELS.index(self.blank_mode) if self.blank_mode in self.BLANK_LABELS else 0
            self.blank_mode = self.BLANK_LABELS[(i + 1) % len(self.BLANK_LABELS)]
            self.cfg["blank_mode"] = self.blank_mode
            self._persist_cfg()
            self._render_menu()
            return

        if idx == 9:  # POWERSAVE AFTER
            self._cycle_powersave_after()
            self._render_menu()
            return

        if idx == 10:  # TIMEOUT
            self._cycle_timeout()
            self._render_menu()
            return

        if idx == 11:  # BLANK NOW
            self._sleep_display()
            return

        # EXIT
        self.enter_idle()

    def _handle_button_down(self, t: float) -> None:
        if not self._event_ok(t, "down"):
            return
        self.press_down_t = t
        self.last_activity = t

    def _handle_button_up(self, t: float) -> None:
        if not self._event_ok(t, "up"):
            return
        if self.press_down_t is None:
            return

        dur = max(0.0, t - self.press_down_t)
        self.press_down_t = None
        self.last_activity = t

        is_long = self._is_long(dur)

        if self.state == "SLEEP":
            self._wake_display()
            if not is_long:
                self.enter_playing()
            else:
                self.enter_passkey()
            return

        if self.state == "PLAYING":
            if is_long:
                self.renderer.stop_video()
                self.enter_idle()
                return

            # short press: if subtitle was changed recently, restart from beginning
            if self._subtitle_changed_t is not None:
                if (t - self._subtitle_changed_t) <= float(self.subtitle_restart_window_s):
                    try:
                        self.renderer.ipc.command("seek", 0, "absolute")
                        self.renderer.ipc.show_text("Restart", 800)
                    except Exception:
                        # fallback: reload file
                        path = self._current_video_path()
                        if path is not None:
                            loop_inf = (self.loop_mode == "SINGLE")
                            self.renderer.play_video(path, loop_inf=loop_inf)
                    self._subtitle_changed_t = None
            return


        if self.state == "IDLE":
            if not is_long:
                self.enter_playing()
            else:
                self.enter_passkey()
            return

        if self.state == "PASSKEY":
            sym = "-" if is_long else "."
            self._passkey_feed(sym)
            self.passkey_last_input_t = t
            self._render_passkey()
            return

        if self.state == "MENU":
            if not is_long:
                self.menu_index = (self.menu_index + 1) % len(self._menu_items())
                self._render_menu()
            else:
                self._menu_select()
            return

    def _handle_mpv_events(self) -> None:
        while True:
            try:
                ev = self.renderer.ipc.events.get_nowait()
            except queue.Empty:
                break

            et = ev.get("event")

            # ─────────────────────────────────────────────────────────────
            # Apply preferred subtitle once mpv has loaded tracks for the file.
            # This MUST run on "file-loaded" (not "end-file").
            # ─────────────────────────────────────────────────────────────
            if et == "file-loaded":
                if (
                    self._pending_preferred_lang is not None
                    and self.state == "PLAYING"
                    and (not self._is_slideshow_mode())
                ):
                    try:
                        self._apply_preferred_subtitle_now()
                    finally:
                        # Clear regardless; if preferred lang isn't available, we don't keep retrying forever.
                        self._pending_preferred_lang = None
                continue

            # We only care about end-of-playback for looping/idle decisions.
            if et != "end-file":
                continue

            reason = ev.get("reason")
            if self.state != "PLAYING" or reason != "eof":
                continue

            # Slideshow: after each displayed image, keep going.
            if self._is_slideshow_mode():
                self._start_slideshow()
                continue

            # Expo mode: treat OFF like ALL (continuous)
            effective_loop = self.loop_mode
            if self.expo_mode and self.loop_mode == "OFF":
                effective_loop = "ALL"

            if effective_loop == "ALL":
                if self.videos:
                    self.active_video = (self.active_video + 1) % len(self.videos)
                    self._persist_cfg()
                self.enter_playing()

            elif effective_loop == "RANDOM":
                if self.videos:
                    if len(self.videos) == 1:
                        self.active_video = 0
                    else:
                        cur = self.active_video
                        nxt = cur
                        for _ in range(10):
                            nxt = random.randrange(0, len(self.videos))
                            if nxt != cur:
                                break
                        self.active_video = nxt
                    self._persist_cfg()
                self.enter_playing()

            else:
                self.enter_idle()





    def _cleanup_on_exit(self) -> None:
        # Ensure we never leave the system “stuck”.
        try:
            self._dpms_spam_stop_now()
        except Exception:
            pass
        try:
            if self._mpv_frozen:
                self.renderer.thaw()
                self._mpv_frozen = False
        except Exception:
            pass
        try:
            if self._slept_hardware_off:
                self.blanker.hw_blank_on()
                self._slept_hardware_off = False
        except Exception:
            pass
        try:
            if self._mpv_killed:
                self._mpv_killed = False
        except Exception:
            pass
        try:
            self.renderer.stop()
        except Exception:
            pass

    def _handle_config_changed(self) -> None:
        log("CONFIG_CHANGED received → reloading config")

        new_cfg = load_config()
        self.cfg = new_cfg
        self.blanker.cfg = new_cfg
        self.renderer.cfg = new_cfg


        self.videos = self._scan_videos()
        self.images = self._scan_images()

        # Active video index from config (clamp)
        try:
            self.active_video = int(new_cfg.get("active_video", self.active_video))
        except Exception:
            pass
        if self.videos:
            self.active_video %= len(self.videos)
        else:
            self.active_video = 0

        # Subtitles: default mode may have changed
        self.subtitle_default_on = bool(new_cfg.get("subtitle_default_on", getattr(self, "subtitle_default_on", False)))


        # Paths (optional but usually desired)
        self.video_dir = Path(str(new_cfg.get("video_dir", DEFAULT_CONFIG["video_dir"]))).expanduser().resolve()
        self.image_dir = Path(str(new_cfg.get("image_dir", DEFAULT_CONFIG["image_dir"]))).expanduser()

        # reload simple runtime values
        self.loop_mode = str(new_cfg.get("loop_mode", self.loop_mode)).upper()
        self.idle_timeout_s = float(new_cfg.get("idle_timeout_s", self.idle_timeout_s))
        self.powersave_after_s = float(new_cfg.get("powersave_after_s", self.powersave_after_s))
        self.blank_mode = str(new_cfg.get("blank_mode", self.blank_mode)).upper()

        # feature flags
        self.expo_mode = bool(new_cfg.get("expo_mode", self.expo_mode))
        self.slideshow_interval_s = float(new_cfg.get("slideshow_interval_s", self.slideshow_interval_s))
        self.screensaver_window_enable = bool(new_cfg.get("screensaver_window_enable", self.screensaver_window_enable))
        self.screensaver_start_hhmm = str(new_cfg.get("screensaver_start_hhmm", self.screensaver_start_hhmm))
        self.screensaver_end_hhmm = str(new_cfg.get("screensaver_end_hhmm", self.screensaver_end_hhmm))

        # color + visuals are safe to reapply live
        self.color_preset = str(new_cfg.get("color_preset", self.color_preset)).upper()
        self.color_saturation = float(new_cfg.get("color_saturation", self.color_saturation))
        self.color_brightness = float(new_cfg.get("color_brightness", self.color_brightness))
        self.color_gamma = float(new_cfg.get("color_gamma", self.color_gamma))
        self.color_contrast = float(new_cfg.get("color_contrast", self.color_contrast))
        self._apply_color()

        # UI background may have changed
        self.renderer.load_idle(self._bg_path(), force=True)

        # stay in current state; do not auto-play


    def run(self) -> None:
        log(f"run() video_dir={self.video_dir} image_dir={self.image_dir}")

        if not self.video_dir.exists():
            print(f"WARNING: video_dir does not exist: {self.video_dir}", file=sys.stderr)
        if not self.image_dir.exists():
            print(f"WARNING: image_dir does not exist: {self.image_dir}", file=sys.stderr)

        self.videos = self._scan_videos()
        self.images = self._scan_images()
        if self.videos:
            self.active_video %= len(self.videos)
        else:
            self.active_video = 0

        #scan once for subtitles
        self._merge_subtitle_preferences_startup()

        self.renderer.start()
        self.renderer.load_idle(self._bg_path(), force=True)
        self.enter_idle()

        try:
            while True:
                if self.state != "SLEEP" and not self.renderer.is_alive():
                    log("ERROR: mpv process is not alive; exiting")
                    raise SystemExit(2)

                while True:
                    ev: Optional[BtnEvent] = None
                    try:
                        ev = self.io.q.get_nowait()
                    except queue.Empty:
                        pass

                    if ev is None:
                        try:
                            ev = self.sub_io.q.get_nowait()
                            ev.kind = "sub_" + ev.kind   # tag source
                        except queue.Empty:
                            break

                    if ev.kind == "config":
                        self._handle_config_changed()

                    elif ev.kind == "down":
                        self._handle_button_down(ev.t)

                    elif ev.kind == "up":
                        self._handle_button_up(ev.t)

                    elif ev.kind == "sub_down":
                        # we only act on release; keep symmetry
                        pass

                    elif ev.kind == "sub_up":
                        self._handle_subtitle_press(ev.t)


                # Only read mpv events when mpv is expected to be responsive
                if HARDWARE_SLEEP_STRATEGY.upper() != "SIGSTOP" or not self._mpv_frozen:
                    self._handle_mpv_events()

                now = self._now()

                if self.state == "IDLE" and (now - self.idle_since) >= float(self.idle_timeout_s):
                    if self.loop_mode != "OFF" or self.expo_mode:
                        log("IDLE timeout -> auto start playing (loop or expo)")
                        self.enter_playing()
                    else:
                        # NEW: only allow screensaver (sleep/blank) in configured time window
                        if self._screensaver_allowed_now():
                            self._sleep_display()
                        else:
                            # Stay idle; just reset the idle timer so we don't spin.
                            self.idle_since = now

                # slideshow tick (advance to next image after interval)
                if self.state == "PLAYING" and self._is_slideshow_mode():
                    if self._next_slide_t is not None and now >= self._next_slide_t:
                        self._start_slideshow()




                # NEW: if we are in SLEEP soft-black phase, transition into hardware powersave after N seconds
                if (
                    self.state == "SLEEP"
                    and self._sleep_soft_phase
                    and self.blanker.is_hardware_mode()
                    and float(self.powersave_after_s) > 0.0
                    and self._sleep_soft_started_t is not None
                    and (now - self._sleep_soft_started_t) >= float(self.powersave_after_s)
                ):
                    self._enter_hardware_powersave()

                if self.state == "PASSKEY":
                    t_last = self.passkey_last_input_t or self.passkey_started_t or now
                    if (now - t_last) >= self.passkey_timeout_s:
                        self.enter_playing()

                if self.state == "MENU" and (now - self.last_activity) >= self.menu_timeout_s:
                    self.enter_idle()

                # Avoid any OSD refresh while sleeping (keep it dark)
                if self.state == "MENU":
                    self._render_menu()
                elif self.state == "PASSKEY":
                    self._render_passkey()

                time.sleep(0.05)
        finally:
            self._cleanup_on_exit()


def main() -> None:
    cfg = load_config()
    app = App(cfg)
    app.run()


if __name__ == "__main__":
    main()
