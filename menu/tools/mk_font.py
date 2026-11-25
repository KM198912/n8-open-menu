#!/usr/bin/env python3
"""Generate menu/font.chr: 128 NES tiles, tile n = ASCII n, 5x7 glyphs.

Glyph table: 5 columns per character, bit 0 = top row. Only plane 0 is set,
so text uses palette colour 1.
"""
import os

GLYPHS = """
20 00 00 00 00 00|21 00 00 5F 00 00|22 00 07 00 07 00|23 14 7F 14 7F 14
24 24 2A 7F 2A 12|25 23 13 08 64 62|26 36 49 55 22 50|27 00 05 03 00 00
28 00 1C 22 41 00|29 00 41 22 1C 00|2A 08 2A 1C 2A 08|2B 08 08 3E 08 08
2C 00 50 30 00 00|2D 08 08 08 08 08|2E 00 60 60 00 00|2F 20 10 08 04 02
30 3E 51 49 45 3E|31 00 42 7F 40 00|32 42 61 51 49 46|33 21 41 45 4B 31
34 18 14 12 7F 10|35 27 45 45 45 39|36 3C 4A 49 49 30|37 01 71 09 05 03
38 36 49 49 49 36|39 06 49 49 29 1E|3A 00 36 36 00 00|3B 00 56 36 00 00
3C 00 08 14 22 41|3D 14 14 14 14 14|3E 41 22 14 08 00|3F 02 01 51 09 06
40 32 49 79 41 3E|41 7E 11 11 11 7E|42 7F 49 49 49 36|43 3E 41 41 41 22
44 7F 41 41 22 1C|45 7F 49 49 49 41|46 7F 09 09 01 01|47 3E 41 41 51 32
48 7F 08 08 08 7F|49 00 41 7F 41 00|4A 20 40 41 3F 01|4B 7F 08 14 22 41
4C 7F 40 40 40 40|4D 7F 02 04 02 7F|4E 7F 04 08 10 7F|4F 3E 41 41 41 3E
50 7F 09 09 09 06|51 3E 41 51 21 5E|52 7F 09 19 29 46|53 46 49 49 49 31
54 01 01 7F 01 01|55 3F 40 40 40 3F|56 1F 20 40 20 1F|57 7F 20 18 20 7F
58 63 14 08 14 63|59 03 04 78 04 03|5A 61 51 49 45 43|5B 00 00 7F 41 41
5C 02 04 08 10 20|5D 41 41 7F 00 00|5E 04 02 01 02 04|5F 40 40 40 40 40
60 00 01 02 04 00|61 20 54 54 54 78|62 7F 48 44 44 38|63 38 44 44 44 20
64 38 44 44 48 7F|65 38 54 54 54 18|66 08 7E 09 01 02|67 08 14 54 54 3C
68 7F 08 04 04 78|69 00 44 7D 40 00|6A 20 40 44 3D 00|6B 00 7F 10 28 44
6C 00 41 7F 40 00|6D 7C 04 18 04 78|6E 7C 08 04 04 78|6F 38 44 44 44 38
70 7C 14 14 14 08|71 08 14 14 18 7C|72 7C 08 04 04 08|73 48 54 54 54 20
74 04 3F 44 40 20|75 3C 40 40 20 7C|76 1C 20 40 20 1C|77 3C 40 30 40 3C
78 44 28 10 28 44|79 0C 50 50 50 3C|7A 44 64 54 4C 44|7B 00 08 36 41 00
7C 00 00 7F 00 00|7D 00 41 36 08 00|7E 08 04 08 10 08
"""


def main():
    tiles = bytearray(128 * 16)
    for item in GLYPHS.replace("\n", "|").split("|"):
        item = item.strip()
        if not item:
            continue
        v = [int(x, 16) for x in item.split()]
        code, cols = v[0], v[1:]
        for row in range(8):
            bits = 0
            for c, col in enumerate(cols):
                if col >> row & 1:
                    bits |= 0x80 >> (c + 1)      # glyph in pixel columns 1-5
            tiles[code * 16 + row] = bits
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "font.chr")
    with open(out, "wb") as f:
        f.write(tiles)
    print("wrote", os.path.normpath(out), len(tiles), "bytes")


if __name__ == "__main__":
    main()
