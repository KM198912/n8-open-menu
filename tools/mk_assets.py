#!/usr/bin/env python3
"""Generated images for the repository (committed, shown in README.md):

  assets/mappers.svg   mapper chart, 16 x 16 grid of iNES mappers 0-255:
                       green = n8-open core, yellow = original firmware only,
                       white = neither; FDS in the legend

Same data as the release PNG (tools/mk_mapchart.py: cores/cores.txt,
docs/mappers.md, version from the menu's title string). Deterministic: the
same data gives a byte-identical file, so git only sees real changes.
Run after changing cores/cores.txt or docs/mappers.md, commit the result.

Usage: python tools/mk_assets.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mk_mapchart as mc       # noqa: E402

ROOT = mc.ROOT
OUT = os.path.join(ROOT, "assets", "mappers.svg")

CELL_W, CELL_H = 34, 24
LEGEND_H = 3 * 26 + 10


def rgb(c):
    return "#%02X%02X%02X" % c


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def main():
    ver = mc.version()
    have = mc.ours()
    orig = mc.original()
    green = have - {mc.FDS}
    yellow = orig - green
    w, h = 16 * CELL_W + 1, 16 * CELL_H + 1 + LEGEND_H

    out = []
    out.append('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
               'viewBox="0 0 %d %d" font-family="DejaVu Sans, Arial, Helvetica, sans-serif">' % (w, h, w, h))
    out.append('<title>n8-open %s mapper chart</title>' % esc(ver))
    out.append('<rect x="0" y="0" width="%d" height="%d" fill="%s"/>' % (w, h, rgb(mc.WHITE)))
    for n in range(256):
        x, y = (n % 16) * CELL_W + 0.5, (n // 16) * CELL_H + 0.5
        col = mc.GREEN if n in green else mc.YELLOW if n in yellow else mc.WHITE
        out.append('<rect x="%.1f" y="%.1f" width="%d" height="%d" fill="%s" stroke="%s"/>'
                   % (x, y, CELL_W, CELL_H, rgb(col), rgb(mc.GRID)))
        out.append('<text x="%.1f" y="%.1f" font-size="13" text-anchor="middle" dominant-baseline="central" '
                   'fill="%s">%d</text>' % (x + CELL_W / 2, y + CELL_H / 2, rgb(mc.TEXT), n))

    top = 16 * CELL_H + 1
    lw = 250
    rows = ((mc.GREEN, "n8-open core: %d" % len(green)),
            (mc.YELLOW, "original firmware only: %d" % len(yellow)),
            (mc.WHITE, "neither: %d" % (256 - len(green) - len(yellow))))
    for i, (col, label) in enumerate(rows):
        y = top + 5 + i * 26
        out.append('<rect x="4.5" y="%.1f" width="%d" height="22" fill="%s" stroke="%s"/>'
                   % (y + 0.5, lw - 4, rgb(col), rgb(mc.GRID)))
        out.append('<text x="12" y="%.1f" font-size="14" dominant-baseline="central" fill="%s">%s</text>'
                   % (y + 11.5, rgb(mc.TEXT), esc(label)))
    out.append('<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>'
               % (lw + 6, top + 5, w - 4 - (lw + 6), h - 5 - (top + 5), rgb(mc.PANEL)))
    cx = (lw + 6 + w - 4) / 2
    for y, size, text in ((top + 26, 22, "n8-open %s" % ver),
                          (top + 52, 12, "EverDrive N8 clone - open firmware"),
                          (top + 70, 12, "FDS (.fds disk images): %s" % ("supported" if mc.FDS in have else "no"))):
        out.append('<text x="%.1f" y="%d" font-size="%d" text-anchor="middle" dominant-baseline="central" '
                   'fill="%s">%s</text>' % (cx, y, size, rgb(mc.PANEL_TEXT), esc(text)))
    out.append('</svg>')
    data = ("\n".join(out) + "\n").encode("ascii")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    if os.path.exists(OUT) and open(OUT, "rb").read() == data:
        print("%s unchanged" % os.path.relpath(OUT, ROOT))
        return
    tmp = OUT + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, OUT)
    print("wrote %s: %d n8-open, %d original only, FDS %s" % (
        os.path.relpath(OUT, ROOT), len(green), len(yellow), "yes" if mc.FDS in have else "no"))


if __name__ == "__main__":
    main()
