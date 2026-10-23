#!/usr/bin/env python3
"""
Pull curated artwork from the homeai image service (plexus) into a theme folder.

    python3 tools/fetch_art.py kiosk-halloween themes/halloween [--state picked] [--dry-run]

Every image the user marked "picked" on the curation page is saved as <name>.png
(<name>_2.png, ... when several of one name are picked), trimmed to its alpha bounding box.
The API key is read from ~/.config/homeai/key (never commit it).
"""
import argparse
import io
import json
import os
import urllib.request
from pathlib import Path

from PIL import Image

BASE = os.environ.get("HOMEAI_URL", "http://100.92.233.10:8095")
KEY = Path(os.environ.get("HOMEAI_KEY_FILE", "~/.config/homeai/key")).expanduser()


def get(path: str) -> bytes:
    req = urllib.request.Request(BASE + path, headers={"Authorization": "Bearer " + KEY.read_text().strip()})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("project")
    ap.add_argument("theme_dir", type=Path)
    ap.add_argument("--state", default="picked")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    data = json.loads(get(f"/images?project={a.project}&state={a.state}"))
    images = data.get("images", data) if isinstance(data, dict) else data
    count: dict[str, int] = {}
    images = [i for i in images if i.get("gen_state", "done") == "done"]
    for im in sorted(images, key=lambda i: (i.get("name", ""), str(i.get("id")))):
        name = im.get("name") or im["id"]
        count[name] = count.get(name, 0) + 1
        out = a.theme_dir / (f"{name}.png" if count[name] == 1 else f"{name}_{count[name]}.png")
        print(f"{im['id']}  {name:16s} -> {out}" + (f"   note: {im['note']}" if im.get("note") else ""))
        if a.dry_run:
            continue
        pic = Image.open(io.BytesIO(get(f"/images/{im['id']}.png"))).convert("RGBA")
        box = pic.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
        if box:
            pic = pic.crop(box)
        pic.save(out, optimize=True)


if __name__ == "__main__":
    main()
