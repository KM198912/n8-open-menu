#!/usr/bin/env python3
"""Generate a register-readout test OS.BIN for the EverDrive N8 clone.

Reads the FPGA register file (index -> $4400, value <- $4401) and prints the
values as hex on screen. Own code only, nothing from Krikzz or the clone.

Registers read: $00-$1F and $80-$9F (64 registers). Only reads; the index
write to $4400 is the only write to the cart registers.

Two snapshots, about one second apart:
  rows 2-9    first snapshot
  rows 12-19  second snapshot (values that change are status/counters)
Each row: register number of the first column, then 8 values.
  row 0..3 of a block -> $00,$08,$10,$18     row 4..7 -> $80,$88,$90,$98

Layout of OS.BIN as in mk_testos.py (PRG at file 0x6000 = CPU $8000).
The font is also uploaded to CHR RAM by the program, so the result does not
depend on how the bootloader handles the CHR block.

Usage: python mk_regdump.py [output path]   (default: ../test/OS.BIN)
"""
import os
import sys

SIZE = 0xE000
PRG_FILE = 0x6000
ORG = 0x8000

# ---------------------------------------------------------------- assembler
OPC = {
    ('LDA', 'imm'): 0xA9, ('LDA', 'zp'): 0xA5, ('LDA', 'abs'): 0xAD,
    ('LDA', 'abx'): 0xBD, ('LDA', 'aby'): 0xB9,
    ('LDX', 'imm'): 0xA2, ('LDY', 'imm'): 0xA0, ('LDY', 'zp'): 0xA4,
    ('STA', 'zp'): 0x85, ('STA', 'abs'): 0x8D, ('STA', 'aby'): 0x99,
    ('STA', 'abx'): 0x9D,
    ('CMP', 'imm'): 0xC9, ('CPX', 'imm'): 0xE0, ('CPY', 'imm'): 0xC0,
    ('ADC', 'imm'): 0x69, ('ADC', 'zp'): 0x65, ('AND', 'imm'): 0x29,
    ('ORA', 'imm'): 0x09, ('BIT', 'abs'): 0x2C, ('INC', 'zp'): 0xE6,
    ('JMP', 'abs'): 0x4C, ('JSR', 'abs'): 0x20,
    ('BPL', 'rel'): 0x10, ('BCC', 'rel'): 0x90, ('BNE', 'rel'): 0xD0,
    ('SEI', 'imp'): 0x78, ('CLD', 'imp'): 0xD8, ('CLC', 'imp'): 0x18,
    ('TXS', 'imp'): 0x9A, ('TXA', 'imp'): 0x8A, ('TAX', 'imp'): 0xAA,
    ('TAY', 'imp'): 0xA8, ('PHA', 'imp'): 0x48, ('PLA', 'imp'): 0x68,
    ('INX', 'imp'): 0xE8, ('DEX', 'imp'): 0xCA, ('DEY', 'imp'): 0x88,
    ('RTS', 'imp'): 0x60, ('RTI', 'imp'): 0x40, ('ASL', 'acc'): 0x0A,
    ('LSR', 'acc'): 0x4A,
}
SIZE_OF = {'imp': 1, 'acc': 1, 'imm': 2, 'zp': 2, 'rel': 2,
           'abs': 3, 'abx': 3, 'aby': 3}


class Asm:
    def __init__(self, org):
        self.org = org
        self.items = []          # (addr, mnem, mode, operand) or ('data', bytes)
        self.labels = {}
        self.pc = org

    def label(self, name):
        assert name not in self.labels, name
        self.labels[name] = self.pc

    def __call__(self, mnem, mode='imp', operand=None):
        assert (mnem, mode) in OPC, (mnem, mode)
        self.items.append((self.pc, mnem, mode, operand))
        self.pc += SIZE_OF[mode]

    def data(self, b):
        self.items.append((self.pc, 'data', None, bytes(b)))
        self.pc += len(b)

    def value(self, v):
        return self.labels[v] if isinstance(v, str) else v

    def assemble(self):
        out = bytearray()
        for addr, mnem, mode, operand in self.items:
            if mnem == 'data':
                out += operand
                continue
            out.append(OPC[(mnem, mode)])
            if mode in ('imp', 'acc'):
                continue
            v = self.value(operand)
            if mode == 'rel':
                d = v - (addr + 2)
                assert -128 <= d <= 127, ("branch out of range", addr, operand)
                out.append(d & 0xFF)
            elif SIZE_OF[mode] == 2:
                assert 0 <= v <= 0xFF, (mnem, mode, operand)
                out.append(v)
            else:
                out += bytes([v & 0xFF, v >> 8])
        return out


# ---------------------------------------------------------------- font
# tile 0 = blank, tiles 1..16 = hex digits 0..F (tile = nibble + 1)
GLYPHS = {
    '0': ["..XXX...", ".X...X..", ".X..XX..", ".X.X.X..", ".XX..X..", ".X...X..", "..XXX...", "........"],
    '1': ["...X....", "..XX....", "...X....", "...X....", "...X....", "...X....", "..XXX...", "........"],
    '2': ["..XXX...", ".X...X..", ".....X..", "....X...", "...X....", "..X.....", ".XXXXX..", "........"],
    '3': ["..XXX...", ".X...X..", ".....X..", "...XX...", ".....X..", ".X...X..", "..XXX...", "........"],
    '4': ["....X...", "...XX...", "..X.X...", ".X..X...", ".XXXXX..", "....X...", "....X...", "........"],
    '5': [".XXXXX..", ".X......", ".XXXX...", ".....X..", ".....X..", ".X...X..", "..XXX...", "........"],
    '6': ["...XX...", "..X.....", ".X......", ".XXXX...", ".X...X..", ".X...X..", "..XXX...", "........"],
    '7': [".XXXXX..", ".....X..", "....X...", "...X....", "..X.....", "..X.....", "..X.....", "........"],
    '8': ["..XXX...", ".X...X..", ".X...X..", "..XXX...", ".X...X..", ".X...X..", "..XXX...", "........"],
    '9': ["..XXX...", ".X...X..", ".X...X..", "..XXXX..", ".....X..", "....X...", "..XX....", "........"],
    'A': ["..XXX...", ".X...X..", ".X...X..", ".XXXXX..", ".X...X..", ".X...X..", ".X...X..", "........"],
    'B': [".XXXX...", ".X...X..", ".X...X..", ".XXXX...", ".X...X..", ".X...X..", ".XXXX...", "........"],
    'C': ["..XXX...", ".X...X..", ".X......", ".X......", ".X......", ".X...X..", "..XXX...", "........"],
    'D': [".XXXX...", ".X...X..", ".X...X..", ".X...X..", ".X...X..", ".X...X..", ".XXXX...", "........"],
    'E': [".XXXXX..", ".X......", ".X......", ".XXXX...", ".X......", ".X......", ".XXXXX..", "........"],
    'F': [".XXXXX..", ".X......", ".X......", ".XXXX...", ".X......", ".X......", ".X......", "........"],
}


def font_bytes():
    out = bytearray(16)                       # tile 0: blank
    for ch in "0123456789ABCDEF":
        rows = GLYPHS[ch]
        plane0 = bytes(int(r.replace('.', '0').replace('X', '1'), 2) for r in rows)
        out += plane0 + bytes(8)              # colour 1 only
    return out                                # 17 tiles = 272 bytes


# ---------------------------------------------------------------- program
BUF = 0x0300          # 128 bytes of snapshots
OFS, ROW16, ROW, PHI, PLO = 0x10, 0x11, 0x12, 0x13, 0x14


def build():
    a = Asm(ORG)
    a.label('reset')
    a('SEI'); a('CLD'); a('LDX', 'imm', 0xFF); a('TXS')
    a('LDA', 'imm', 0x00); a('STA', 'abs', 0x2000); a('STA', 'abs', 0x2001)
    a('LDA', 'imm', 0x40); a('STA', 'abs', 0x4017)
    a('JSR', 'abs', 'vwait'); a('JSR', 'abs', 'vwait')

    # palette: backdrop black, colours 1-3 white
    a('LDA', 'abs', 0x2002)
    a('LDA', 'imm', 0x3F); a('STA', 'abs', 0x2006)
    a('LDA', 'imm', 0x00); a('STA', 'abs', 0x2006)
    a('LDA', 'imm', 0x0F); a('STA', 'abs', 0x2007)
    a('LDA', 'imm', 0x30); a('STA', 'abs', 0x2007); a('STA', 'abs', 0x2007); a('STA', 'abs', 0x2007)

    # font -> CHR RAM $0000 (272 bytes)
    a('LDA', 'abs', 0x2002)
    a('LDA', 'imm', 0x00); a('STA', 'abs', 0x2006); a('STA', 'abs', 0x2006)
    a('LDX', 'imm', 0x00)
    a.label('fl1')
    a('LDA', 'abx', 'font'); a('STA', 'abs', 0x2007); a('INX'); a('BNE', 'rel', 'fl1')
    a.label('fl2')
    a('LDA', 'abx', 'font_hi'); a('STA', 'abs', 0x2007); a('INX')
    a('CPX', 'imm', 16); a('BNE', 'rel', 'fl2')

    # clear nametable 0 incl. attributes ($2000-$23FF)
    a('LDA', 'abs', 0x2002)
    a('LDA', 'imm', 0x20); a('STA', 'abs', 0x2006)
    a('LDA', 'imm', 0x00); a('STA', 'abs', 0x2006)
    a('LDY', 'imm', 4); a('LDX', 'imm', 0)
    a.label('cl')
    a('STA', 'abs', 0x2007); a('INX'); a('BNE', 'rel', 'cl'); a('DEY'); a('BNE', 'rel', 'cl')

    # snapshot 1, wait ~1 s, snapshot 2
    a('LDA', 'imm', 0); a('STA', 'zp', OFS); a('JSR', 'abs', 'snap')
    a('LDX', 'imm', 60)
    a.label('dl')
    a('JSR', 'abs', 'vwait'); a('DEX'); a('BNE', 'rel', 'dl')
    a('LDA', 'imm', 64); a('STA', 'zp', OFS); a('JSR', 'abs', 'snap')

    a('JSR', 'abs', 'draw')

    # show background
    a('JSR', 'abs', 'vwait')
    a('LDA', 'abs', 0x2002)
    a('LDA', 'imm', 0); a('STA', 'abs', 0x2005); a('STA', 'abs', 0x2005)
    a('STA', 'abs', 0x2000)
    a('LDA', 'imm', 0x0A); a('STA', 'abs', 0x2001)
    a.label('forever')
    a('JMP', 'abs', 'forever')

    # wait for vblank
    a.label('vwait')
    a('BIT', 'abs', 0x2002); a('BPL', 'rel', 'vwait'); a('RTS')

    # read 64 registers into BUF+OFS: i<32 -> reg i, else reg i+$60
    a.label('snap')
    a('LDX', 'imm', 0)
    a.label('sn1')
    a('TXA'); a('CMP', 'imm', 32); a('BCC', 'rel', 'sn2')
    a('CLC'); a('ADC', 'imm', 0x60)
    a.label('sn2')
    a('STA', 'abs', 0x4400)
    a('LDA', 'abs', 0x4401)
    a('PHA'); a('TXA'); a('CLC'); a('ADC', 'zp', OFS); a('TAY'); a('PLA')
    a('STA', 'aby', BUF)
    a('INX'); a('CPX', 'imm', 64); a('BNE', 'rel', 'sn1')
    a('RTS')

    # draw 16 rows: row16 0-7 -> screen rows 2-9, 8-15 -> rows 12-19
    a.label('draw')
    a('LDA', 'imm', 0); a('STA', 'zp', ROW16)
    a.label('dr1')
    a('LDA', 'zp', ROW16); a('CLC'); a('ADC', 'imm', 2)
    a('LDY', 'zp', ROW16); a('CPY', 'imm', 8); a('BCC', 'rel', 'dr2')
    a('CLC'); a('ADC', 'imm', 2)
    a.label('dr2')
    a('STA', 'zp', ROW)
    a('LSR', 'acc'); a('LSR', 'acc'); a('LSR', 'acc')
    a('CLC'); a('ADC', 'imm', 0x20); a('STA', 'zp', PHI)
    a('LDA', 'zp', ROW); a('AND', 'imm', 7)
    for _ in range(5):
        a('ASL', 'acc')
    a('ORA', 'imm', 2); a('STA', 'zp', PLO)
    a('LDA', 'abs', 0x2002)
    a('LDA', 'zp', PHI); a('STA', 'abs', 0x2006)
    a('LDA', 'zp', PLO); a('STA', 'abs', 0x2006)
    # label: (row16 & 7) * 8, +$60 from 32 on
    a('LDA', 'zp', ROW16); a('AND', 'imm', 7)
    a('ASL', 'acc'); a('ASL', 'acc'); a('ASL', 'acc')
    a('CMP', 'imm', 32); a('BCC', 'rel', 'dr3')
    a('CLC'); a('ADC', 'imm', 0x60)
    a.label('dr3')
    a('JSR', 'abs', 'puthex')
    a('LDA', 'imm', 0); a('STA', 'abs', 0x2007)
    # 8 values from BUF + row16*8
    a('LDA', 'zp', ROW16); a('ASL', 'acc'); a('ASL', 'acc'); a('ASL', 'acc'); a('TAX')
    a('LDY', 'imm', 8)
    a.label('dr4')
    a('LDA', 'abx', BUF); a('JSR', 'abs', 'puthex')
    a('LDA', 'imm', 0); a('STA', 'abs', 0x2007)
    a('INX'); a('DEY'); a('BNE', 'rel', 'dr4')
    a('INC', 'zp', ROW16); a('LDA', 'zp', ROW16); a('CMP', 'imm', 16)
    a('BNE', 'rel', 'dr1_far')
    a('RTS')
    a.label('dr1_far')
    a('JMP', 'abs', 'dr1')

    # A -> two hex tiles at the current PPU address (keeps X, Y)
    a.label('puthex')
    a('PHA')
    a('LSR', 'acc'); a('LSR', 'acc'); a('LSR', 'acc'); a('LSR', 'acc')
    a('CLC'); a('ADC', 'imm', 1); a('STA', 'abs', 0x2007)
    a('PLA'); a('AND', 'imm', 0x0F)
    a('CLC'); a('ADC', 'imm', 1); a('STA', 'abs', 0x2007)
    a('RTS')

    a.label('nmi')
    a('RTI')

    f = font_bytes()
    a.label('font')
    a.data(f[:256])
    a.label('font_hi')
    a.data(f[256:])
    return a, f


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "test", "OS.BIN")

    a, font = build()
    prog = a.assemble()
    assert ORG + len(prog) < 0xFFF0, "program too large"

    img = bytearray(SIZE)
    img[0:len(font)] = font                          # CHR block: same font
    img[0x2000:0x4000] = b"\xAA" * 0x2000
    img[PRG_FILE:SIZE] = b"\xEA" * (SIZE - PRG_FILE)
    img[PRG_FILE:PRG_FILE + len(prog)] = prog

    def cpu(addr):
        return PRG_FILE + addr - ORG
    img[cpu(0xFFF0):cpu(0xFFF3)] = bytes([0x4C, ORG & 0xFF, ORG >> 8])
    for i, v in enumerate([a.labels['nmi'], a.labels['reset'], a.labels['nmi']]):
        img[cpu(0xFFFA) + 2 * i] = v & 0xFF
        img[cpu(0xFFFA) + 2 * i + 1] = v >> 8

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    tmp = out + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(img)
    os.replace(tmp, out)
    print("wrote %s, program %d bytes ($%04X-$%04X)" % (out, len(prog), ORG, ORG + len(prog) - 1))


if __name__ == "__main__":
    main()
