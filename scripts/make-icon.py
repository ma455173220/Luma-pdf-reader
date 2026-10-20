"""Builds Resources/AppIcon.icns from the reader's artwork in Resources/icon/source.webp.

The artwork is the character 知 in ink on paper that fills the whole picture, with an open book
standing in for 口. This:
  1. takes a square closely around the character and the seal;
  2. lifts the ink off the artwork's coarse, yellowish paper and lays it on a lighter xuan paper
     made here: warm white, fine grain, a few fibres. Specks of dirt in the scan stay behind;
  3. stamps a seal reading 守墨 in small seal script, white characters cut into red (白文), under
     the book. The icon then reads 知 (the character), 白 (the empty paper), 守墨 (the seal);
  4. places the square on Apple's icon grid: an 824-point rounded square in the middle of a
     1024-point canvas, transparent around it.

The seal characters are Shuowen small seal glyphs from Wikimedia Commons, public domain:
File:守-seal.svg, File:黑-seal.svg, File:土-seal.svg (kept beside the artwork, with the
masks rendered from them at 1600 pixels by macOS's own SVG drawing). The Shuowen builds 墨
from 黑 above 土, and so does this script; Commons has no 墨 of its own.

usage: python3 -I scripts/make-icon.py
"""
import os
import shutil
import subprocess
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
icon_dir = os.path.join(root, "Resources", "icon")
iconset = os.path.join(root, "build", "AppIcon.iconset")
target = os.path.join(root, "Resources", "AppIcon.icns")

# The square taken from the artwork, in its pixels: the ink spans x 309–950 and y 352–890, and
# with the seal below the book the whole sits centred in it, about five sixths of its width.
CENTRE_X, CENTRE_Y, SIDE = 629, 644, 760
CANVAS, SHAPE = 1024, 824
# The seal, in artwork pixels: under the right edge of the book.
SEAL_W, SEAL_H, SEAL_CENTRE = 62, 121, (915, 876)
PAPER = (246, 241, 230)                    # xuan paper, warm white
INK_COLOUR = np.array([30.0, 27.0, 22.0])  # the artwork's ink
K = 8                                      # the seal is drawn 8 times finer, then scaled down
INK = np.array([0.78, 0.38, 0.30])         # multiplied into the paper; the old seal's red
rng = np.random.default_rng(7)             # fixed, so the stamp's wear is the same every build


def mask(name):
    m = np.asarray(Image.open(os.path.join(icon_dir, name)).convert("L")) < 128
    ys, xs = np.where(m)
    return m[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def resized(m, w, h):
    return np.asarray(Image.fromarray((m * 255).astype(np.uint8)).resize((int(w), int(h)), Image.LANCZOS)) > 127


def stroke(m):
    d = ndimage.distance_transform_edt(m)
    return 2 * np.median(d[(d == ndimage.maximum_filter(d, size=3)) & (d > 1)])


def character_mo():
    """墨: 黑 above 土, with 土's upright reaching between 黑's lower strokes."""
    hei, tu = mask("hei-seal.png"), mask("tu-seal.png")
    width = hei.shape[1]
    top_h = int(hei.shape[0] * 0.82)
    upper = resized(hei, width, top_h)
    tu_w, tu_h = int(width * 0.9), int(top_h * 0.46)
    lower = resized(tu, tu_w, tu_h)
    x = (width - tu_w) // 2
    gap_to_upper = ndimage.distance_transform_edt(~np.pad(upper, ((0, tu_h), (0, 0))))
    limit = 1.5 * stroke(upper)
    rise = 0
    while rise + 4 < tu_h:
        y = top_h - (rise + 4)
        if gap_to_upper[y:y + tu_h, x:x + tu_w][lower].min() < limit:
            break
        rise += 4
    out = np.zeros((top_h + tu_h - rise, width), bool)
    out[:top_h] |= upper
    out[top_h - rise:top_h - rise + tu_h, x:x + tu_w] |= lower
    return out


def fit(m, cw, ch, target):
    """Fills a cell the way seal carvers do (widened up to 1.45 times), with strokes of one width."""
    h, w = m.shape
    m = resized(m, min(cw, w * ch / h * 1.45), ch)
    delta = (target - stroke(m)) / 2
    if delta > 0:
        m = ndimage.distance_transform_edt(~m) <= delta
    elif delta < 0:
        m = ndimage.distance_transform_edt(m) > -delta
    out = np.zeros((int(ch), int(cw)), bool)
    x = (int(cw) - m.shape[1]) // 2
    out[:, x:x + m.shape[1]] = m
    return out


def rounded_rect(w, h, r):
    y, x = np.mgrid[0:h, 0:w]
    cx, cy = np.clip(x, r, w - 1 - r), np.clip(y, r, h - 1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def seal_alpha():
    W, H = SEAL_W * K, SEAL_H * K
    margin, gap = int(W * 0.12), int(W * 0.06)
    cw = W - 2 * margin
    first_h = int((H - 2 * margin - gap) * 0.42)      # 墨 is the busier character and gets more height
    second_h = H - 2 * margin - gap - first_h
    target = W * 0.085
    chars = np.zeros((H, W), bool)
    chars[margin:margin + first_h, margin:margin + cw] = fit(mask("shou-seal.png"), cw, first_h, target)
    chars[margin + first_h + gap:H - margin, margin:margin + cw] = fit(character_mo(), cw, second_h, target)
    ink = rounded_rect(W, H, int(W * 0.1)) & ~chars
    # A rough edge, worn spots where the stamp did not take, and uneven pressure.
    noise = ndimage.gaussian_filter(rng.standard_normal(ink.shape), 2.5)
    ink = ndimage.gaussian_filter(ink.astype(float), 3) + 0.22 * noise / noise.std() > 0.5
    voids = ndimage.gaussian_filter(rng.standard_normal(ink.shape), 4)
    ink &= voids < np.percentile(voids, 95)
    pressure = 0.82 + 0.18 * np.clip(ndimage.gaussian_filter(rng.standard_normal(ink.shape), 10) * 4 + 0.5, 0, 1)
    alpha = Image.fromarray((ink * pressure * 255).astype(np.uint8)).resize((SEAL_W, SEAL_H), Image.LANCZOS)
    return np.asarray(alpha)[..., None] / 255.0


def ink_alpha(square):
    """How much ink covers each pixel, 0 to 1, read against the artwork's own paper."""
    lum = square.mean(axis=2)
    # The paper's brightness, from pixels that are plainly paper, so that it is not pulled down
    # inside the strokes.
    plain = (lum > 170).astype(float)
    paper = ndimage.gaussian_filter(lum * plain, 30) / np.maximum(ndimage.gaussian_filter(plain, 30), 1e-3)
    alpha = np.clip((paper - lum) / (paper - 22), 0, 1)
    # Around the character, including the thin lines inside the book, every trace of ink is kept;
    # only the paper's own faint fibres are taken out.
    labels, count = ndimage.label(alpha > 0.15)
    sizes = ndimage.sum(np.ones_like(labels), labels, range(1, count + 1))
    strokes = np.isin(labels, np.where(sizes >= 2000)[0] + 1)
    around = ndimage.distance_transform_edt(~strokes) <= 60
    inside = np.clip((alpha - 0.06) / 0.94, 0, 1)
    # Further out there is only paper: fibres, and specks of dirt in the scan.
    outside = np.clip((alpha - 0.2) / 0.25, 0, 1)
    outside[ndimage.binary_dilation(labels > 0, iterations=2)] = 0
    return np.where(around, inside, outside)


def xuan_paper(n):
    """Warm white paper with a fine grain, the faintest clouding, and a few long fibres."""
    from PIL import ImageDraw
    paper_rng = np.random.default_rng(11)
    grain = ndimage.gaussian_filter(paper_rng.standard_normal((n, n)), 0.8)
    cloud = ndimage.gaussian_filter(paper_rng.standard_normal((n, n)), 40)
    shade = 1 + 0.008 * grain / grain.std() + 0.005 * cloud / cloud.std()
    paper = np.array(PAPER, float)[None, None, :] * shade[..., None]
    fibres = Image.new("L", (n, n), 0)
    draw = ImageDraw.Draw(fibres)
    for _ in range(140):
        x, y = paper_rng.uniform(0, n, 2)
        angle, length = paper_rng.uniform(0, np.pi), paper_rng.uniform(15, 60)
        points = [(x + t * length * np.cos(angle) + 3 * np.sin(t * 3 + x), y + t * length * np.sin(angle) + 3 * np.cos(t * 2 + y))
                  for t in np.linspace(0, 1, 8)]
        draw.line(points, fill=int(paper_rng.uniform(25, 60)), width=1)
    return paper * (1 - 0.18 * np.asarray(fibres, float)[..., None] / 255)


art = np.asarray(Image.open(os.path.join(icon_dir, "source.webp")).convert("RGB")).astype(float)
left, top = CENTRE_X - SIDE // 2, CENTRE_Y - SIDE // 2
alpha = ink_alpha(art[top:top + SIDE, left:left + SIDE])[..., None]
square = xuan_paper(SIDE) * (1 - alpha) + INK_COLOUR * alpha

a = seal_alpha()
sx, sy = SEAL_CENTRE[0] - SEAL_W // 2 - left, SEAL_CENTRE[1] - SEAL_H // 2 - top
region = square[sy:sy + SEAL_H, sx:sx + SEAL_W]
square[sy:sy + SEAL_H, sx:sx + SEAL_W] = region * (1 - a) + region * INK * a

paper = Image.fromarray(np.clip(square, 0, 255).astype(np.uint8)).resize((SHAPE, SHAPE), Image.LANCZOS)

# Apple's rounded square is close to a superellipse of degree 5. Drawn four times larger
# and scaled down, so that its edge is smooth.
n = SHAPE * 4
coords = (np.arange(n) + 0.5) / n * 2 - 1
x, y = np.meshgrid(coords, coords)
inside = (np.abs(x) ** 5 + np.abs(y) ** 5) <= 1
shape = Image.fromarray((inside * 255).astype(np.uint8)).resize((SHAPE, SHAPE), Image.LANCZOS)

icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
offset = (CANVAS - SHAPE) // 2
icon.paste(paper, (offset, offset), shape)

shutil.rmtree(iconset, ignore_errors=True)
os.makedirs(iconset)
for size in (16, 32, 128, 256, 512):
    icon.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
    icon.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", target], check=True)
shutil.rmtree(iconset)
print("wrote", target, file=sys.stderr)
