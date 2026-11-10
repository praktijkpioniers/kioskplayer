#!/usr/bin/env python3
# Writes the Piet colour variants (recipes/piet_b.json, piet_c.json, ...) from recipes/piet.json:
# the same Piet with other doublet / hose colours, hair and skin, and maybe a sack on the back.
#   python3 tools/bake/piet_variants.py   then bake each with kaykit.py (see piet.json)
import copy, json
from pathlib import Path

R = Path(__file__).resolve().parent / "recipes"
BASE_MAIN, BASE_ALT = "#7b3fa6", "#f2c230"          # (piet.json: purple and yellow)

VARIANTS = {
    # name: main colour, its shade, second colour, hair, skin, sack
    "piet_b": dict(main="#1f5fbf", shade="#16438a", alt="#f08a24", hair="#17120f", skin="#a8714b", sack=True),
    "piet_c": dict(main="#2e8a3e", shade="#1f6029", alt="#e85a9a", hair="#8a3b1c", skin="#f0c7a8", sack=False),
    "piet_d": dict(main="#169c9c", shade="#0f6e6e", alt="#f2c230", hair="#5a3a22", skin="#d29a72", sack=False),
}

def main():
    base = json.loads((R / "piet.json").read_text())
    for name, v in VARIANTS.items():
        r = copy.deepcopy(base)
        r["_doc"] = f"Written by tools/bake/piet_variants.py from piet.json - edit that, not this. {base['_doc']}"
        t = r["recolor"]["rogue_texture"]
        for k, c in t.items():
            if c == BASE_MAIN: t[k] = v["main"]
            elif c == BASE_ALT: t[k] = v["alt"]
            elif c in ("#5c2c80",): t[k] = v["shade"]
        t["0,0"], t["1,0"], t["3,0"] = v["skin"], v["hair"], v["hair"]
        for p in r["props"]:
            if p["color"] == BASE_MAIN: p["color"] = v["main"]
            elif p["color"] == BASE_ALT: p["color"] = v["alt"]
        if v["sack"]:
            r["props"].append({"bone": "chest", "shape": "sphere", "at": [0, 0.42, 0.1],
                               "size": [0.36, 0.3, 0.42], "color": "#b98d5a", "name": "sack"})
            r["props"].append({"bone": "chest", "shape": "cylinder", "at": [0, 0.4, 0.5],
                               "size": [0.1, 0.12], "axis": "z", "color": "#8a6538", "name": "sack_neck"})
        (R / f"{name}.json").write_text(json.dumps(r, indent=1) + "\n")
        print("wrote", name)

if __name__ == "__main__":
    main()
