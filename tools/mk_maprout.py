#!/usr/bin/env python3
"""Build MAPROUT.BIN from cores/cores.txt (our own table, no original bytes).

Layout (Krikzz documentation): 512 bytes = two tables of 256 entries,
offset = iNES mapper number, value = RBF number, $FF = not supported.
  0x000-0x0FF  normal mappers
  0x100-0x1FF  save-state mappers (none yet: all $FF)
Entry $FF in both tables stays $FF (reserved for the OS).

Usage: python mk_maprout.py [cores.txt] [out MAPROUT.BIN]
"""
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "cores", "cores.txt")
out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "..", "test", "MAPROUT.BIN")

table = bytearray(b"\xFF" * 512)
for n, line in enumerate(open(src), 1):
    line = line.split("#")[0].strip()
    if not line:
        continue
    mapper, rbf = (int(x) for x in line.split())
    if not (0 <= mapper <= 254 and 0 <= rbf <= 253):
        sys.exit("%s:%d: mapper 0-254, RBF 0-253" % (src, n))
    table[mapper] = rbf
    print("mapper %3d -> %03d.RBF" % (mapper, rbf))

tmp = out + ".tmp"
with open(tmp, "wb") as f:
    f.write(table)
os.replace(tmp, out)
print("wrote", os.path.normpath(out))
