#!/usr/bin/env python3
"""Synthetic Persian handwriting for the handwriting benchmark (ink-eval.yml).

There is no public set of Persian online handwriting (pen strokes with times), so words are
drawn with fonts close to handwriting (Nastaliq, Ruqaa, a plain sans) and turned into pen
strokes: the word is shaped with HarfBuzz, rendered, thinned to a one-pixel skeleton, and the
skeleton is traced into strokes, the word's parts right to left and the dots after them, at a
writing pace. A rough stand-in for a finger: real handwriting is messier, so treat the result as
a check that the recognizer reads Persian at all and of its speed and memory, not as its
accuracy on a user's own hand.

Usage: ink_samples.py <fa_words.txt> <out.json> <count> <font.ttf> [font.ttf ...]
"""
import json
import random
import sys

import numpy as np
import uharfbuzz as hb
from fontTools.pens.basePen import BasePen
from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw
from skimage.measure import label
from skimage.morphology import skeletonize

HEIGHT = 140  # pixels for the font's em


class FlatPen(BasePen):
    """Collects glyph outlines as polygons, curves cut into short lines."""

    def __init__(self, glyphset, dx, scale, base):
        super().__init__(glyphset)
        self.polys, self.cur, self.dx, self.scale, self.base = [], [], dx, scale, base

    def _pt(self, p):
        return ((p[0] + self.dx) * self.scale, self.base - p[1] * self.scale)

    def _moveTo(self, p):
        self.cur = [self._pt(p)]

    def _lineTo(self, p):
        self.cur.append(self._pt(p))

    def _curveToOne(self, p1, p2, p3):
        p0 = self._last_raw
        for i in range(1, 9):
            t = i / 8
            x = (1 - t) ** 3 * p0[0] + 3 * (1 - t) ** 2 * t * p1[0] + 3 * (1 - t) * t * t * p2[0] + t ** 3 * p3[0]
            y = (1 - t) ** 3 * p0[1] + 3 * (1 - t) ** 2 * t * p1[1] + 3 * (1 - t) * t * t * p2[1] + t ** 3 * p3[1]
            self.cur.append(self._pt((x, y)))

    def _qCurveToOne(self, p1, p2):
        p0 = self._last_raw
        for i in range(1, 9):
            t = i / 8
            x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0]
            y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]
            self.cur.append(self._pt((x, y)))

    def _closePath(self):
        if len(self.cur) > 2:
            self.polys.append(self.cur)
        self.cur = []

    # BasePen keeps the current point; remember the raw one for curves.
    def moveTo(self, p):
        self._last_raw = p
        super().moveTo(p)

    def lineTo(self, p):
        super().lineTo(p)
        self._last_raw = p

    def curveTo(self, *points):
        super().curveTo(*points)
        self._last_raw = points[-1]

    def qCurveTo(self, *points):
        super().qCurveTo(*points)
        if points[-1] is not None:
            self._last_raw = points[-1]


def render(word, font_path, tt, hbfont, upem):
    buf = hb.Buffer()
    buf.add_str(word)
    buf.guess_segment_properties()
    hb.shape(hbfont, buf)
    glyphset = tt.getGlyphSet()
    order = tt.getGlyphOrder()
    scale = HEIGHT / upem
    width = sum(p.x_advance for p in buf.glyph_positions) * scale + 60
    size = (int(width) + 60, int(HEIGHT * 2.2))
    img = Image.new("L", size, 0)
    draw = ImageDraw.Draw(img)
    x = 30 / scale
    base = HEIGHT * 1.4
    polys = []
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        pen = FlatPen(glyphset, x + pos.x_offset, scale, base - pos.y_offset * scale)
        glyphset[order[info.codepoint]].draw(pen)
        polys += pen.polys
        x += pos.x_advance
    # Even-odd fill: holes (the eye of «ه», «م») stay open.
    mask = np.zeros(size[::-1], dtype=bool)
    for poly in polys:
        layer = Image.new("1", size, 0)
        ImageDraw.Draw(layer).polygon(poly, fill=1)
        mask ^= np.array(layer, dtype=bool)
    return mask


def trace(mask):
    """Skeleton pixels to strokes: each connected part, walked from an end."""
    skel = skeletonize(mask)
    labels, count = label(skel, connectivity=2, return_num=True)
    parts = []
    for n in range(1, count + 1):
        ys, xs = np.nonzero(labels == n)
        if len(xs) < 3:
            continue
        pixels = set(zip(xs.tolist(), ys.tolist()))

        def neighbours(p):
            x, y = p
            return [(x + dx, y + dy) for dx in (-1, 0, 1) for dy in (-1, 0, 1)
                    if (dx or dy) and (x + dx, y + dy) in pixels]

        # One stroke per part, as a pen would draw it without lifting: a walk over the
        # skeleton from its rightmost end that goes back along a branch to reach the next one.
        # Short spurs (thinning noise) are left out.
        ends = [p for p in pixels if len(neighbours(p)) <= 1]
        start = max(ends or pixels, key=lambda p: (p[0], -p[1]))
        seen = {start}
        walk = [start]

        def branch_length(p, came, limit=6):
            n, prev, cur = 0, came, p
            while n < limit:
                nxt = [q for q in neighbours(cur) if q != prev and q not in seen]
                if len(nxt) != 1:
                    return n + (limit if len(nxt) > 1 else 0)
                prev, cur, n = cur, nxt[0], n + 1
            return n

        stack = [(start, None)]
        while stack:
            cur, prev = stack[-1]
            nxt = [q for q in neighbours(cur) if q not in seen]
            if prev is not None and nxt:
                d = (cur[0] - prev[0], cur[1] - prev[1])
                nxt.sort(key=lambda q: -((q[0] - cur[0]) * d[0] + (q[1] - cur[1]) * d[1]))
            nxt = [q for q in nxt if branch_length(q, cur) >= 5 or len(nxt) == 1]
            if nxt:
                q = nxt[0]
                seen.add(q)
                walk.append(q)
                stack.append((q, cur))
            else:
                stack.pop()
                if stack:
                    walk.append(stack[-1][0])
        # The walk back after the last branch is not drawn.
        last = max(i for i, p in enumerate(walk) if walk.index(p) == i)
        strokes = [walk[: last + 1][::2]] if last >= 3 else []
        if strokes:
            parts.append((max(xs), len(xs), strokes))
    if not parts:
        return []
    big = max(p[1] for p in parts)
    bodies = sorted([p for p in parts if p[1] >= big * 0.15], key=lambda p: -p[0])
    dots = sorted([p for p in parts if p[1] < big * 0.15], key=lambda p: -p[0])
    ordered = [s for p in bodies for s in p[2]] + [s for p in dots for s in p[2]]
    # A writing pace: 8 ms a point, 120 ms between strokes.
    out, t = [], 0
    for stroke in ordered:
        points = []
        for x, y in stroke:
            points.append([float(x), float(y), t])
            t += 8
        out.append(points)
        t += 120
    return out


def main():
    words_path, out_path, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
    fonts = sys.argv[4:]
    words = []
    for line in open(words_path, encoding="utf-8"):
        w = line.split("\t")[0].strip()
        if 2 <= len(w) <= 7 and "‌" not in w and all("؀" <= c <= "ۿ" for c in w):
            words.append(w)
        if len(words) >= 4000:
            break
    random.seed(11)
    chosen = random.sample(words, count)
    samples = []
    loaded = []
    for path in fonts:
        tt = TTFont(path)
        data = open(path, "rb").read()
        face = hb.Face(data)
        loaded.append((path, tt, hb.Font(face), face.upem))
    for i, word in enumerate(chosen):
        path, tt, hbfont, upem = loaded[i % len(loaded)]
        mask = render(word, path, tt, hbfont, upem)
        strokes = trace(mask)
        if not strokes:
            continue
        h, w = mask.shape
        samples.append({"word": word, "font": path.split("/")[-1], "strokes": strokes, "width": w, "height": h})
    json.dump(samples, open(out_path, "w", encoding="utf-8"), ensure_ascii=False)
    print(f"{len(samples)} samples, {sum(len(s['strokes']) for s in samples) / max(1, len(samples)):.1f} strokes a word")


if __name__ == "__main__":
    main()
