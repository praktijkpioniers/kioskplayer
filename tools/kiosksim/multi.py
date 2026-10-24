#!/usr/bin/env python3
"""
Several kiosks side by side on this desktop, as one room: each its own mpv window with the theme
engine, its own room-bus node (UDP over 127.0.0.1), and the same ThemeRoom bridge the player uses,
so animations move from one window to the next.

    multi.py [n=4] [level=8] [--gap 16] [--mode idle|video] [--cols 2]

Keys go to one window: python3 tools/kiosksim/multi.py key <i> <key> ...   (b = a flyer now)
Screenshot of the whole row:   python3 tools/kiosksim/multi.py shot <file.png>
Windows: /tmp/kiosksim/k<i>/ (socket, log). Ctrl+C closes them all.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(HERE))
import drive  # noqa: E402
import roombus  # noqa: E402
import themes  # noqa: E402

BASE_DIR = Path(os.environ.get("KIOSKSIM_DIR", "/tmp/kiosksim"))
PORT = 47900
SCREEN_W, SCREEN_H = 1920, 1080


def geometry(i, n, cols):
    """Window i of n in a grid of cols columns filling the screen (read like text: the room's
    left-to-right order goes on at the start of the next row)."""
    gap = 4
    rows = -(-n // cols)
    w = min((SCREEN_W - gap * (cols + 1)) // cols, ((SCREEN_H - gap * (rows + 1)) // rows) * 16 // 9)
    h = w * 9 // 16
    x0 = (SCREEN_W - cols * w - (cols - 1) * gap) // 2
    y0 = (SCREEN_H - rows * h - (rows - 1) * gap) // 2
    return w, h, x0 + (i % cols) * (w + gap), y0 + (i // cols) * (h + gap)


class Kiosk:
    def __init__(self, i, n, gap_px, cols):
        self.i, self.n = i, n
        self.dir = BASE_DIR / f"k{i}"
        self.dir.mkdir(parents=True, exist_ok=True)
        w, h, x, y = geometry(i, n, cols)
        env = dict(os.environ, KIOSKSIM_DIR=str(self.dir), KIOSKSIM_GEOMETRY=f"{w}x{h}+{x}+{y}",
                   KIOSKSIM_TITLE=f"kiosk{i}")
        self.proc = subprocess.Popen([str(HERE / "run.sh")], env=env, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, start_new_session=True)
        sock = self.dir / "mpv.sock"
        for _ in range(100):
            if sock.exists():
                try:
                    self.conn = drive.Conn(sock)
                    break
                except OSError:
                    pass
            time.sleep(0.1)
        else:
            raise SystemExit(f"kiosk{i}: mpv did not start")
        self.lock = threading.Lock()
        self.level = self.mode = None
        peers = [f"127.0.0.1:{PORT + j}" for j in range(n) if j != i]
        self.bus = roombus.Bus("sim", node=f"kiosk{i}", port=PORT + i,
                               transports=[{"udp-peers": peers}]).start()
        self.room = themes.ThemeRoom(self.bus, [f"kiosk{j}" for j in range(n)], gap_px, send=self.cmd,
                                     log=lambda m: print(f"kiosk{i}: {m}"))
        threading.Thread(target=self._events, args=(sock,), daemon=True).start()

    def cmd(self, *args):
        with self.lock:
            return self.conn.cmd(list(args))

    def _events(self, sock):
        # a second connection that only listens: client-message = script-message from the engine
        s = socket.socket(socket.AF_UNIX)
        s.connect(str(sock))
        for line in s.makefile("r"):
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("event") == "client-message":
                args = ev.get("args") or []
                if args and args[0] == "theme-resized" and self.level is not None:
                    threading.Thread(target=self.load, args=(self.level, self.mode), daemon=True).start()
                elif len(args) >= 2 and str(args[0]).startswith("theme-room-"):
                    self.room.from_engine(str(args[0]), str(args[1]))

    def load(self, level, mode):
        self.level, self.mode = level, mode
        for _ in range(50):
            w, h = self.cmd("get_property", "osd-width"), self.cmd("get_property", "osd-height")
            if w and h:
                break
            time.sleep(0.1)
        man = themes.build_manifest("halloween", level, w, h)
        wm = themes.build_watermark({"watermark_image": "themes/watermark/default.png"}, h)
        self.cmd("script-message", "watermark", json.dumps(wm))
        self.room.announce()
        self.cmd("script-message", "theme-load", str(man))
        self.cmd("script-message", "theme-mode", mode)


def shot(path):
    """The whole row in one picture (each window's own screenshot, pasted side by side)."""
    from PIL import Image
    ims = []
    for d in sorted(BASE_DIR.glob("k[0-9]*"), key=lambda p: int(p.name[1:])):
        if (d / "mpv.sock").exists():
            try:
                c = drive.Conn(d / "mpv.sock")
                c.cmd(["screenshot-to-file", str(d / "row.png"), "window"])
                ims.append(Image.open(d / "row.png"))
            except OSError:
                pass
    if not ims:
        raise SystemExit("no kiosks running")
    gap = 4
    out = Image.new("RGB", (sum(im.width for im in ims) + gap * (len(ims) - 1), max(im.height for im in ims)), "black")
    x = 0
    for im in ims:
        out.paste(im, (x, 0))
        x += im.width + gap
    out.save(path)
    print(path)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "key":
        c = drive.Conn(BASE_DIR / f"k{int(sys.argv[2])}" / "mpv.sock")
        for k in sys.argv[3:]:
            c.cmd(["keypress", k])
        return
    if len(sys.argv) > 1 and sys.argv[1] == "shot":
        shot(sys.argv[2] if len(sys.argv) > 2 else str(BASE_DIR / "row.png"))
        return
    ap = argparse.ArgumentParser()
    ap.add_argument("n", nargs="?", type=int, default=4)
    ap.add_argument("level", nargs="?", type=int, default=8)
    ap.add_argument("--gap", type=float, default=16, help="pixels (at 1080p) between two screens")
    ap.add_argument("--mode", default="idle")
    ap.add_argument("--cols", type=int, default=2, help="windows per row (n for one row)")
    a = ap.parse_args()
    kiosks = [Kiosk(i, a.n, a.gap, max(1, min(a.cols, a.n))) for i in range(a.n)]
    for k in kiosks:
        k.load(a.level, a.mode)
    print(f"{a.n} kiosks, level {a.level}; 'multi.py key 0 b' sends a flyer. Ctrl+C to stop.")
    try:
        while all(k.proc.poll() is None for k in kiosks):
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass
    finally:
        for k in kiosks:
            k.proc.terminate()


if __name__ == "__main__":
    main()
