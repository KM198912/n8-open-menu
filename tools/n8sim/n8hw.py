"""EverDrive N8 (clone) hardware model for the n8-open simulator.

Models what docs/hw-interface.md documents, menu mode only for now:
  - 2 KB CPU RAM, minimal PPU (VRAM, palette, $2000/$2002/$2006/$2007, vblank)
  - FPGA OS map: regs $80-$88, windows $4800-$4FFF (PRG RAM) and $6000-$7FFF
    (save SRAM), CHR pages for the PPU
  - CPLD: reg $00 SPI data, reg $02 (bit 1 CS, bit 2 auto-read, bit 3 CONF_DONE),
    reg $06 nCONFIG, reg $05 / $4403 config data, reg $07 flash bank,
    reg $09 source of $8000 (01 = menu SRAM), $4402 mode, $4403 status
  - SD card in SPI mode on an image file

Things the real hardware may do differently are marked "ASSUMPTION".
"""

import sdcard

RBF_PREAMBLE = bytes([0x6A, 0xDE, 0xFF, 0x7F])
OPEN_BUS = 0x44   # what reads of write-only registers return on the clone


class PPU:
    def __init__(self):
        self.ctrl = 0
        self.mask = 0
        self.vblank = False
        self.addr = 0
        self.latch = False
        self.buffer = 0
        self.nt = bytearray(0x800)        # console CIRAM
        self.pal = bytearray(32)
        self.chr_read = None              # callbacks set by the board
        self.chr_write = None
        self.one_screen = True            # menu mode: CIRAM A10 = 0
        self.now = 0                      # CPU cycle (set by the run loop)
        self.vbl_end = 0                  # end of the current vblank (CPU cycle)
        self.warn = None                  # callback for programming errors

    def nt_index(self, a):
        a &= 0x0FFF
        if self.one_screen:
            return a & 0x3FF
        return a & 0x7FF

    def vram_read(self, a):
        a &= 0x3FFF
        if a < 0x2000:
            return self.chr_read(a)
        if a < 0x3F00:
            return self.nt[self.nt_index(a)]
        return self.pal[self.pal_index(a)]

    def vram_write(self, a, v):
        a &= 0x3FFF
        if a < 0x2000:
            self.chr_write(a, v)
        elif a < 0x3F00:
            self.nt[self.nt_index(a)] = v
        else:
            self.pal[self.pal_index(a)] = v

    @staticmethod
    def pal_index(a):
        i = a & 0x1F
        if i in (0x10, 0x14, 0x18, 0x1C):
            i -= 0x10
        return i

    def read(self, reg):
        if reg == 2:
            v = (0x80 if self.vblank else 0) | 0x00
            self.vblank = False
            self.latch = False
            return v
        if reg == 7:
            a = self.addr
            if (a & 0x3FFF) >= 0x3F00:
                v = self.vram_read(a)
            else:
                v = self.buffer
                self.buffer = self.vram_read(a)
            self.addr = (a + (32 if self.ctrl & 4 else 1)) & 0x3FFF
            return v
        return 0

    def write(self, reg, v):
        if reg == 0:
            self.ctrl = v
        elif reg == 1:
            self.mask = v
        elif reg == 5:
            self.latch = not self.latch
        elif reg == 6:
            if not self.latch:
                self.addr = ((v & 0x3F) << 8) | (self.addr & 0xFF)
            else:
                self.addr = (self.addr & 0xFF00) | v
            self.latch = not self.latch
        elif reg == 7:
            if (self.mask & 0x18) and self.now > self.vbl_end and self.warn:
                self.warn("PPUDATA write to $%04X while rendering is on, outside vblank" % self.addr)
            self.vram_write(self.addr, v)
            self.addr = (self.addr + (32 if self.ctrl & 4 else 1)) & 0x3FFF


class N8Board:
    CYCLES_PER_FRAME = 29780          # NTSC; good enough for pacing

    def __init__(self, os_bin, sd_image=None, log=None, sdhc=True, expect_rbf=None, reject_writes=False,
                 no_signature=False):
        self.ram = bytearray(0x800)
        self.prg = bytearray(512 * 1024)      # PRG SRAM
        self.chr = bytearray(512 * 1024)      # CHR SRAM
        self.sram = bytearray(256 * 1024)     # save SRAM (also holds the menu PRG)
        self.sram_mask = 0x3FFFF              # 0x1FFFF: A17 not reaching the chip
        self.ppu = PPU()
        self.ppu.chr_read = self.chr_read
        self.ppu.chr_write = self.chr_write
        self.log = log or (lambda s: None)
        self.bug_count = 0
        self.ppu.warn = self.bug

        # FPGA: "os" (menu map), "unconf" (after nCONFIG), "game"
        self.fpga = "os"
        self.our_core = False                  # boot core at power-on; ours after a valid load
        self.ram_at_start = None               # CPU RAM at the game start
        self.no_signature = no_signature       # loaded cores act like foreign ones (no $5000 window)
        self.reset_osmap()
        self.cfg_stream = bytearray()
        self.cfg_result = None
        self.expect_rbf = open(expect_rbf, "rb").read() if expect_rbf else None

        # CPLD
        self.ctl = 0x09                        # reg $02 after boot (read test: $09)
        self.mem_mode = 0x01                   # reg $09
        self.flash_bank = 0
        self.mode4402 = 0x03
        self.spi_last = 0xFF
        self.nconfig_pulses = 0
        self.sd = sdcard.SDCard(sd_image, sdhc=sdhc, reject_writes=reject_writes) if sd_image else None
        self.autoread_pipelined = True         # confirmed on hardware 2026-11-24 (offset 01)
        self.joy = 0                           # buttons for $4016 (A,B,Sel,Start,U,D,L,R)
        self.fds_port = []                     # FDS core: ($91..$94 index, value) in order
        self.joy_shift = 0

        # boot state as left by the BIOS (dump, $F080): the whole OS.BIN, 7 x
        # 8 KB, into save SRAM pages 9-15 ($12000-$1FFFF): CHR part in page 9,
        # padding in 10-11, PRG in 12-15 ($18000 = CPU $8000). Whatever the
        # menu kept in pages 9-11 is gone after every power-on. (The BIOS then
        # copies its own $FC00-$FFFF over the menu's last 1 KB - not modelled;
        # our menu ends below $C000 apart from the vectors.) CHR RAM is not
        # loaded: the menu uploads its font itself.
        data = open(os_bin, "rb").read()
        assert len(data) == 0xE000, "OS.BIN must be 57344 bytes"
        self.sram[0x12000:0x20000] = data

    def reset_osmap(self):
        self.index = 0
        self.prg_page = 0
        self.sram_page = 0
        self.chr_page = 1
        self.map_idx = 0xFF
        self.fpga_regs = {}
        self.ppu.one_screen = True

    def bug(self, msg):
        self.bug_count += 1
        if self.bug_count <= 20:
            self.log("BUG: " + msg)

    # ------------------------------------------------------------ PPU side
    def chr_addr(self, a):
        if self.fpga == "game":                 # NROM: CHR at offset 0
            return a & 0x1FFF
        page = self.chr_page if a & 0x1000 else (self.chr_page - 1) & 0x7F
        return (page << 12) | (a & 0xFFF)

    def chr_read(self, a):
        if self.fpga == "unconf":
            self.bug("PPU CHR read while the FPGA is unconfigured")
            return 0xFF
        return self.chr[self.chr_addr(a)]

    def chr_write(self, a, v):
        if self.fpga == "unconf":
            self.bug("PPU CHR write while the FPGA is unconfigured")
            return
        if self.fpga == "game" and not (self.fpga_regs.get(0x85, 0) & 0x80):
            return                              # CHR ROM
        self.chr[self.chr_addr(a)] = v

    # ------------------------------------------------------------ FPGA config
    def config_byte(self, v):
        if self.fpga != "unconf":
            self.bug("config byte $%02X while the FPGA is not in configuration" % v)
            return
        self.cfg_stream.append(v)

    abort_on_idle = False      # variant: $4402 = $03 ends the configuration

    def config_end(self):
        """$4402 back to $03: decide whether the stream was a valid core."""
        if self.fpga != "unconf" or not self.cfg_stream:
            return
        data = bytes(self.cfg_stream)
        if self.abort_on_idle and not (len(data) >= 32768 and data[0x10:0x14] == RBF_PREAMBLE
                                       and (self.expect_rbf is None or data == self.expect_rbf)):
            self.cfg_result = "aborted after %d bytes ($4402 = $03 mid-stream)" % len(data)
            self.log("config stream: " + self.cfg_result)
            self.cfg_stream = bytearray(b"X" * 0x40000)   # poisoned until the next nCONFIG
            return
        ok = len(data) >= 32768 and data[0x10:0x14] == b"\x6A\xDE\xFF\x7F"
        detail = "%d bytes, preamble %s" % (len(data), "ok" if ok else "MISSING")
        if self.expect_rbf is not None:
            same = data == self.expect_rbf
            detail += ", %s the expected RBF" % ("matches" if same else "DIFFERS from")
            ok = ok and same
        self.cfg_result = detail
        self.log("config stream: " + detail)
        if ok:
            self.fpga = "os"
            self.our_core = not self.no_signature
            self.reset_osmap()

    # ------------------------------------------------------------ CPLD / FPGA regs
    def spi(self, out):
        if self.sd is None or (self.ctl & 0x02):      # no card or CS high
            self.spi_last = 0xFF
        else:
            self.spi_last = self.sd.transfer(out)
        return self.spi_last

    def reg_write(self, idx, v):
        if idx >= 0x80:
            if self.fpga != "os":
                if self.fpga == "unconf":
                    self.bug("FPGA reg $%02X write while unconfigured" % idx)
                return
            self.fpga_regs[idx] = v
            if 0x91 <= idx <= 0x94:
                self.fds_port.append((idx, v))
            if idx == 0x80:
                self.prg_page = v
            elif idx == 0x81:
                self.sram_page = v & 0x3F
            elif idx == 0x82:
                self.chr_page = v & 0x7F
            elif idx == 0x83:
                self.map_idx = v
                if v != 0xFF:
                    self.fpga = "game"
                    self.ppu.one_screen = False
                    self.ram_at_start = bytes(self.ram)     # CPU RAM the game starts with
                    self.log("game start: mapper $%02X, regs %s" % (v, " ".join(
                        "$%02X=$%02X" % kv for kv in sorted(self.fpga_regs.items()))))
            return
        if idx == 0x00:
            self.spi(v)
        elif idx == 0x02:
            self.ctl = v                       # bit 3 is a plain setting (BIOS writes it)
        elif idx == 0x05:
            self.config_byte(v)
        elif idx == 0x06:
            if v == 0:
                self.nconfig_pulses += 1
                self.fpga = "unconf"
                self.cfg_stream = bytearray()
                self.cfg_result = None
        elif idx == 0x07:
            self.flash_bank = v
        elif idx == 0x09:
            self.mem_mode = v
        else:
            self.log("write to unknown CPLD reg $%02X = $%02X" % (idx, v))

    def reg_read(self, idx):
        if idx >= 0x80:
            return OPEN_BUS
        if idx == 0x00:
            if self.ctl & 0x04:                        # auto-read: clock a new byte
                if self.autoread_pipelined:            # hardware: returns the previous byte
                    prev = self.spi_last
                    self.spi(0xFF)
                    return prev
                return self.spi(0xFF)
            return self.spi_last
        if idx == 0x02:
            return self.ctl
        if idx == 0x07:
            return self.flash_bank
        if idx == 0x09:
            return self.mem_mode
        if idx == 0x01:
            return 0x00                                # USB FIFO: nothing there
        return 0x01                                    # read test: $03-$06, $08-$1F = $01

    # ------------------------------------------------------------ CPU bus
    def game_prg_mask(self):
        return ((self.fpga_regs.get(0x84, 0) & 0x1F) + 1) * 0x4000 - 1

    def read(self, a):
        if a < 0x2000:
            return self.ram[a & 0x7FF]
        if a < 0x4000:
            return self.ppu.read(a & 7)
        if a == 0x4016:
            v = (self.joy_shift & 1)
            self.joy_shift = (self.joy_shift >> 1) | 0x80
            return 0x40 | v
        if a < 0x4400:
            return 0x40
        if a < 0x4600:
            port = a & 3
            if port == 1:
                return self.reg_read(self.index)
            if port == 3:
                return 0x01                            # SPI done; no USB data
            return OPEN_BUS
        if self.fpga == "unconf" and a >= 0x4800:
            self.bug("CPU read $%04X while the FPGA is unconfigured (PC must be in CPU RAM)" % a)
            return OPEN_BUS
        if self.fpga == "game":
            if a >= 0x8000:
                return self.prg[(a & 0x7FFF) & self.game_prg_mask()]
            if 0x6000 <= a < 0x8000:
                return self.sram[a & 0x1FFF]
            return OPEN_BUS
        if 0x4800 <= a < 0x5000:
            return self.prg[(self.prg_page << 11) | (a & 0x7FF)]
        if 0x5000 <= a < 0x5800 and self.our_core:      # signature window (our cores only)
            return self.prg[0x7F800 | (a & 0x7FF)]
        if 0x6000 <= a < 0x8000:
            return self.sram[((self.sram_page << 13) | (a & 0x1FFF)) & self.sram_mask]
        if a >= 0x8000:
            if self.mem_mode & 3 == 1:
                return self.sram[0x18000 + (a & 0x7FFF)]
            self.log("read at $%04X while $8000 is not menu RAM (mode %d)" % (a, self.mem_mode & 3))
            return 0xFF
        return OPEN_BUS

    def write(self, a, v):
        if a < 0x2000:
            self.ram[a & 0x7FF] = v
            return
        if a < 0x4000:
            self.ppu.write(a & 7, v)
            return
        if a == 0x4016:
            if v & 1:
                self.joy_shift = self.joy
            return
        if a < 0x4400:
            return
        if a < 0x4600:
            port = a & 3
            if port == 0:
                self.index = v
            elif port == 1:
                self.reg_write(self.index, v)
            elif port == 2:
                if self.mode4402 == 0x05 and v != 0x05:
                    self.config_end()
                self.mode4402 = v
            elif port == 3:
                if self.mode4402 == 0x05:
                    self.config_byte(v)
                else:
                    self.bug("write to $4403 while $4402 != $05")
            return
        if self.fpga == "unconf" and a >= 0x4800:
            self.bug("CPU write $%04X while the FPGA is unconfigured" % a)
            return
        if self.fpga == "game":
            if 0x6000 <= a < 0x8000:
                self.sram[a & 0x1FFF] = v
            return
        if 0x4800 <= a < 0x5000:
            self.prg[(self.prg_page << 11) | (a & 0x7FF)] = v
        elif 0x5000 <= a < 0x5800:
            if self.our_core:
                self.prg[0x7F800 | (a & 0x7FF)] = v
        elif 0x6000 <= a < 0x8000:
            self.sram[((self.sram_page << 13) | (a & 0x1FFF)) & self.sram_mask] = v
        elif a >= 0x8000:
            if self.mem_mode & 3 == 1:
                self.sram[0x18000 + (a & 0x7FFF)] = v
            else:
                self.log("write at $%04X while $8000 is not menu RAM" % a)

    # ------------------------------------------------------------ screen
    def screen_text(self, charmap=None, rows=30):
        """Nametable 0 as text. charmap: tile -> str; default printable ASCII."""
        out = []
        for r in range(rows):
            line = ""
            for c in range(32):
                t = self.ppu.nt[r * 32 + c]
                if charmap:
                    line += charmap(t)
                else:
                    line += chr(t) if 32 <= t < 127 else ("." if t else " ")
            out.append(line.rstrip())
        while out and not out[-1]:
            out.pop()
        return "\n".join(out)
