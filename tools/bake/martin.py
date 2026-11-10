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
import json, math, os, subprocess, sys
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


def plume():
    """The crest: a rounded brush of red horsehair from the brow over the crown to the back."""
    out = []
    n = 9
    for i in range(n):
        f = i / (n - 1)                                   # 0 front .. 1 back
        a = math.pi * (0.12 + 0.76 * f)
        y = -0.5 * math.cos(a) + 0.06                     # (-y is the front)
        z = 0.86 + 0.38 * math.sin(a)
        r = 0.16 + 0.07 * math.sin(math.pi * f)
        out.append({"bone": "head", "shape": "sphere", "at": [0, y, z], "size": [0.11, r, r],
                    "color": "#c4232b" if i % 2 == 0 else "#a81c24"})
    out.append({"bone": "head", "shape": "cylinder", "at": [0, 0.04, 0.95], "size": [0.05, 0.16], "axis": "z", "color": "#a87a38"})
    return out


# the red cloak per stage: (radius at the hem, length, tilt): a mantle on the shoulders and a cone hanging
# from them, tilted back so it stands out behind him from the side (props on the chest bone: +y = his back)
CLOAK = {0: (0.46, 1.3, 16), 1: (0.38, 0.9, 13), 2: (0.3, 0.5, 9)}


def cloak(stage):
    if stage not in CLOAK:
        return []
    r, ln, tilt = CLOAK[stage]
    t = math.radians(tilt)
    top = (0.12, 0.36)                                   # (y, z) where it hangs from, behind the neck
    return [
        {"name": "cloak_m", "bone": "chest", "shape": "sphere", "at": [0, 0.1, 0.3], "size": [0.4, 0.36, 0.17], "color": RED},
        {"name": "cloak_b", "bone": "chest", "shape": "cone",
         "at": [0, top[0] + 0.12 + math.sin(t) * ln / 2, top[1] - math.cos(t) * ln / 2], "size": [r, ln], "rot": [tilt, 0, 0],
         "color": RED},
    ]


def martin(stage):
    # (the KayKit cape hardly shows from the side: the cloak is props now; Knight_Cape only for the
    # piece the next St Martin gives him, martin_3's *_w clips)
    hide = ["Icosphere", "1H_Sword", "2H_Sword", "Badge_Shield", "Rectangle_Shield", "Round_Shield", "Spike_Shield",
            "Knight_Helmet", "Knight_Cape"]
    props = [
        # a bronze helmet with a red plume, cheek guards
        {"bone": "head", "shape": "sphere", "at": [0, 0.06, 0.8], "size": [0.56, 0.56, 0.36], "color": "#c8964a"},
        {"bone": "head", "shape": "cylinder", "at": [0, 0.06, 0.6], "size": [0.565, 0.07], "axis": "z", "color": "#a87a38"},
    ] + plume() + cloak(stage) + [
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
        "mesh_scale": {"Knight_Cape": [1.3, 1.6, 1.5]},
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


# ── the Roman looks (A, B, C) and the rag beggars: extra variants next to v1 (martin_N, beggar_*) ──────
# theme.json picks: the martin element's "look" ("v1", "A", "B", "C") and the beggar element's "sprites".
#   A  gold muscle cuirass, bronze helmet with cheek guards and a red plume
#   B  silver-grey cuirass (mail) with a gold edge, steel helmet, red plume
#   C  bareheaded (short dark hair) with the gold cuirass
# All: bare arms and knees (KayKit Barbarian arms and legs: the trousers turned skin), laced sandal-boots,
# a skirt of leather strips (pteruges) over a white tunic, the red cloak pinned with a gold brooch at the
# right shoulder, a spatha in its scabbard at the left hip (drawn for the cut).
BAR = "barbarian_texture"
SKIN_M = "#e9b48c"


def look_colors(look):
    if look == "B":
        return {"plate": "#aeb3bb", "edge": "#d2a640", "dark": "#7d838c", "helm": "#b9bec6", "band": "#d2a640"}
    return {"plate": "#e0aa3a", "edge": "#a8741e", "dark": "#b58428", "helm": "#c99a45", "band": "#e8c060"}


def roman_helmet(c):
    return [
        {"name": "helm_dome", "bone": "head", "shape": "sphere", "at": [0, 0.08, 0.78], "size": [0.55, 0.56, 0.4], "color": c["helm"]},
        {"name": "helm_band", "bone": "head", "shape": "cylinder", "at": [0, 0.06, 0.55], "size": [0.555, 0.08], "axis": "z", "color": c["band"]},
        {"name": "helm_cheek_l", "bone": "head", "shape": "cube", "at": [0.5, -0.08, 0.34], "size": [0.06, 0.26, 0.32], "color": c["helm"]},
        {"name": "helm_cheek_r", "bone": "head", "shape": "cube", "at": [-0.5, -0.08, 0.34], "size": [0.06, 0.26, 0.32], "color": c["helm"]},
        {"name": "helm_neck", "bone": "head", "shape": "cube", "at": [0, 0.5, 0.42], "size": [0.8, 0.1, 0.22], "rot": [-25, 0, 0], "color": c["helm"]},
    ] + [dict(p, name="helm_plume%d" % i) for i, p in enumerate(plume())]


def pteruges(c):
    out = [{"name": "tunic", "bone": "hips", "shape": "cylinder", "at": [0, 0, -0.17], "size": [0.37, 0.1], "axis": "z", "color": "#ece6d8"}]
    n = 12
    for i in range(n):
        a = 2 * math.pi * i / n
        out.append({"name": "pteryx%d" % i, "bone": "hips", "shape": "cube",
                    "at": [0.43 * math.sin(a), 0.35 * math.cos(a), -0.06], "size": [0.17, 0.05, 0.2],
                    "rot": [0, 0, -math.degrees(a)], "color": "#7a4a24" if i % 2 else "#94602e"})
    out.append({"name": "belt", "bone": "hips", "shape": "cylinder", "at": [0, 0, 0.06], "size": [0.47, 0.08], "axis": "z", "color": c["edge"]})
    return out


def martin_roman(stage, look):
    c = look_colors(look)
    hide = ["Icosphere", "1H_Sword", "2H_Sword", "1H_Sword_Offhand", "Badge_Shield", "Rectangle_Shield", "Round_Shield",
            "Spike_Shield", "Knight_Helmet", "Knight_Cape", "Knight_ArmLeft", "Knight_ArmRight", "Knight_LegLeft",
            "Knight_LegRight", "Barbarian_Hat", "Barbarian_Cape", "Barbarian_Body", "Barbarian_Head", "1H_Axe",
            "1H_Axe_Offhand", "2H_Axe", "Mug", "Barbarian_Round_Shield"]
    props = (roman_helmet(c) if look != "C" else []) + pteruges(c) + cloak(stage) + [
        {"name": "brooch", "bone": "chest", "shape": "sphere", "at": [-0.34, -0.12, 0.3], "size": [0.09, 0.06, 0.09], "color": "#f0c040"}
        ] * (stage < 3) + [
        {"name": "scabbard", "bone": "hips", "shape": "cube", "at": [0.46, -0.05, -0.3], "size": [0.07, 0.1, 0.8], "rot": [-25, 0, 0], "color": "#5a3a20"},
        {"name": "hilt", "bone": "hips", "shape": "cube", "at": [0.46, -0.24, 0.12], "size": [0.08, 0.08, 0.2], "rot": [-25, 0, 0], "color": "#d2a640"},
        {"name": "blade", "bone": "handslot.r", "shape": "cube", "at": [0, -0.55, 0], "size": [0.05, 1.0, 0.1], "color": "#dde2ea"},
        {"name": "blade_guard", "bone": "handslot.r", "shape": "cube", "at": [0, -0.05, 0], "size": [0.26, 0.06, 0.08], "color": "#d2a640"},
    ]
    r = martin(stage)
    for n, cl in r["clips"].items():
        d = set(cl.get("drop", []))
        if n == "cut":
            d.add("hilt")
        if stage == 3 and n not in ("walk", "idle", "turn_front", "turn_side", "cut", "give"):
            d.update(["helm", "brooch"])          # (in the cold: helmet off, sitting in his tunic)
        if d:
            cl["drop"] = sorted(d)
    r.update({
        "_doc": f"St Martin look {look}, cloak stage {stage} (0 full .. 3 none); generated by tools/bake/martin.py - edit there",
        "parts": [{"model": G + "Barbarian.glb", "meshes": ["Barbarian_ArmLeft", "Barbarian_ArmRight", "Barbarian_LegLeft", "Barbarian_LegRight"]}],
        "hide": hide, "props": props + (PONCHO if stage == 3 else []),
        "recolor": {
            "knight_texture": {"3,0": c["plate"], "7,0": c["edge"], "6,0": c["dark"], "4,0": c["edge"], "7,1": "#6a4424",
                               "2,1": "#6a4424", "1,1": c["edge"], "0,0": SKIN_M, "1,0": "#3a2618" if look == "C" else "#5a3a22"},
            BAR: {"6,0": SKIN_M, "3,2": SKIN_M, "1,1": "#6a4424", "2,1": "#7a5230", "7,1": "#7a5230", "7,2": "#6a4424", "3,0": "#7a5230"}},
    })
    return r


RAG = {"rope": "#9a8558", "oat": "#c9b994", "beige": "#b5a383", "grey": "#8f8270", "dark": "#6f6555", "blanket": "#7c705e"}


def blanket(col):
    return [{"name": "blanket", "bone": "chest", "shape": "sphere", "at": [0, 0.1, 0.12], "size": [0.62, 0.44, 0.18], "color": col},
            {"name": "blanket_b", "bone": "chest", "shape": "cone", "at": [0, 0.3, -0.25], "size": [0.42, 0.8], "rot": [10, 0, 0], "color": col}]


def headscarf(col):
    return [{"name": "scarf_top", "bone": "head", "shape": "sphere", "at": [0, 0.12, 0.62], "size": [0.6, 0.58, 0.55], "color": col},
            {"name": "scarf_tail", "bone": "head", "shape": "cone", "at": [0, 0.48, 0.15], "size": [0.3, 0.6], "rot": [160, 0, 0], "color": col}]


RAGS = {
    # name: (body glb, head (glb, mesh) or None, recolors, extra props)
    "beggar_rags_old": ("Barbarian", None,
                        {BAR: {"6,0": "#e3b896", "0,0": "#e3b896", "1,0": "#e4e0d8", "2,0": "#cfcac0", "2,1": RAG["rope"],
                               "7,0": RAG["oat"], "0,1": RAG["grey"], "3,2": RAG["beige"], "7,1": "#e3b896",
                               "1,1": RAG["grey"], "7,2": RAG["beige"], "3,0": RAG["dark"]}},
                        blanket(RAG["blanket"])),
    "beggar_rags_woman": ("Mage", ("Mage", "Mage_Head"),
                          {"mage_texture": {"0,1": RAG["oat"], "1,1": RAG["beige"], "7,1": RAG["grey"], "2,1": RAG["rope"],
                                            "1,2": RAG["grey"], "5,0": RAG["beige"], "1,3": RAG["dark"], "0,0": "#d9a074"}},
                          headscarf("#a89a7c") + blanket("#6f6a60")),
    "beggar_rags_young": ("Barbarian", ("Knight", "Knight_Head"),
                          {BAR: {"6,0": "#c08a62", "0,0": "#c08a62", "2,1": RAG["rope"], "7,0": RAG["beige"], "0,1": RAG["oat"],
                                 "3,2": "#c08a62", "7,1": "#c08a62", "1,1": RAG["grey"], "7,2": RAG["oat"], "3,0": RAG["dark"]},
                           "knight_texture": {"0,0": "#c08a62", "1,0": "#2e2420", "2,0": "#2e2420"}},
                          []),
}


def beggar_rags(name):
    body, face, recolor, extra = RAGS[name]
    parts = ([{"model": G + face[0] + ".glb", "meshes": [face[1]]}] if face else []) + [CAPE_PART]
    hide = ["Icosphere", "1H_Axe", "1H_Axe_Offhand", "2H_Axe", "Mug", "Barbarian_Round_Shield", "Barbarian_Hat",
            "Barbarian_Cape", "Spellbook", "Spellbook_open", "1H_Wand", "2H_Staff", "Mage_Hat", "Mage_Cape"]
    if face and face[0] != body:
        hide.append(f"{body}_Head")
    return {"_doc": f"St Maarten {name} (rags, after the legend); generated by tools/bake/martin.py - edit there",
            "model": G + body + ".glb", "parts": parts, "hide": hide, "recolor": recolor, "outline": 0.01,
            "props_rest": True, "frame": {"x": [-1.5, 1.5], "h": 2.9},
            "mesh_scale": {"Knight_Cape": [1.3, 1.6, 1.5]},
            "props": extra + PONCHO, "clips": beggar_clips()}


LOOKS = ["A", "B", "C"]


def all_recipes():
    r = {f"martin_{s}": martin(s) for s in range(4)}              # look v1
    r.update({f"martin_{lk}_{s}": martin_roman(s, lk) for lk in LOOKS for s in range(4)})
    r.update({n: beggar(n) for n in BEGGARS})
    r.update({n: beggar_rags(n) for n in RAGS})
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
