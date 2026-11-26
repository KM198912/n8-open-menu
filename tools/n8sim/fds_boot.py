#!/usr/bin/env python3
"""Boot an FDS disk image with the real (patched) BIOS on a model of
cores/nrom/map_fds.v - the check that the BIOS patch, the block table and
the core's disk timing work together, before any SD card is swapped.

Usage:
  python fds_boot.py DISKSYS.ROM GAME.fds [--frames N] [--side N]

Memory is set up as the menu does it: patched BIOS at PRG SRAM $08000,
side 0 in the save SRAM at $00000, sides 1-3 at PRG $20000/$30000/$40000,
block tables from fdsdisk.block_table.
NTSC timing only (the PAL correction is covered by cores/tb/tb_fds.v).
The CPU model uses base cycle counts (no page-cross or branch penalties),
so the transfer timing here is slightly optimistic.

Prints: both nametables as text (BIOS/Nintendo font: 0-9, A-Z), whether the
game's code was reached, the blocks the BIOS read, and lost bytes (a new
transfer while the previous one was not yet taken).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cpu6502 import CPU            # noqa: E402
from n8hw import PPU               # noqa: E402
import fdsdisk                     # noqa: E402

LEADIN, GAP = 3537, 122
SWAP_HOLD, SWAP_EJECT = 1600000, 1790000      # CPU cycles (map_fds.v)
SIDE_END = 65500
ST_STOP, ST_LEAD, ST_BLK, ST_CRC, ST_GAP, ST_END, ST_WR = range(7)


class FDSPPU(PPU):
    def __init__(self, core):
        super().__init__()
        self.core = core
        self.one_screen = False

    def nt_index(self, a):
        a &= 0x0FFF
        if self.core.ctl & 0x08:                     # horizontal: A11
            return ((a >> 1) & 0x400) | (a & 0x3FF)
        return a & 0x7FF                             # vertical: A10


class FDSBoard:
    """Python model of map_fds.v (same constants and rules) + CPU RAM + PPU."""

    def __init__(self, prg, tables, side=0, ram=None, log=print, sram=None):
        """prg: 512 KB PRG SRAM image, sram: 256 KB save SRAM image (sides
        0-2), tables: per side the block table (list of offsets ending in
        $FFFF), ram: CPU RAM to share."""
        self.log = log
        self.ram = ram if ram is not None else bytearray(0x800)
        self.prg = prg
        self.sram = sram if sram is not None else bytearray(256 * 1024)
        self.chr = bytearray(0x2000)
        self.tables = [list(t) for t in tables]
        self.side = side
        self.nsides = sum(1 for t in self.tables if t and t[0] != 0xFFFF)
        self.nodisk = False
        # pad 1: the console side (joy = buttons held, A=1 ... Right=$80) and
        # what the core reads along (side swap: Select + Down held)
        self.joy = 0
        self.joy_shift = 0
        self.pad_stb = False
        self.pad_n = 8
        self.pad_sh = 0
        self.pad_btn = 0
        self.sw_cnt = 0
        self.sw_arm = True
        self.eject = False
        self.ej_cnt = 0
        self.swaps = []
        self.ppu = FDSPPU(self)
        self.ppu.chr_read = lambda a: self.chr[a & 0x1FFF]
        self.ppu.chr_write = self._chr_write
        self.ppu.warn = None
        # core state
        self.ctl = 0x26
        self.io_en = False
        self.t_rel = self.t_cnt = 0
        self.t_rep = self.t_en = self.t_irq = False
        self.xfer = False
        self.ph = ST_STOP
        self.hcnt = 0
        self.blk = 0
        self.bstart = 0
        self.ptr = 0
        self.sync = False
        self.ovr = False
        self.rd_off = 0
        self.bacc = 0
        self.sess = False
        self.wfirst = False
        self.wskip = False
        self.wstart = self.wcnt = 0
        # statistics
        self.lost = 0
        self.blocks_read = []
        self.written = []

    def _chr_write(self, a, v):
        self.chr[a & 0x1FFF] = v

    def tbl(self, i):
        t = self.tables[self.side]
        return t[i] if i < len(t) else 0xFFFF

    # ------------------------------------------------------------ core timing
    def no_disk(self):
        return self.nodisk or self.eject

    def running(self):
        return (self.ctl & 0x03) == 0x01 and not self.no_disk()

    def set_xfer(self, data_byte):
        if self.xfer and data_byte:
            self.lost += 1
        self.xfer = True

    def advance(self, n):
        if not (self.pad_btn & 0x04 and self.pad_btn & 0x20):
            self.sw_cnt, self.sw_arm = 0, True
        elif self.sw_arm and not self.eject:
            self.sw_cnt += n
            if self.sw_cnt > SWAP_HOLD:
                self.sw_arm, self.eject, self.ej_cnt = False, True, 0
                self.ph, self.sync = ST_STOP, False
        if self.eject:
            self.ej_cnt += n
            if self.ej_cnt > SWAP_EJECT:
                self.eject = False
                self.side = 0 if self.side + 1 >= self.nsides else self.side + 1
                self.swaps.append(self.side)
        if self.io_en and self.t_en:
            left = n
            while left > 0:
                if self.t_cnt >= left:
                    self.t_cnt -= left
                    left = 0
                else:
                    left -= self.t_cnt + 1
                    self.t_irq = True
                    self.t_cnt = self.t_rel
                    if not self.t_rep:
                        self.t_en = False
                        break
        self.bacc += 3 * n
        while self.bacc >= 448:
            self.bacc -= 448
            self.byte_tick()

    def byte_tick(self):
        if not self.io_en:
            return
        if not self.ctl & 0x04 and self.ctl & 0x40:
            self.xfer = True                         # write mode: every byte time
        if not self.running():
            if self.ph != ST_WR:
                self.ph = ST_STOP
                self.sync = False
            return
        ph = self.ph
        if ph == ST_STOP:
            self.ph, self.hcnt, self.blk, self.bstart = ST_LEAD, LEADIN, 0, 0
        elif ph in (ST_LEAD, ST_GAP):
            if self.sync:
                self.set_xfer(False)
            if self.hcnt == 1:
                if self.tbl(self.blk + 1) == 0xFFFF:
                    self.ph = ST_END
                else:
                    self.ph = ST_BLK
                    self.ptr = self.bstart
                    self.ovr = False
                    if self.ctl & 0x40 and self.ctl & 0x04:
                        self.sync = True
            self.hcnt -= 1
        elif ph == ST_BLK:
            if self.sync:
                if self.xfer:
                    self.ovr = True
                self.set_xfer(True)
                self.rd_off = self.ptr
            if self.ptr + 1 >= self.tbl(self.blk + 1):
                self.ph, self.hcnt = ST_CRC, 2
            self.ptr += 1
        elif ph == ST_CRC:
            if self.sync:
                self.set_xfer(False)
            if self.hcnt == 1:
                self.ph, self.hcnt = ST_GAP, GAP
                self.bstart = self.tbl(self.blk + 1)
                self.blk += 1
            else:
                self.hcnt -= 1
        elif ph == ST_END:
            if self.sync:
                self.set_xfer(False)

    def irq_line(self):
        return self.t_irq or (self.ctl & 0x80 and self.xfer)

    # ------------------------------------------------------------ bus
    def wr_off(self):
        return self.wstart + self.wcnt

    def disk_loc(self, off, a):
        """(memory, index) of the window byte: CPU A9-A0, the core's page"""
        mem, base = side_mem(self.prg, self.sram, self.side)
        return mem, base + (off & 0xFC00) + (a & 0x3FF)

    def read(self, a):
        if a < 0x2000:
            return self.ram[a & 0x7FF]
        if a < 0x4000:
            return self.ppu.read(a & 7)
        if a == 0x4030:
            v = (0x80 if self.xfer else 0) | (0x40 if self.ph == ST_END else 0) | (self.ctl & 0x08) | \
                (0x10 if self.ovr else 0) | (1 if self.t_irq else 0)
            self.t_irq = False
            return v
        if a == 0x4031:
            self.xfer = False
            return 0x00
        if a == 0x4016:
            if self.pad_stb:
                v = self.joy & 1
            else:
                v = self.joy_shift & 1
                self.joy_shift = (self.joy_shift >> 1) | 0x80
                if self.pad_n != 8:                  # the core reads along
                    self.pad_sh = (self.pad_sh >> 1) | (v << 7)
                    if self.pad_n == 7:
                        self.pad_btn = self.pad_sh
                    self.pad_n += 1
            return 0x40 | v
        if a == 0x4032:
            ready = self.io_en and self.running() and self.ph not in (ST_STOP, ST_END)
            nd = 1 if self.no_disk() else 0
            return 0x40 | (nd << 2) | (0 if ready else 2) | nd
        if a == 0x4033:
            return 0x80
        if 0x5700 <= a <= 0x570F:
            r, w = self.rd_off, self.wr_off()
            return [0xAE, r & 0xFF, 0x58 | ((r >> 8) & 3), 0x60,
                    0x8D, w & 0xFF, 0x5C | ((w >> 8) & 3), 0x60,
                    0x8D, 0x0F, 0x57, 0x4C, 0xA3, 0xE7, 0xEA, 0xEA][a - 0x5700]
        if 0x5800 <= a < 0x5C00:
            self.xfer = False
            if self.ph != ST_WR and self.sync:
                self.blocks_read.append(self.blk) if not self.blocks_read or self.blocks_read[-1] != self.blk else None
            mem, i = self.disk_loc(self.rd_off, a)
            return mem[i]
        if 0x6000 <= a < 0xE000:
            return self.prg[a - 0x6000]
        if a >= 0xE000:
            return self.prg[0x8000 + a - 0xE000]
        return a >> 8

    def write(self, a, v):
        if a < 0x2000:
            self.ram[a & 0x7FF] = v
        elif a < 0x4000:
            self.ppu.write(a & 7, v)
        elif a == 0x4016:
            if self.pad_stb and not v & 1:
                self.pad_n = 0
                self.joy_shift = self.joy
            self.pad_stb = bool(v & 1)
        elif 0x4020 <= a <= 0x4026:
            r = a & 0xF
            if r == 0:
                self.t_rel = (self.t_rel & 0xFF00) | v
            elif r == 1:
                self.t_rel = (self.t_rel & 0xFF) | (v << 8)
            elif r == 2 and self.io_en:
                self.t_rep, self.t_en, self.t_irq = bool(v & 1), bool(v & 2), False
                if v & 2:
                    self.t_cnt = self.t_rel
            elif r == 3:
                self.io_en = bool(v & 1)
                if not self.io_en:
                    self.t_en = self.t_irq = self.xfer = False
            elif r == 4 and self.io_en:
                self.xfer = False
            elif r == 5 and self.io_en:
                self.write_ctl(v)
        elif a == 0x570F:
            self.wskip = self.sess                   # flush byte follows
        elif 0x5C00 <= a < 0x6000:
            self.xfer = False
            if self.sess:
                if self.wfirst:
                    self.wfirst = False
                elif self.wskip:
                    self.wskip = False               # not on the disk
                elif self.wr_off() < SIDE_END:
                    mem, i = self.disk_loc(self.wr_off(), a)
                    mem[i] = v
                    self.wcnt += 1
        elif 0x6000 <= a < 0xE000:
            self.prg[a - 0x6000] = v

    def write_ctl(self, v):
        old_sess = self.sess
        self.ctl = v
        if not v & 0x40:
            self.sync = False
            self.xfer = False                        # the flag reads 0 without bit 6
        if (v & 0x02 or not v & 0x01) and self.ph != ST_WR:
            self.ph, self.sync = ST_STOP, False          # head back to the start
        if not old_sess and not v & 0x04 and v & 0x40:
            self.sess, self.wfirst, self.wcnt, self.wskip = True, True, 0, False
            if self.ph == ST_CRC:
                self.wstart = self.tbl(self.blk + 1)
                self.blk += 1
                self.bstart = self.wstart
            else:
                self.wstart = self.bstart
            self.ph = ST_WR
        if old_sess and (v & 0x04 or not v & 0x40):
            self.sess = False
            if self.wfirst or self.wcnt == 0:
                self.ph, self.hcnt = ST_GAP, GAP
            else:
                self.ph, self.hcnt = ST_CRC, 2
                end = self.wr_off()
                self.written.append((self.side, self.blk, self.wstart, end))
                if end != self.tbl(self.blk + 1):
                    t = self.tables[self.side]
                    del t[self.blk + 1:]
                    t += [end, 0xFFFF]


SIDE_BASE = (("sram", 0x00000), ("prg", 0x20000), ("prg", 0x30000), ("prg", 0x40000))


def side_mem(prg, sram, side):
    where, base = SIDE_BASE[side]
    return (sram if where == "sram" else prg), base


def side_bytes(prg, sram, side):
    mem, base = side_mem(prg, sram, side)
    return bytes(mem[base:base + fdsdisk.SIDE])


def build_prg(bios, sides):
    """PRG SRAM image, save SRAM image and tables as the menu builds them
    (fds.s)."""
    prg = bytearray(512 * 1024)
    sram = bytearray(256 * 1024)
    prg[0x8000:0xA000] = fdsdisk.patch_bios(bios)
    tables = []
    for i, s in enumerate(sides[:4]):
        mem, base = side_mem(prg, sram, i)
        mem[base:base + len(s)] = s
        tables.append(fdsdisk.block_table(s))
    return prg, sram, tables


def tables_from_core(words):
    """The 1024 entries the RAM code sent through $93 -> per side lists."""
    out = []
    for side in range(4):
        t = []
        for w in words[side * 256:(side + 1) * 256]:
            t.append(w)
            if w == 0xFFFF:
                break
        out.append(t)
    return out


FONT = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"


def nt_text(ppu, base):
    rows = []
    for r in range(30):
        line = ""
        for c in range(32):
            t = ppu.nt[ppu.nt_index(base + r * 32 + c)]
            line += FONT[t] if t < len(FONT) else ("." if t not in (0x24, 0x28, 0xFF, 0x00) else " ")
        rows.append(line.rstrip())
    while rows and not rows[-1]:
        rows.pop()
    return "\n".join(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bios")
    ap.add_argument("fds")
    ap.add_argument("--frames", type=int, default=900)
    ap.add_argument("--side", type=int, default=0)
    args = ap.parse_args()

    sides = fdsdisk.sides(open(args.fds, "rb").read())
    prg, sram, tables = build_prg(open(args.bios, "rb").read(), sides)
    board = FDSBoard(prg, tables, args.side, sram=sram)
    cpu = CPU(board)
    cpu.irq_line = board.irq_line
    cpu.reset()

    frame = 0
    next_vblank = 29780
    game_pc_frame = None
    while frame < args.frames and not cpu.halted:
        c = cpu.step()
        board.advance(c if c else 2)
        if cpu.cycles >= next_vblank:
            next_vblank += 29780
            frame += 1
            board.ppu.vblank = True
            if board.ppu.ctrl & 0x80:
                cpu.nmi_pending = True
        if game_pc_frame is None and 0x6000 <= cpu.pc < 0xE000:
            game_pc_frame = frame

    print("== nametable $2000")
    print(nt_text(board.ppu, 0x2000))
    print("== nametable $2800")
    print(nt_text(board.ppu, 0x2800))
    print("-" * 32)
    print("frames %d, PC $%04X%s" % (frame, cpu.pc, " HALTED" if cpu.halted else ""))
    print("game code first reached in frame:", game_pc_frame)
    print("blocks read (side %d):" % board.side, board.blocks_read[:80])
    print("blocks written:", board.written)
    print("lost bytes (transfer not taken in time):", board.lost)
    print("rendering %s, $4025 = $%02X" % ("on" if board.ppu.mask & 0x18 else "off", board.ctl))


if __name__ == "__main__":
    main()
