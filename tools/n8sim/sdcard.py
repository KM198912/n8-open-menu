"""SD card in SPI mode, backed by an image file (SDHC: block addressing).

Supported: CMD0, CMD8, CMD9/10 (dummy), CMD12, CMD13, CMD16, CMD17, CMD18,
CMD24, CMD25, CMD55, ACMD41, CMD58. Writes go to the image file.

transfer(byte_out) -> byte_in, one SPI byte at a time.
"""


def crc16(data):
    """CRC16-CCITT (poly 0x1021, init 0) as SD cards append to data blocks."""
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc


class SDCard:
    def __init__(self, path, acmd41_busy=2, sdhc=True, write_busy=4, reject_writes=False):
        self.f = open(path, "r+b")
        self.f.seek(0, 2)
        self.blocks = self.f.tell() // 512
        self.out = bytearray()          # bytes the card will send next
        self.cmd = bytearray()
        self.app = False
        self.idle = True
        self.acmd41_left = acmd41_busy  # ACMD41 answers "busy" this many times
        self.reading = None             # next block for CMD18, or None
        self.writing = None             # ("single"|"multi", lba) while receiving data
        self.wbuf = None
        self.log = []
        self.sdhc = sdhc
        self.write_busy = write_busy    # busy ($00) bytes after an accepted block
        self.reject_writes = reject_writes  # answer every block with "write error"
        self.errors = []                # host protocol errors

    # ------------------------------------------------------------ helpers
    def block(self, lba):
        if lba >= self.blocks:
            return None
        self.f.seek(lba * 512)
        return self.f.read(512)

    def queue_block(self, lba):
        data = self.block(lba)
        if data is None:
            self.out += bytes([0x09])   # data error token: out of range
            return False
        # real CRC16, high byte first: a CRC low byte of $FE must not be
        # mistaken for the next data token (bug found 2026-11-25)
        self.out += b"\xFF" + b"\xFE" + data + crc16(data).to_bytes(2, "big")
        return True

    def r1(self):
        return 0x01 if self.idle else 0x00

    # ------------------------------------------------------------ SPI byte
    def transfer(self, b):
        # data phase of a write
        if self.writing is not None:
            return self._write_byte(b)

        # command collection: a command starts with 01xxxxxx
        if self.cmd or (b & 0xC0) == 0x40:
            self.cmd.append(b)
            if len(self.cmd) == 6:
                cmd = bytes(self.cmd)
                self.cmd.clear()
                self._command(cmd)
            return 0xFF

        if self.out:
            return self.out.pop(0)
        if self.reading is not None:    # CMD18 keeps streaming
            if self.queue_block(self.reading):
                self.reading += 1
            else:
                self.reading = None
            return self.out.pop(0) if self.out else 0xFF
        return 0xFF

    def _command(self, c):
        idx = c[0] & 0x3F
        arg = int.from_bytes(c[1:5], "big")
        app, self.app = self.app, False
        self.log.append(("ACMD" if app else "CMD") + "%d %08X" % (idx, arg))
        if idx == 12:                   # stop transmission
            self.reading = None
            self.out = bytearray(b"\xFF\x00\xFF")
            return
        self.out = bytearray(b"\xFF")   # Ncr: one byte before the response
        if idx == 0:
            self.idle = True
            self.reading = None
            self.out.append(0x01)
        elif idx == 8:
            self.out += bytes([self.r1(), 0x00, 0x00, (arg >> 8) & 0x0F, arg & 0xFF])
        elif idx == 55:
            self.app = True
            self.out.append(self.r1())
        elif idx == 41 and app:
            if self.acmd41_left > 0:
                self.acmd41_left -= 1
                self.out.append(0x01)
            else:
                self.idle = False
                self.out.append(0x00)
        elif idx == 58:
            ocr = (0xC0FF8000 if self.sdhc else 0x80FF8000) if not self.idle else 0x00FF8000
            self.out += bytes([self.r1()]) + ocr.to_bytes(4, "big")
        elif idx in (9, 10):
            self.out += bytes([self.r1()]) + b"\xFF\xFE" + bytes(16) + b"\x00\x00"
        elif idx == 13:
            self.out += bytes([self.r1(), 0x00])
        elif idx == 16:
            self.out.append(self.r1())
        elif idx == 17:
            self.out.append(0x00)
            self.queue_block(arg if self.sdhc else arg // 512)
        elif idx == 18:
            self.out.append(0x00)
            blk = arg if self.sdhc else arg // 512
            if self.queue_block(blk):
                self.reading = blk + 1
        elif idx in (24, 25):
            self.out.append(0x00)
            self.writing = ("single" if idx == 24 else "multi", arg if self.sdhc else arg // 512)
            self.wbuf = None
        else:
            self.out.append(0x05 if not app else 0x05)   # illegal command
            self.log.append("  -> illegal")

    def error(self, msg):
        self.errors.append(msg)
        self.log.append("  !! " + msg)

    def _write_byte(self, b):
        kind, lba = self.writing
        if self.out:                    # still sending R1/data response/busy
            return self.out.pop(0)
        if self.wbuf is None:
            if b == 0xFE or (kind == "multi" and b == 0xFC):
                self.wbuf = bytearray()
            elif kind == "multi" and b == 0xFD:   # stop token
                self.writing = None
                self.out += b"\xFF\x00\xFF"
            elif b != 0xFF:
                self.error("byte $%02X before the data token (LBA %d)" % (b, lba))
            return 0xFF
        self.wbuf.append(b)
        if len(self.wbuf) == 514:       # 512 data + 2 CRC
            if self.reject_writes:
                self.log.append("  rejected LBA %d" % lba)
                self.wbuf = None
                self.writing = None
                self.out += b"\x0D\xFF"         # data rejected: write error
                return 0xFF
            if lba >= self.blocks:
                self.error("write beyond the card: LBA %d" % lba)
            if lba < self.blocks:
                self.f.seek(lba * 512)
                self.f.write(bytes(self.wbuf[:512]))
                self.f.flush()
            self.log.append("  wrote LBA %d" % lba)
            self.wbuf = None
            self.out += b"\x05" + b"\x00" * self.write_busy + b"\xFF"   # accepted, busy, ready
            if kind == "single":
                self.writing = None
            else:
                self.writing = (kind, lba + 1)
        return 0xFF
