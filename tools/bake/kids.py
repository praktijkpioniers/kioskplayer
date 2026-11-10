#!/usr/bin/env python3
"""St Maarten lantern children: generate many distinct kid recipes for kaykit.py, and bake them.

    python3 tools/bake/kids.py recipes            # writes tools/bake/recipes/stmaarten/kid_NN.json
    python3 tools/bake/kids.py bake [NN ...] [-j 4]  # bakes them to themes/stmaarten/anim/kid_NN
    python3 tools/bake/kids.py sprites            # the theme.json "sprites" entries (paste/merge)

Every kid has the same clips (walk, idle, sing, give, skip, cheer, turns), so the engine treats them
all alike. Outfits come from a few bases (KayKit Rogue or Mage body = jacket or long coat, four
faces) crossed with winter clothes: coat colour, scarf, a knitted hat with a pompom, a cap, a hood
or bare hair, skin tone, leg length (three heights). Outfits are picked so no two share both coat
colour and headwear. The lantern is not baked: the left hand is held forward and tracked ("hand.l"
in clips.json), and the engine draws a lantern on its stick there (lantern colour and shape at
random, see tools/bake/lanterns.py).
"""
import json, os, random, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RDIR = os.path.join(HERE, "recipes", "stmaarten")
OUT = os.path.join(ROOT, "themes", "stmaarten", "anim")
G = "../../models/kaykit-adventurers/addons/kaykit_character_pack_adventures/Characters/gltf/"
PYLIB = os.path.expanduser("~/assets-src/pylib")
N_KIDS = 14

SKIN = ["#ffd9c4", "#f2c09a", "#d9a074", "#a8704a", "#7a4a2e"]
COATS = ["#d8382f", "#2f5fd8", "#e8b828", "#2f9a52", "#8a3fb0", "#e0702a", "#1f7f8a", "#c0346e",
         "#5a6e8c", "#7a4a2e", "#3a3a48", "#d0d0c8"]
WOOL = ["#e8e0d0", "#d8382f", "#2f5fd8", "#f2c230", "#2f9a52", "#e070a8", "#8a3fb0", "#f08030", "#202028"]

# faces: (glb, head mesh, texture key, girl?) - the Rogue face also comes hooded (Rogue_Hooded.glb)
FACES = [("Rogue", "Rogue_Head", "rogue_texture"), ("Knight", "Knight_Head", "knight_texture"),
         ("Mage", "Mage_Head", "mage_texture"), ("Rogue_Hooded", "Rogue_Head_Hooded", "rogue_texture")]
HIDE_ALL = ["Icosphere", "Knife", "Knife_Offhand", "1H_Crossbow", "2H_Crossbow", "Throwable", "Rogue_Cape",
            "Spellbook", "Spellbook_open", "1H_Wand", "2H_Staff", "Mage_Hat", "Mage_Cape"]
OWN_HEAD = {"Rogue": "Rogue_Head", "Mage": "Mage_Head", "Rogue_Hooded": "Rogue_Head_Hooded"}
# body swatches (column,row of the 8×4 texture): the jacket / robe, its trim
BODY = {"Rogue": {"coat": ["0,1", "1,1", "1,2"], "trim": []},   # ("1,0" is the hair)
        "Mage": {"coat": ["0,1", "1,1", "7,1"], "trim": ["2,1", "1,2", "5,0", "1,3"]}}

HOLD = {"from": "Idle", "frame": 0, "bones": ["upperarm.l", "lowerarm.l", "wrist.l", "hand.l"]}
ARM = {"upperarm.l": [0, 0, -55]}          # the lantern arm forward and up a little (see the stick)
TRACK = {"hand.l": [0, 0, 0]}


def clip(action, yaw, **kw):
    c = {"action": action, "yaw": yaw, "hold": HOLD, "turn": dict(ARM), "track": TRACK}
    c.update(kw)
    return c


CLIPS = {
    "walk": clip("Walking_A", 90, loop=True, stride="auto", step=3),
    "idle": clip("Idle", 15, loop=True, frames=8, step=5),
    "turn_front": clip("Idle", [90, 15], frames=4),
    "turn_side": clip("Idle", [15, 90], frames=4),
    # singing: half turned to whom they sing for, chin up (the engine adds the bob and the notes)
    "sing": clip("Idle", 55, loop=True, frames=8, step=5),
    "give": clip("PickUp", 90, step=3),
    "skip": clip("Running_A", 90, loop=True, stride="auto", step=3, speed=0.8),
    "cheer": clip("Cheer", 15, step=3),
}
CLIPS["sing"]["turn"] = dict(ARM, head=[-14, 0, 0])


def hat_props(kind, wool, wool2):
    """Headwear as props on the head bone (rest pose; the head bone starts 1.24 up, the head's top ~2.2)."""
    if kind == "beanie":
        return [{"bone": "head", "shape": "sphere", "at": [0, 0.02, 0.78], "size": [0.57, 0.57, 0.4], "color": wool},
                {"bone": "head", "shape": "cylinder", "at": [0, 0.02, 0.56], "size": [0.58, 0.12], "axis": "z", "color": wool2},
                {"bone": "head", "shape": "sphere", "at": [0, 0.02, 1.16], "size": [0.13, 0.13, 0.13], "color": wool2}]
    if kind == "cap":
        return [{"bone": "head", "shape": "sphere", "at": [0, 0.02, 0.74], "size": [0.52, 0.52, 0.32], "color": wool},
                {"bone": "head", "shape": "cube", "at": [0, -0.5, 0.6], "size": [0.5, 0.32, 0.05], "color": wool}]
    if kind == "bobble":    # a long knitted hat, its tail with the pompom hanging back
        return [{"bone": "head", "shape": "sphere", "at": [0, 0.02, 0.76], "size": [0.53, 0.53, 0.36], "color": wool},
                {"bone": "head", "shape": "cone", "at": [0, 0.22, 1.12], "size": [0.26, 0.5], "rot": [-35, 0, 0], "color": wool},
                {"bone": "head", "shape": "sphere", "at": [0, 0.42, 1.36], "size": [0.12, 0.12, 0.12], "color": wool2}]
    return []


def scarf_props(col):
    return [{"bone": "chest", "shape": "cylinder", "at": [0, 0, 0.26], "size": [0.36, 0.14], "axis": "z", "color": col},
            {"bone": "chest", "shape": "cube", "at": [0.14, -0.33, 0.05], "size": [0.13, 0.05, 0.36], "color": col}]


def outfits(n=N_KIDS, seed=1111):
    rnd = random.Random(seed)
    seen, out = set(), []
    heads = ["beanie", "cap", "bobble", "hood", "bare"]
    while len(out) < n:
        k = len(out)
        face = FACES[k % 3] if k % 5 != 4 else FACES[3]          # every fifth hooded
        hat = "hood" if face[0] == "Rogue_Hooded" else rnd.choice(["beanie", "beanie", "cap", "bobble", "bare"])
        coat = rnd.choice(COATS)
        if (coat, hat) in seen:
            continue
        seen.add((coat, hat))
        wool = rnd.choice([w for w in WOOL if w != coat])
        wool2 = rnd.choice([w for w in WOOL if w != wool])
        out.append({"face": face, "body": "Mage" if k % 3 == 1 else "Rogue", "hat": hat, "coat": coat,
                    "wool": wool, "wool2": wool2, "scarf": rnd.random() < 0.6, "skin": SKIN[(k * 2 + k // 5) % len(SKIN)],
                    "legs": [0.75, 0.85, 0.95][k % 3]})
    return out


def recipe(o, i):
    body = o["body"]
    face_glb, face_mesh, face_tex = o["face"]
    model, parts, hide = body, [], list(HIDE_ALL)
    if face_glb == "Rogue_Hooded" and body == "Rogue":
        model = "Rogue_Hooded"            # (its own head is the hooded one)
    elif OWN_HEAD[body] != face_mesh:
        parts = [{"model": G + face_glb + ".glb", "meshes": [face_mesh]}]
        hide.append(OWN_HEAD[body])       # ("Rogue_Head" would hide "Rogue_Head_Hooded" too: only a Mage's)
    recolor = {f"{body.lower()}_texture": {c: o["coat"] for c in BODY[body]["coat"]}}
    recolor[f"{body.lower()}_texture"].update({c: o["wool"] for c in BODY[body]["trim"][:1]})
    recolor[f"{body.lower()}_texture"]["0,0"] = o["skin"]
    rf = recolor.setdefault(face_tex, {})
    rf["0,0"] = o["skin"]
    if o["hat"] == "hood":      # the hood in the coat's colour
        rf.update({"1,1": o["coat"], "0,1": o["coat"], "1,2": o["coat"]})
    props = hat_props(o["hat"], o["wool"], o["wool2"])
    if o["scarf"]:
        props += scarf_props(o["wool2"] if o["hat"] != "bare" else o["wool"])
    # mittens
    props += [{"bone": "hand.l", "shape": "sphere", "at": [0.09, 0, 0], "size": [0.12, 0.12, 0.12], "color": o["wool"]},
              {"bone": "hand.r", "shape": "sphere", "at": [-0.09, 0, 0], "size": [0.12, 0.12, 0.12], "color": o["wool"]}]
    return {
        "_doc": f"St Maarten lantern child {i:02d} (generated by tools/bake/kids.py - edit there): {body} body, "
                f"{face_mesh}, {o['hat']}, coat {o['coat']}",
        "model": G + model + ".glb", "parts": parts,
        "hide": hide, "recolor": recolor, "outline": 0.01, "props_rest": True,
        "bone_scale": {"head": 1.08, "upperleg.l": o["legs"], "upperleg.r": o["legs"]},
        "frame": {"x": [-1.15, 1.15], "h": 2.75},
        "props": props, "clips": CLIPS}


def write_recipes():
    os.makedirs(RDIR, exist_ok=True)
    names = []
    for i, o in enumerate(outfits()):
        p = os.path.join(RDIR, f"kid_{i:02d}.json")
        with open(p, "w") as f:
            json.dump(recipe(o, i), f, indent=1)
        names.append(p)
    print("wrote", len(names), "recipes to", RDIR)


def bake(which, jobs=4, size=300):
    env = dict(os.environ, PYTHONPATH=PYLIB)

    def one(i):
        r = os.path.join(RDIR, f"kid_{i}.json")
        out = os.path.join(OUT, f"kid_{i}")
        p = subprocess.run(["blender", "-b", "-P", os.path.join(HERE, "kaykit.py"), "--", r, out, str(size)],
                           env=env, capture_output=True, text=True)
        ok = "BAKED" in p.stdout
        print("kid", i, "ok" if ok else "FAILED\n" + p.stdout[-2000:] + p.stderr[-2000:], flush=True)
        if ok:
            subprocess.run([sys.executable, os.path.join(HERE, "quantize.py"), out], capture_output=True)
        return ok

    with ThreadPoolExecutor(jobs) as ex:
        return all(ex.map(one, which))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "recipes"
    if cmd == "recipes":
        write_recipes()
    elif cmd == "bake":
        args = [a for a in sys.argv[2:] if not a.startswith("-j")]
        jobs = int(next((a[2:] for a in sys.argv[2:] if a.startswith("-j")), 4) or 4)
        which = args or [f"{i:02d}" for i in range(N_KIDS)]
        sys.exit(0 if bake(which, jobs) else 1)
    elif cmd == "sprites":
        print(json.dumps({f"kid_{i:02d}": {"anim": f"anim/kid_{i:02d}", "unit": 0.075} for i in range(N_KIDS)}, indent=1))
