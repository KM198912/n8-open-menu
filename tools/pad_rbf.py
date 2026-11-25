#!/usr/bin/env python3
"""Pad a Quartus .rbf for the EverDrive N8 mapper loader.

The loader wants a size that is a multiple of 512, padded with 0xFF, and an
upper-case file name (NNN.RBF).

Usage: python pad_rbf.py <input.rbf> <number> [output dir]
       e.g. python pad_rbf.py ../cores/nrom/output_files/n8_nrom.rbf 100
       -> writes 100.RBF next to the input (or into output dir)
"""
import os
import sys

PREAMBLE = b"\x6A\xDE\xFF\x7F"     # seen at offset 0x10 in every working RBF
MIN_PAD = 256                      # 0xFF bytes after the bitstream (start-up clocks)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    src = sys.argv[1]
    num = int(sys.argv[2])
    if not 0 <= num <= 255:
        sys.exit("RBF number must be 0-255 (255 = menu core loaded by the BIOS, 254 = FDS)")
    outdir = sys.argv[3] if len(sys.argv) > 3 else os.path.dirname(os.path.abspath(src))

    data = open(src, "rb").read()
    if PREAMBLE not in data[:64]:
        print("warning: no Altera RBF preamble in the first 64 bytes - is this really an .rbf?")
    # At least MIN_PAD bytes of 0xFF: the CPLD only clocks the FPGA while
    # bytes are streamed, and the Cyclone II needs extra clocks after the
    # last configuration bit to start up. With 11 bytes of padding our core
    # never came up (2026-11-24); with 500 it did.
    pad = (-len(data)) % 512
    if pad < MIN_PAD:
        pad += 512
    data += b"\xFF" * pad

    out = os.path.join(outdir, "%03d.RBF" % num)
    tmp = out + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, out)
    print("wrote %s (%d bytes, %d bytes padding)" % (out, len(data), pad))


if __name__ == "__main__":
    main()
