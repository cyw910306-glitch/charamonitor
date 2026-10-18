"""Writes web/demo-tancat.png, the site's drag demo sheet (web/index.html #play): one row per motion, 34x20 frames at 1x,
transparent. Run from this folder: python3 web_demo.py"""
from PIL import Image
from lib import W, H, img
import tancat
ROWS = [("poses", "lying"), ("poses", "walk"), ("poses", "run"), ("poses", "sprint"), ("extras", "special")]  # index.html ROW
d = tancat.data
frames = [d[s][k] for s, k in ROWS]
out = Image.new("RGBA", (W * max(map(len, frames)), H * len(ROWS)), (0, 0, 0, 0))
for j, frs in enumerate(frames):
    for i, fr in enumerate(frs):
        out.alpha_composite(img(fr, d["palette"]), (i * W, j * H))
out.save("../../web/demo-tancat.png", optimize=True)
print("web/demo-tancat.png", out.size, [len(f) for f in frames])
