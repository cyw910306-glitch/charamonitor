"""Tiny compositor for 34x20 ASCII pixel frames + PNG previews (PIL)."""
import json
from PIL import Image

W, H = 34, 20
POSES = ["lying", "slowWalk", "walk", "fastWalk", "run", "sprint", "exhausted"]
EXTRAS = ["hungry", "eat", "special"]

def P(s):
    """Part from a multi-line string; strips the common leading blank line."""
    rows = [r for r in s.split("\n") if r.strip() != ""]
    return [r.strip() for r in rows]

def blank():
    return [["."] * W for _ in range(H)]

def stamp(c, part, x, y, flip=False, recolor=None):
    for dy, row in enumerate(part):
        if flip: row = row[::-1]
        for dx, ch in enumerate(row):
            if ch == "." or ch == " ": continue
            X, Y = x + dx, y + dy
            if 0 <= X < W and 0 <= Y < H:
                c[Y][X] = recolor.get(ch, ch) if recolor else ch
    return c

def frame(*layers):
    """layers: (part, x, y) or (part, x, y, opts dict)."""
    c = blank()
    for L in layers:
        if L is None: continue
        part, x, y = L[0], L[1], L[2]
        opts = L[3] if len(L) > 3 else {}
        stamp(c, part, x, y, **opts)
    return ["".join(r) for r in c]

def validate(name, data, hop_ok=()):
    pal = data["palette"]
    assert len(pal) <= 16, (name, len(pal))
    def chk(key, fr, i):
        assert len(fr) == H, (name, key, i, len(fr))
        for r in fr:
            assert len(r) == W, (name, key, i, r)
            for ch in r:
                assert ch == "." or ch in pal, (name, key, i, ch)
        if (key, i) not in hop_ok and key not in hop_ok:
            assert any(ch != "." for ch in fr[-1]), (name, key, i, "feet not on row 19")
    for k, frs in list(data["poses"].items()) + list(data["extras"].items()):
        for i, fr in enumerate(frs): chk(k, fr, i)

def hexrgb(h): return tuple(int(h[i:i+2], 16) for i in (1, 3, 5))

def img(fr, pal, bg=None, scale=1):
    im = Image.new("RGBA", (W, H), bg + (255,) if bg else (0, 0, 0, 0))
    px = im.load()
    for y, r in enumerate(fr):
        for x, ch in enumerate(r):
            if ch != ".": px[x, y] = hexrgb(pal[ch]) + (255,)
    return im.resize((W * scale, H * scale), Image.NEAREST)

def sheet(data, path, scale=8):
    rows = [(k, data["poses"][k]) for k in POSES] + [(k, data["extras"][k]) for k in EXTRAS]
    cols = max(len(f) for _, f in rows)
    pad = 4
    S = Image.new("RGBA", (cols * (W * scale + pad) + pad, len(rows) * (H * scale + pad) + pad), (205, 205, 205, 255))
    for j, (_, frs) in enumerate(rows):
        for i, fr in enumerate(frs):
            S.paste(img(fr, data["palette"], (232, 232, 232), scale), (pad + i * (W * scale + pad), pad + j * (H * scale + pad)))
    S.save(path)

def strips(data, path, zoom=3):
    """Every frame at 1x on a light and a dark menu bar, then zoomed (nearest) so it can be looked at."""
    rows = [data["poses"][k] for k in POSES] + [data["extras"][k] for k in EXTRAS]
    cols = max(len(f) for f in rows)
    out = Image.new("RGBA", (cols * (W + 4) * 2 + 8, len(rows) * (H + 2)), (120, 120, 120, 255))
    for half, bg in enumerate([(236, 236, 236), (42, 42, 42)]):
        x0 = half * (cols * (W + 4) + 8)
        for j, frs in enumerate(rows):
            bar = Image.new("RGBA", (cols * (W + 4), H + 2), bg + (255,))
            for i, fr in enumerate(frs):
                bar.alpha_composite(img(fr, data["palette"]), (i * (W + 4) + 2, 1))
            out.paste(bar, (x0, j * (H + 2)))
    out.save(path.replace(".png", "@1x.png"))
    out.resize((out.width * zoom, out.height * zoom), Image.NEAREST).save(path)

def gif(data, path, keys, scale=6, ms=140):
    frs = []
    for k in keys:
        src = data["poses"].get(k) or data["extras"][k]
        frs += [img(f, data["palette"], (236, 236, 236), scale) for f in src]
    frs[0].save(path, save_all=True, append_images=frs[1:], duration=ms, loop=0)

def F(*groups):
    layers = []
    for g in groups:
        if isinstance(g, list): layers += g
        elif g: layers.append(g)
    return frame(*layers)

def stamp_all(fr, layers):
    c = [list(r) for r in fr]
    for L in layers:
        stamp(c, L[0], L[1], L[2], **(L[3] if len(L) > 3 else {}))
    return ["".join(r) for r in c]

def flip_cols(fr, a, b):
    return [r[:a] + r[a:b][::-1] + r[b:] for r in fr]

def silhouette(layers, outline, fill):
    """Same layers, every pixel recoloured: outline pixels to `outline`, the rest to `fill` (afterimages)."""
    out = []
    for L in layers:
        part = [''.join('.' if ch == '.' else (outline if ch == 'o' else fill) for ch in row) for row in L[0]]
        out.append((part,) + tuple(L[1:]))
    return out
