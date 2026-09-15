#!/usr/bin/env python3
"""Generate assets/icon.png (512×512 app icon). Requires Pillow."""
from math import cos, sin, radians
from pathlib import Path

from PIL import Image, ImageDraw

S = 4  # supersample
W = 512 * S
out = Path(__file__).resolve().parent.parent / "assets" / "icon.png"

img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle((16 * S, 16 * S, 496 * S, 496 * S), radius=90 * S, fill=(13, 71, 161, 255))
overlay = Image.new("RGBA", (W, W), (0, 0, 0, 0))
od = ImageDraw.Draw(overlay)
od.rounded_rectangle((16 * S, 16 * S, 496 * S, 300 * S), radius=90 * S, fill=(33, 150, 243, 110))
img = Image.alpha_composite(img, overlay)
d = ImageDraw.Draw(img)

cx, cy, rad = 256 * S, 250 * S, 132 * S
d.ellipse((cx - rad, cy - rad, cx + rad, cy + rad), outline=(255, 152, 0, 255), width=26 * S)
for ang in (90, 0, 270, 180):
    a = radians(ang)
    x1, y1 = cx + (rad - 6 * S) * cos(a), cy - (rad - 6 * S) * sin(a)
    x2, y2 = cx + (rad - 32 * S) * cos(a), cy - (rad - 32 * S) * sin(a)
    d.line((x1, y1, x2, y2), fill=(255, 255, 255, 230), width=10 * S)

d.line((cx, cy, cx, cy - 74 * S), fill=(255, 255, 255, 255), width=17 * S)
d.line((cx, cy, cx + 52 * S, cy + 34 * S), fill=(255, 255, 255, 255), width=14 * S)
d.ellipse((cx - 13 * S, cy - 13 * S, cx + 13 * S, cy + 13 * S), fill=(255, 255, 255, 255))

for i, r2 in enumerate((64, 44, 24)):
    box = (cx - 190 * S - r2 * S, cy + 60 * S - r2 * S, cx - 190 * S + r2 * S, cy + 60 * S + r2 * S)
    d.arc(box, start=300, end=60, fill=(227, 242, 253, 200 - i * 40), width=8 * S)

img = img.resize((512, 512), Image.LANCZOS)
out.parent.mkdir(parents=True, exist_ok=True)
img.save(out)
print("saved", out)
