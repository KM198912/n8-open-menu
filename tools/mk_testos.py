#!/usr/bin/env python3
"""Generate a minimal test OS.BIN for the EverDrive N8 clone.

Purpose: find out whether the clone's bootloader starts a plain (unscrambled)
OS.BIN. Uses only our own code, nothing from Krikzz or the clone firmware.

Layout (taken from Krikzz's plain OS v1.26, 57344 bytes):
  0x0000-0x1FFF  CHR (8 KB)          -> zeros here (no font needed)
  0x2000-0x3FFF  unused, 0xAA fill   -> same fill as the original
  0x4000-0x5FFF  unused, 0x00 fill
  0x6000-0xDFFF  PRG, 32 KB at CPU $8000-$FFFF, vectors at $FFFA

Test program at $8000: rendering off, palette $3F00 = red ($16), VRAM address
left at $3F00 so the backdrop shows that colour, then loop forever.
The rest of PRG is a NOP sled ending in JMP $8000, so a start at any other
address still reaches the test.

Result on the TV:
  red screen         -> bootloader accepts plain code
  anything else      -> bootloader decrypts/unpacks (or a different layout)

Usage: python mk_testos.py [output path]   (default: ../test/OS.BIN)
"""
import os
import sys

SIZE = 0xE000
PRG_FILE = 0x6000          # file offset of CPU $8000
PRG_CPU = 0x8000
COLOR = 0x16               # NES palette: red


def cpu(addr):
    return PRG_FILE + (addr - PRG_CPU)


def build_program():
    p = bytearray()
    p += bytes([0x78])                    # SEI
    p += bytes([0xD8])                    # CLD
    p += bytes([0xA2, 0xFF, 0x9A])        # LDX #$FF / TXS
    p += bytes([0xA9, 0x00])              # LDA #$00
    p += bytes([0x8D, 0x00, 0x20])        # STA $2000  (NMI off)
    p += bytes([0x8D, 0x01, 0x20])        # STA $2001  (rendering off)
    p += bytes([0xA9, 0x40])              # LDA #$40
    p += bytes([0x8D, 0x17, 0x40])        # STA $4017  (APU frame IRQ off)
    for _ in range(2):                    # wait two vblanks (PPU warm-up)
        p += bytes([0x2C, 0x02, 0x20])    #   BIT $2002
        p += bytes([0x10, 0xFB])          #   BPL -5
    p += bytes([0xAD, 0x02, 0x20])        # LDA $2002  (reset address latch)
    p += bytes([0xA9, 0x3F, 0x8D, 0x06, 0x20])   # $2006 = $3F
    p += bytes([0xA9, 0x00, 0x8D, 0x06, 0x20])   # $2006 = $00
    p += bytes([0xA9, COLOR, 0x8D, 0x07, 0x20])  # $2007 = colour
    p += bytes([0xA9, 0x3F, 0x8D, 0x06, 0x20])   # back to $3F00 so the
    p += bytes([0xA9, 0x00, 0x8D, 0x06, 0x20])   # backdrop shows it
    loop = PRG_CPU + len(p)
    p += bytes([0x4C, loop & 0xFF, loop >> 8])   # loop: JMP loop
    rti = PRG_CPU + len(p)
    p += bytes([0x40])                    # RTI (for NMI/IRQ vectors)
    return p, rti


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "test", "OS.BIN")

    img = bytearray(SIZE)
    img[0x2000:0x4000] = b"\xAA" * 0x2000

    # PRG: NOP sled, test program at $8000, JMP $8000 at $FFF0, vectors
    img[PRG_FILE:SIZE] = b"\xEA" * (SIZE - PRG_FILE)
    prog, rti = build_program()
    img[cpu(0x8000):cpu(0x8000) + len(prog)] = prog
    img[cpu(0xFFF0):cpu(0xFFF3)] = bytes([0x4C, 0x00, 0x80])
    vec = [rti, 0x8000, rti]              # NMI, RESET, IRQ
    for i, v in enumerate(vec):
        img[cpu(0xFFFA) + 2 * i] = v & 0xFF
        img[cpu(0xFFFA) + 2 * i + 1] = v >> 8

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    tmp = out + ".tmp"
    with open(tmp, "wb") as f:
        f.write(img)
    os.replace(tmp, out)
    print("wrote %s (%d bytes), program %d bytes at $8000" % (out, len(img), len(prog)))


if __name__ == "__main__":
    main()
