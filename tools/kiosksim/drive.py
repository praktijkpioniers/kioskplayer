#!/usr/bin/env python3
"""
Drive the kiosksim mpv over IPC.

    drive.py <level> <idle|video> [delay ...]   load the Halloween theme at a level, screenshot
                                                after each delay (shot0.png, shot1.png, ...)
    drive.py key <key> [...]                    press keys (preview keys: 1-9 0 v t f w, SPACE)
"""
import json
import os
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

DIR = Path(os.environ.get("KIOSKSIM_DIR", "/tmp/kiosksim"))


class Conn:
    def __init__(self, path: Path = DIR / "mpv.sock"):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(str(path))
        self.f = self.s.makefile("r")
        self.n = 0

    def cmd(self, args: list):
        self.n += 1
        self.s.sendall((json.dumps({"command": args, "request_id": self.n}) + "\n").encode())
        while True:
            r = json.loads(self.f.readline())
            if r.get("request_id") == self.n:
                return r.get("data")

    def prop(self, name: str):
        return self.cmd(["get_property", name])

    def shot(self, name: str):
        self.cmd(["screenshot-to-file", str(DIR / name), "window"])


def main() -> None:
    c = Conn()
    if sys.argv[1] == "key":
        for k in sys.argv[2:]:
            c.cmd(["keypress", k])
        return
    import themes
    level, mode = int(sys.argv[1]), sys.argv[2]
    w, h = c.prop("osd-width"), c.prop("osd-height")
    man = themes.build_manifest("halloween", level, w, h)
    wm = themes.build_watermark({"watermark_image": "themes/watermark/default.png"}, h)
    c.cmd(["script-message", "watermark", json.dumps(wm)])
    c.cmd(["script-message", "theme-load", str(man)])
    c.cmd(["script-message", "theme-mode", mode])
    for k, delay in enumerate(sys.argv[3:]):
        time.sleep(float(delay))
        c.shot(f"shot{k}.png")


if __name__ == "__main__":
    main()
