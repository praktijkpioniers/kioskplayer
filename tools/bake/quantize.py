#!/usr/bin/env python3
"""Shrink baked frames for git: 256-colour palette PNGs (~10x smaller, alpha kept).

Usage: python3 tools/bake/quantize.py themes/<theme>/anim/<name>
"""
import sys
from pathlib import Path
from PIL import Image

for f in sorted(Path(sys.argv[1]).glob("*.png")):
    Image.open(f).convert("RGBA").quantize(256, method=Image.Quantize.FASTOCTREE).save(f, optimize=True)
