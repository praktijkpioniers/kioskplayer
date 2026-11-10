#!/usr/bin/env python3
"""St Maarten: St Martin (four cloak stages) and the beggars - recipes for kaykit.py, and bake.

    python3 tools/bake/martin.py recipes          # tools/bake/recipes/stmaarten/{martin_N,beggar_*}.json
    python3 tools/bake/martin.py bake [name ...]  # -> themes/stmaarten/anim/<name>

St Martin: a Roman soldier (the KayKit Knight, armour turned bronze, a helmet with a red crest made of
props) with a long red cloak (the Knight's cape stretched, "mesh_scale"). martin_0 full cloak,
martin_1 half, martin_2 a quarter, martin_3 none. Clips: walk, idle, turn_front, turn_side, cut (the
sword drawn: a slice), give (reaching out). martin_3 also has the beggar's clips: with no cloak he
sits down in the cold and is one of the beggars himself (the next St Martin finds him).
Beggars: sit_down, sit (huddled), reach (taking what is given), the red piece of cloak round them
as a poncho (the *_w clips: sit_w, stand_w, walk_w, idle_w), stand (up, cold), walk, idle.
"""
import json, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RDIR = os.path.join(HERE, "recipes", "stmaarten")
OUT = os.path.join(ROOT, "themes", "stmaarten", "anim")
G = "../../models/kaykit-adventurers/addons/kaykit_character_pack_adventures/Characters/gltf/"
PYLIB = os.path.expanduser("~/assets-src/pylib")
RED = "#c4232b"

# the piece of cloak a beggar gets: the Knight's cape (red) on his back and a shawl round his shoulders;
# in the *_w clips only
PONCHO = [{"name": "poncho", "bone": "chest", "shape": "cone", "at": [0, 0, 0.1], "size": [0.5, 0.55], "color": RED}]
CAPE_PART = {"model": G + "Knight.glb", "meshes": ["Knight_Cape"]}
SIT_ARM = {"upperarm.r": [0, 0, 60], "lowerarm.r": [0, 0, 10]}


def beggar_clips(walk="Walking_C", walk_speed=0.7):
    W = ["poncho", "Knight_Cape"]          # (dropped where not wrapped)
    return {
        "walk": {"action": walk, "yaw": 90, "loop": True, "stride": "auto", "step": 3, "speed": walk_speed, "drop": W},
        "idle": {"action": "Idle", "yaw": 15, "loop": True, "frames": 8, "step": 5, "drop": W},
        "sit_down": {"action": "Sit_Floor_Down", "yaw": 40, "step": 3, "drop": W},
        "sit": {"action": "Sit_Floor_Idle", "yaw": 40, "loop": True, "frames": 8, "step": 5, "drop": W,
                "turn": {"head": [12, 0, 0], "spine": [10, 0, 0]}},
        "reach": {"action": "Sit_Floor_Idle", "yaw": 40, "frames": 8, "step": 3, "drop": W, "turn": SIT_ARM, "ramp": [0, 1]},
        "stand": {"action": "Sit_Floor_StandUp", "yaw": 40, "step": 3, "drop": W},
        "sit_w": {"action": "Sit_Floor_Idle", "yaw": 30, "loop": True, "frames": 8, "step": 5},
        "stand_w": {"action": "Sit_Floor_StandUp", "yaw": 40, "step": 3},
        "walk_w": {"action": "Walking_A", "yaw": 90, "loop": True, "stride": "auto", "step": 3},
        "idle_w": {"action": "Cheer", "yaw": 15, "step": 3},
    }


def martin(stage):
    cape = {0: [1.5, 2.2, 2.5], 1: [1.4, 1.9, 1.55], 2: [1.25, 1.5, 0.8]}.get(stage)
    hide = ["Icosphere", "1H_Sword", "2H_Sword", "Badge_Shield", "Rectangle_Shield", "Round_Shield", "Spike_Shield",
            "Knight_Helmet"]
    if cape is None:
        hide.append("Knight_Cape")
    props = [
        # a bronze helmet with a red crest, cheek guards
        {"bone": "head", "shape": "sphere", "at": [0, 0.06, 0.8], "size": [0.56, 0.56, 0.36], "color": "#c8964a"},
        {"bone": "head", "shape": "cube", "at": [0, 0.08, 1.16], "size": [0.1, 0.7, 0.22], "color": "#c4232b"},
        {"bone": "head", "shape": "cylinder", "at": [0, 0.06, 0.6], "size": [0.565, 0.07], "axis": "z", "color": "#a87a38"},
        # the sword: a blade in the right hand, only out for the cut
        {"name": "blade", "bone": "handslot.r", "shape": "cube", "at": [0, -0.42, 0], "size": [0.05, 0.75, 0.11], "color": "#d8dde4"},
        {"name": "blade_guard", "bone": "handslot.r", "shape": "cube", "at": [0, -0.05, 0], "size": [0.28, 0.06, 0.08], "color": "#a87a38"},
    ]
    clips = {
        "walk": {"action": "Walking_A", "yaw": 90, "loop": True, "stride": "auto", "step": 3},
        "idle": {"action": "Idle", "yaw": 20, "loop": True, "frames": 8, "step": 5},
        "turn_front": {"action": "Idle", "yaw": [90, 30], "frames": 4},
        "turn_side": {"action": "Idle", "yaw": [30, 90], "frames": 4},
        "cut": {"action": "1H_Melee_Attack_Slice_Diagonal", "yaw": 55, "step": 2, "show": []},
        "give": {"action": "Idle", "yaw": 55, "frames": 10, "step": 3, "turn": {"upperarm.r": [0, 0, 55]}, "ramp": [0, 1]},
    }
    for n, c in clips.items():
        if n != "cut":
            c["drop"] = ["blade"]
    poncho = []
    if stage == 3:                       # no cloak: he is one of the beggars now
        for n, c in beggar_clips(walk="Walking_A", walk_speed=0.8).items():
            c = dict(c)
            c["drop"] = sorted(set(c.get("drop", []) + ["blade"]))
            if n.endswith("_w"):
                c["show"] = ["Knight_Cape"]     # (the piece the next St Martin gave him)
            clips[n] = c
        poncho = PONCHO
        # (no helmet while sitting in the cold? he keeps it: you see it's him)
    return {
        "_doc": f"St Martin, cloak stage {stage} (0 full .. 3 none); generated by tools/bake/martin.py - edit there",
        "model": G + "Knight.glb", "hide": hide, "outline": 0.01, "props_rest": True,
        "recolor": {"knight_texture": {"2,1": "#b8863e", "3,1": "#a87a38", "1,2": "#c8964a", "7,0": "#a87a38",
                                        "3,0": "#c8964a", "1,1": "#e8d8b8", "0,2": "#e8d8b8", "4,1": "#e0b040"}},
        "mesh_scale": {"Knight_Cape": cape or [1.3, 1.6, 1.5]},
        "frame": {"x": [-1.5, 1.5], "h": 2.9},
        "props": props + poncho, "clips": clips}


BEGGARS = {
    # name: (body glb, face part or None, hide, recolor, extra props)
    "beggar_old": ("Rogue", ("Barbarian", "Barbarian_Head"), ["Rogue_Head"],
                   {"rogue_texture": {"0,1": "#6b5a48", "1,1": "#5e5040", "1,2": "#7a6a55", "0,0": "#e8c0a0"},
                    "barbarian_texture": {"0,0": "#e8c0a0"}},
                   [{"bone": "chest", "shape": "cube", "at": [0.2, -0.36, 0.0], "size": [0.18, 0.04, 0.16], "color": "#8a7a5a"}]),
    "beggar_woman": ("Mage", ("Rogue_Hooded", "Rogue_Head_Hooded"), ["Mage_Head"],
                     {"mage_texture": {"0,1": "#5a5f6a", "1,1": "#4e535e", "7,1": "#6a6e78", "2,1": "#6a5a50",
                                       "1,2": "#6a5a50", "0,0": "#d9a074"},
                      "rogue_texture": {"0,1": "#7a6e58", "1,1": "#6e6450", "1,2": "#7a6e58", "0,0": "#d9a074"}},
                     [{"bone": "hips", "shape": "cube", "at": [-0.22, -0.4, -0.05], "size": [0.2, 0.04, 0.18], "color": "#7a6e58"}]),
    "beggar_young": ("Rogue", ("Knight", "Knight_Head"), ["Rogue_Head"],
                     {"rogue_texture": {"0,1": "#5a6650", "1,1": "#4e5a46", "1,2": "#66705a", "0,0": "#a8704a"},
                      "knight_texture": {"0,0": "#a8704a"}},
                     [{"bone": "chest", "shape": "cube", "at": [-0.18, -0.37, 0.05], "size": [0.16, 0.04, 0.14], "color": "#7a5a3a"},
                      {"bone": "hips", "shape": "cube", "at": [0.2, -0.4, -0.1], "size": [0.16, 0.04, 0.14], "color": "#6a6a6a"}]),
    "beggar_hood": ("Rogue_Hooded", None, [],
                    {"rogue_texture": {"0,1": "#4a4440", "1,1": "#423c38", "1,2": "#544c46", "0,0": "#f2c09a"}},
                    []),
}


def beggar(name):
    body, face, hide_own, recolor, extra = BEGGARS[name]
    parts = ([{"model": G + face[0] + ".glb", "meshes": [face[1]]}] if face else []) + [CAPE_PART]
    hide = ["Icosphere", "Knife", "Knife_Offhand", "1H_Crossbow", "2H_Crossbow", "Throwable", "Rogue_Cape",
            "Spellbook", "Spellbook_open", "1H_Wand", "2H_Staff", "Mage_Hat", "Mage_Cape"] + hide_own
    return {"_doc": f"St Maarten {name}; generated by tools/bake/martin.py - edit there",
            "model": G + body + ".glb", "parts": parts, "hide": hide, "recolor": recolor, "outline": 0.01,
            "props_rest": True, "frame": {"x": [-1.5, 1.5], "h": 2.9},
            "mesh_scale": {"Knight_Cape": [1.3, 1.6, 1.5]},
            "props": extra + PONCHO, "clips": beggar_clips()}


def all_recipes():
    r = {f"martin_{s}": martin(s) for s in range(4)}
    r.update({n: beggar(n) for n in BEGGARS})
    return r


def write_recipes():
    os.makedirs(RDIR, exist_ok=True)
    for n, rec in all_recipes().items():
        with open(os.path.join(RDIR, n + ".json"), "w") as f:
            json.dump(rec, f, indent=1)
    print("recipes written")


def bake(names, jobs=4, size=320):
    env = dict(os.environ, PYTHONPATH=PYLIB)

    def one(n):
        out = os.path.join(OUT, n)
        p = subprocess.run(["blender", "-b", "-P", os.path.join(HERE, "kaykit.py"), "--",
                            os.path.join(RDIR, n + ".json"), out, str(size)], env=env, capture_output=True, text=True)
        ok = "BAKED" in p.stdout
        print(n, "ok" if ok else "FAILED\n" + p.stdout[-2500:] + p.stderr[-1500:], flush=True)
        if ok:
            subprocess.run([sys.executable, os.path.join(HERE, "quantize.py"), out], capture_output=True)
        return ok

    with ThreadPoolExecutor(jobs) as ex:
        return all(ex.map(one, names))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "recipes"
    if cmd == "recipes":
        write_recipes()
    elif cmd == "bake":
        names = sys.argv[2:] or list(all_recipes())
        sys.exit(0 if bake(names, jobs=4) else 1)
