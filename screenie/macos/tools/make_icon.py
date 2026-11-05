"""Draws Resources/AppIcon.png (1024x1024): Aurora glows and stars on a night-sky
squircle, laid out on the standard macOS icon grid (824 px shape, 100 px margins).

    python3 tools/make_icon.py      (needs numpy and Pillow)
"""
import random
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

SIZE = 1024
SS = 2                      # supersampling for smooth edges
N = SIZE * SS
INSET, SHAPE = 100, 824     # macOS icon grid

# Pixel centres in shape coordinates (0..1 across the squircle).
y, x = np.mgrid[0:N, 0:N].astype(np.float64)
u = ((x + 0.5) / SS - INSET) / SHAPE
v = ((y + 0.5) / SS - INSET) / SHAPE

# Squircle (superellipse, n=4 is close to Apple's continuous-corner shape).
mask = (np.abs(2 * u - 1) ** 4 + np.abs(2 * v - 1) ** 4) <= 1.0

# Night sky: deep navy, a touch lighter towards the bottom.
top = np.array([0.020, 0.025, 0.075])
bottom = np.array([0.045, 0.030, 0.110])
img = top + (bottom - top) * np.clip(v, 0, 1)[..., None]

# Aurora glows (the same colours as the Aurora style).
glows = [
    ((0.20, 0.45, 1.00), 0.34, 0.42, 0.30, 0.85),
    ((0.10, 0.80, 0.75), 0.70, 0.30, 0.22, 0.70),
    ((0.55, 0.25, 0.95), 0.64, 0.66, 0.28, 0.85),
    ((0.95, 0.35, 0.60), 0.28, 0.80, 0.20, 0.40),
    ((0.25, 0.65, 1.00), 0.52, 0.50, 0.40, 0.25),
]
for color, cx, cy, r, a in glows:
    g = np.exp(-(((u - cx) ** 2 + (v - cy) ** 2) / (2 * (r / 2) ** 2))) * a
    img = img + g[..., None] * np.array(color)

# Stars.
rnd = random.Random(7)
for _ in range(45):
    sx, sy = rnd.uniform(0.06, 0.94), rnd.uniform(0.06, 0.94)
    b = rnd.uniform(0.25, 1.0) ** 2
    rad = rnd.uniform(0.0025, 0.0055)
    d2 = (u - sx) ** 2 + (v - sy) ** 2
    img = img + (np.exp(-d2 / (2 * rad ** 2)) * b)[..., None] * np.array([0.9, 0.93, 1.0])
# A few bright twinkles with a cross flare.
for sx, sy, b in [(0.22, 0.24, 1.0), (0.79, 0.58, 0.85), (0.60, 0.17, 0.7), (0.40, 0.70, 0.6)]:
    du, dv = np.abs(u - sx), np.abs(v - sy)
    core = np.exp(-(du ** 2 + dv ** 2) / (2 * 0.009 ** 2))
    flare = (np.exp(-du / 0.022) * np.exp(-(dv / 0.0035) ** 2)
             + np.exp(-dv / 0.022) * np.exp(-(du / 0.0035) ** 2))
    img = img + ((core + 0.8 * flare) * b)[..., None] * np.array([0.92, 0.95, 1.0])

# Soft tone mapping so overlapping glows don't clip harshly.
img = 1 - np.exp(-img * 1.15)

# Faint highlight along the top edge for depth.
edge = mask & ~((np.abs(2 * u - 1) ** 4 + np.abs(2 * (v - 0.004) - 1) ** 4) <= 1.0)
img[edge] = img[edge] * 0.6 + 0.4 * np.array([0.55, 0.6, 0.9])

rgba = np.zeros((N, N, 4))
rgba[..., :3] = np.clip(img, 0, 1)
rgba[..., 3] = mask
icon = Image.fromarray((rgba * 255).round().astype(np.uint8), "RGBA").resize((SIZE, SIZE), Image.LANCZOS)

# Drop shadow, as on standard macOS icons.
alpha = icon.getchannel("A")
shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
shadow.putalpha(alpha.point(lambda a: a * 0.35))
shadow = shadow.transform((SIZE, SIZE), Image.AFFINE, (1, 0, 0, 0, 1, -10)).filter(ImageFilter.GaussianBlur(14))
out = Image.alpha_composite(shadow, icon)

dest = Path(__file__).resolve().parent.parent / "Resources" / "AppIcon.png"
out.save(dest)
print(f"wrote {dest}")
