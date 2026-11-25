#!/usr/bin/env python3
"""Generate BIOS dump "games" (.nes) for the EverDrive N8 clone.

Needs the dump helper core (cores/biosdump, DUMP_HELPER=1) as the mapper 0
core. Each ROM copies one 8 KB chunk of the BIOS flash window ($8000-$FFFF in
flash mode) into the battery-backed save RAM at $6000. After a reset the menu
stores the save RAM on the SD card like any battery save.

STRICTLY READ-ONLY: the program contains no flash command sequence. The only
writes are to RAM, the save RAM, $5000 (core: release PRG RAM) and CPLD
register $09 bits 1:0 (01 = menu RAM, 10 = flash at $8000), the same
switch Krikzz's menu uses for its read-only CFI query.

Sequence (runs from CPU RAM at $0300, interrupts off):
  1. $5000 = 1          core stops driving PRG RAM at $8000
  2. reg $09 = xx10     CPLD shows the BIOS flash at $8000
  3. copy 8 KB  $8000+chunk*$2000 -> $6000
  4. reg $09 = xx01     back to normal
  5. $5000 = 0          PRG RAM back
Result on screen (backdrop colour):
  green   copied data varies (looks like real content)
  yellow  all 8 KB identical (flash probably not visible -> report this)
  blue    still running / never returned

Usage: python mk_biosdump.py [outdir]   -> biosdump0.nes .. biosdump3.nes
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mk_regdump as base          # reuse the mini assembler

base.OPC.update({
    ('LDA', 'izy'): 0xB1, ('STA', 'izy'): 0x91, ('CMP', 'izy'): 0xD1,
    ('BEQ', 'rel'): 0xF0, ('ORA', 'imm'): 0x09, ('INY', 'imp'): 0xC8,
})
base.SIZE_OF['izy'] = 2
Asm = base.Asm

RAM_RUN = 0x0300
SRC, DST, CNT = 0x00, 0x02, 0x04

GREEN, YELLOW, BLUE = 0x2A, 0x28, 0x12


def ram_routine():
    """The part that runs from CPU RAM while the flash is visible."""
    r = Asm(RAM_RUN)
    r('LDA', 'imm', 0x01); r('STA', 'abs', 0x5000)          # release PRG RAM
    r('LDA', 'imm', 0x09); r('STA', 'abs', 0x4400)          # select reg $09
    r('LDA', 'abs', 0x4401); r('AND', 'imm', 0xFC); r('ORA', 'imm', 0x02)
    r('STA', 'abs', 0x4401)                                  # flash at $8000
    r('LDX', 'imm', 0x20); r('LDY', 'imm', 0x00)            # 32 pages = 8 KB
    r.label('cp')
    r('LDA', 'izy', SRC); r('STA', 'izy', DST)
    r('INY'); r('BNE', 'rel', 'cp')
    r('INC', 'zp', SRC + 1); r('INC', 'zp', DST + 1)
    r('DEX'); r('BNE', 'rel', 'cp')
    r('LDA', 'abs', 0x4401); r('AND', 'imm', 0xFC); r('ORA', 'imm', 0x01)
    r('STA', 'abs', 0x4401)                                  # menu RAM again
    r('LDA', 'imm', 0x00); r('STA', 'abs', 0x5000)          # PRG RAM back
    r('RTS')
    return r.assemble()


def set_backdrop(a, colour):
    a('LDA', 'abs', 0x2002)
    a('LDA', 'imm', 0x3F); a('STA', 'abs', 0x2006)
    a('LDA', 'imm', 0x00); a('STA', 'abs', 0x2006)
    a('LDA', 'imm', colour); a('STA', 'abs', 0x2007)
    a('LDA', 'imm', 0x3F); a('STA', 'abs', 0x2006)
    a('LDA', 'imm', 0x00); a('STA', 'abs', 0x2006)


def program(chunk):
    blob = ram_routine()
    a = Asm(0x8000)
    a.label('reset')
    a('SEI'); a('CLD'); a('LDX', 'imm', 0xFF); a('TXS')
    a('LDA', 'imm', 0x00); a('STA', 'abs', 0x2000); a('STA', 'abs', 0x2001)
    a('LDA', 'imm', 0x40); a('STA', 'abs', 0x4017)
    a.label('v1'); a('BIT', 'abs', 0x2002); a('BPL', 'rel', 'v1')
    a.label('v2'); a('BIT', 'abs', 0x2002); a('BPL', 'rel', 'v2')
    set_backdrop(a, BLUE)

    # copy the RAM routine to $0300
    a('LDX', 'imm', 0x00)
    a.label('cpy')
    a('LDA', 'abx', 'blob'); a('STA', 'abx', RAM_RUN); a('INX')
    a('CPX', 'imm', len(blob)); a('BNE', 'rel', 'cpy')

    # pointers: source = $8000 + chunk*$2000, destination = $6000
    a('LDA', 'imm', 0x00); a('STA', 'zp', SRC); a('STA', 'zp', DST)
    a('LDA', 'imm', 0x80 + chunk * 0x20); a('STA', 'zp', SRC + 1)
    a('LDA', 'imm', 0x60); a('STA', 'zp', DST + 1)
    a('JSR', 'abs', RAM_RUN)

    # check: are all 8 KB equal to the first byte?
    a('LDA', 'imm', 0x00); a('STA', 'zp', DST)
    a('LDA', 'imm', 0x60); a('STA', 'zp', DST + 1)
    a('LDA', 'abs', 0x6000)
    a('LDX', 'imm', 0x20); a('LDY', 'imm', 0x00)
    a.label('ck')
    a('CMP', 'izy', DST); a('BNE', 'rel', 'varied')
    a('INY'); a('BNE', 'rel', 'ck')
    a('INC', 'zp', DST + 1); a('DEX'); a('BNE', 'rel', 'ck')
    set_backdrop(a, YELLOW)
    a('JMP', 'abs', 'done')
    a.label('varied')
    set_backdrop(a, GREEN)
    a.label('done')
    a('JMP', 'abs', 'done')

    a.label('nmi')
    a('RTI')
    a.label('blob')
    a.data(blob)
    return a


def build_nes(chunk):
    a = program(chunk)
    code = a.assemble()
    prg = bytearray(b"\xEA" * 0x8000)
    prg[0:len(code)] = code
    prg[0x7FF0:0x7FF3] = bytes([0x4C, 0x00, 0x80])
    nmi = a.labels['nmi']
    for i, v in enumerate([nmi, 0x8000, nmi]):
        prg[0x7FFA + 2 * i] = v & 0xFF
        prg[0x7FFB + 2 * i] = v >> 8
    header = bytes([0x4E, 0x45, 0x53, 0x1A,   # "NES^Z"
                    2,                        # 2 x 16 KB PRG
                    1,                        # 1 x 8 KB CHR
                    0x03,                     # vertical mirroring + battery, mapper 0
                    0x00]) + bytes(8)
    return header + bytes(prg) + bytes(0x2000), len(code)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "test")
    os.makedirs(outdir, exist_ok=True)
    for chunk in range(4):
        data, n = build_nes(chunk)
        out = os.path.join(outdir, "biosdump%d.nes" % chunk)
        tmp = out + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, out)
        print("wrote %s (chunk %d = flash window $%04X-$%04X, code %d bytes)"
              % (out, chunk, 0x8000 + chunk * 0x2000, 0x9FFF + chunk * 0x2000, n))


if __name__ == "__main__":
    main()
