"""Draws the app icon: a white microphone on the keyboard's turning gradient orb, with a glow,
over a dark blue background. Writes a 1024 x 1024 PNG without transparency.

    python3 scripts/make_icon.py PersianSTT/Assets.xcassets/AppIcon.appiconset/AppIcon.png
"""
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
S = 4 * SIZE  # drawn large, then scaled down for smooth edges


def rgb(hex_colour):
    return np.array([int(hex_colour[i:i + 2], 16) for i in (1, 3, 5)], dtype=float)


def mix(stops, t):
    """Colour at t in [0, 1] along evenly spaced colour stops, per pixel."""
    t = np.clip(t, 0, 1) * (len(stops) - 1)
    i = np.minimum(t.astype(int), len(stops) - 2)
    f = (t - i)[..., None]
    a = np.array(stops)[i]
    b = np.array(stops)[i + 1]
    return a + (b - a) * f


y, x = np.mgrid[0:S, 0:S].astype(float)
cx = cy = S / 2
dx, dy = x - cx, y - cy
r = np.hypot(dx, dy) / S

# Background: dark blue, lighter towards the top.
background = mix([rgb("#2A2F7A"), rgb("#141A45"), rgb("#090C24")], y / S)

# Glow behind the orb.
glow = np.exp(-((r / 0.30) ** 2))[..., None]
image = background + (mix([rgb("#C04BD8")], np.zeros_like(r)) - background) * 0.55 * glow

# Orb: conic gradient pink, purple, blue, teal, pink, as in the keyboard.
angle = (np.arctan2(dx, -dy) / (2 * np.pi)) % 1
conic = mix([rgb("#FF375F"), rgb("#BF5AF2"), rgb("#0A84FF"), rgb("#40C8E0"), rgb("#FF375F")], angle)
# A soft light from the top left, and a darker rim.
shade = 1 + 0.18 * np.clip(-(dx + dy) / S / 0.3, -1, 1)
orb_radius = 0.30
edge = np.clip((orb_radius - r) * S / 6, 0, 1)[..., None]  # anti-aliased by the scaling below
rim = 1 - 0.25 * np.clip((r - orb_radius * 0.7) / (orb_radius * 0.3), 0, 1)
orb = np.clip(conic * shade[..., None] * rim[..., None], 0, 255)
image = image * (1 - edge) + orb * edge

# Thin rings around the orb, like the progress ring.
for radius, width, alpha in [(0.365, 0.006, 0.35), (0.42, 0.004, 0.18)]:
    ring = np.clip(1 - np.abs(r - radius) / width, 0, 1)[..., None]
    image = image * (1 - alpha * ring) + 255 * alpha * ring

canvas = Image.fromarray(image.astype(np.uint8), "RGB")

# Microphone, white, with a soft shadow.
mic = Image.new("L", (S, S), 0)
d = ImageDraw.Draw(mic)
u = S / 1024
body_w, body_h = 150 * u, 250 * u
top = cy - 205 * u
d.rounded_rectangle([cx - body_w / 2, top, cx + body_w / 2, top + body_h], radius=body_w / 2, fill=255)
stroke = 30 * u
holder_w, holder_top = 236 * u, top + 95 * u
holder_bottom = top + body_h + 55 * u
# The holder: straight sides, then a half circle under the body.
bend = holder_bottom - holder_w / 2
d.arc([cx - holder_w / 2, bend - holder_w / 2, cx + holder_w / 2, holder_bottom],
      start=0, end=180, fill=255, width=int(stroke))
for side in (-1, 1):
    ex = cx + side * (holder_w / 2 - stroke / 2)
    d.rectangle([ex - stroke / 2, holder_top, ex + stroke / 2, bend], fill=255)
    # Rounded ends.
    d.ellipse([ex - stroke / 2, holder_top - stroke / 2, ex + stroke / 2, holder_top + stroke / 2], fill=255)
stem_top, stem_bottom = holder_bottom - stroke / 2, holder_bottom + 70 * u
d.rectangle([cx - stroke / 2, stem_top, cx + stroke / 2, stem_bottom], fill=255)
base_w = 150 * u
d.rounded_rectangle([cx - base_w / 2, stem_bottom - stroke / 2, cx + base_w / 2, stem_bottom + stroke / 2],
                    radius=stroke / 2, fill=255)

shadow = mic.filter(ImageFilter.GaussianBlur(28 * u))
canvas.paste(Image.new("RGB", (S, S), (40, 10, 70)), (0, 0), shadow.point(lambda v: int(v * 0.45)))
canvas.paste(Image.new("RGB", (S, S), (255, 255, 255)), (0, 0), mic)

canvas.resize((SIZE, SIZE), Image.LANCZOS).save(sys.argv[1], optimize=True)
