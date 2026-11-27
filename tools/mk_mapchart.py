#!/usr/bin/env python3
"""Mapper chart for a release: 16 x 16 grid of iNES mappers 0-255.

  green   n8-open has a core            (cores/cores.txt)
  yellow  the original firmware lists it, n8-open has no core yet
                                        (docs/mappers.md, 151 mappers)
  white   neither
FDS (cores.txt entry 254 = MAPROUT $FE) is not a mapper cell; the legend
says whether it is supported. Version from the menu's title string.

Usage: python tools/mk_mapchart.py [out.png]
       default: test/release/n8-open-<version>-mappers.png
Needs Pillow.
"""
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CORES_TXT = os.path.join(ROOT, "cores", "cores.txt")
MAPPERS_MD = os.path.join(ROOT, "docs", "mappers.md")
MAIN_S = os.path.join(ROOT, "menu", "src", "main.s")
FDS = 254

GREEN = (88, 196, 120)
YELLOW = (242, 204, 76)
WHITE = (255, 255, 255)
GRID = (150, 150, 150)
TEXT = (20, 20, 20)
PANEL = (32, 36, 44)
PANEL_TEXT = (235, 235, 235)

CELL_W, CELL_H = 34, 24
LEGEND_H = 3 * 26 + 10


def ours():
    """mappers with a core in cores.txt (FDS included as 254)"""
    out = set()
    for n, raw in enumerate(open(CORES_TXT), 1):
        line = raw.split("#")[0].strip()
        if line:
            out.add(int(line.split()[0]))
    return out


def original():
    """the original firmware's list: the Mapper column of docs/mappers.md"""
    out = set()
    for raw in open(MAPPERS_MD, encoding="ascii"):
        m = re.match(r"\|\s*(\d+)\s*\|", raw)
        if m:
            out.add(int(m.group(1)))
    return out


def version():
    m = re.search(r'"N8-OPEN MENU ([0-9][0-9A-Za-z.\-]*)"', open(MAIN_S).read())
    if not m:
        sys.exit("main.s: title string \"N8-OPEN MENU x.y\" not found")
    return m.group(1)


def font(size):
    for name in ("DejaVuSans.ttf", "arial.ttf", "Arial.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    return ImageFont.load_default(size=size)


def main():
    ver = version()
    have = ours()
    orig = original()
    mappers = have - {FDS}
    missing = sorted(mappers - orig)
    if missing:
        print("note: n8-open cores for mappers not on the original's list:", missing)
    green = mappers
    yellow = orig - mappers
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        ROOT, "test", "release", "n8-open-%s-mappers.png" % ver)

    w, h = 16 * CELL_W + 1, 16 * CELL_H + 1 + LEGEND_H
    img = Image.new("RGB", (w, h), WHITE)
    d = ImageDraw.Draw(img)
    f_cell, f_leg, f_title, f_small = font(13), font(14), font(22), font(12)

    for n in range(256):
        x, y = (n % 16) * CELL_W, (n // 16) * CELL_H
        col = GREEN if n in green else YELLOW if n in yellow else WHITE
        d.rectangle([x, y, x + CELL_W, y + CELL_H], fill=col, outline=GRID)
        d.text((x + CELL_W / 2, y + CELL_H / 2), str(n), fill=TEXT, font=f_cell, anchor="mm")

    top = 16 * CELL_H + 1
    lw = 250
    rows = ((GREEN, "n8-open core: %d" % len(green)),
            (YELLOW, "original firmware only: %d" % len(yellow)),
            (WHITE, "neither: %d" % (256 - len(green) - len(yellow))))
    for i, (col, label) in enumerate(rows):
        y = top + 5 + i * 26
        d.rectangle([4, y, lw, y + 22], fill=col, outline=GRID)
        d.text((12, y + 11), label, fill=TEXT, font=f_leg, anchor="lm")
    d.rectangle([lw + 6, top + 5, w - 4, h - 5], fill=PANEL)
    cx = (lw + 6 + w - 4) / 2
    d.text((cx, top + 26), "n8-open %s" % ver, fill=PANEL_TEXT, font=f_title, anchor="mm")
    d.text((cx, top + 52), "EverDrive N8 clone - open firmware", fill=PANEL_TEXT, font=f_small, anchor="mm")
    d.text((cx, top + 70), "FDS (.fds disk images): %s" % ("supported" if FDS in have else "no"),
           fill=PANEL_TEXT, font=f_small, anchor="mm")

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    tmp = out + ".tmp.png"
    img.save(tmp)
    os.replace(tmp, out)
    print("wrote %s: %d n8-open, %d original only, FDS %s" % (
        os.path.relpath(out, ROOT), len(green), len(yellow), "yes" if FDS in have else "no"))


if __name__ == "__main__":
    main()
