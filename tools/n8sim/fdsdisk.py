"""FDS preparation as the menu does it (reference for menu/src): .fds parsing,
block tables for map_fds.v, and the BIOS patch.

.fds: optional 16-byte header ("FDS" $1A, side count), then 65500 bytes per
side: blocks back to back without gaps or CRCs, zero-filled.
Blocks: 1 disk info (56 bytes), 2 file amount (2), then per file 3 header
(16) and 4 data (1 + size from the header). Files past the count in block 2
are ignored by the BIOS, but they are on the disk: the table lists every
block found until the zero fill.
"""

SIDE = 65500

# FDS BIOS (CRC32 5E607DCF), patched to use the core's stub (map_fds.v):
#   $E1CE LDX $4031 -> JSR $5700 (LDX <current disk byte>)
#   $E1D1 STA $4024 -> JSR $5704 (STA <next byte to write>)
#   $E729 JSR $E7A3 -> JSR $5708 (end of a block write: the flush byte)
#   $E445 JSR $E6E3 -> JSR $5720 (disk check: the wanted ID to the core)
BIOS_PATCHES = (
    (0x01CE, bytes.fromhex("AE3140 8D2440"), bytes.fromhex("200057 200457")),
    (0x0729, bytes.fromhex("20A3E7"), bytes.fromhex("200857")),
    (0x0445, bytes.fromhex("20E3E6"), bytes.fromhex("202057")),
)
ID_OFF, ID_LEN = 0x0F, 10          # block 1 bytes the BIOS's check compares


def sides(data):
    """List of 65500-byte sides."""
    if data[:4] == b"FDS\x1a":
        data = data[16:]
    n = len(data) // SIDE
    if n == 0 or data[0] != 0x01:
        raise ValueError("not an FDS image")
    return [bytes(data[i * SIDE:(i + 1) * SIDE]) for i in range(n)]


def side_id(side):
    """The 10 bytes of block 1 the BIOS compares with a game's wanted ID
    (manufacturer, name, type, version, side, disk number, ...)."""
    return bytes(side[ID_OFF:ID_OFF + ID_LEN])


def block_table(side):
    """Block start offsets, then the end of the last block, then $FFFF."""
    starts = []
    p = 0
    size = None
    while p < SIDE:
        t = side[p]
        if t == 1:
            n = 56
        elif t == 2:
            n = 2
        elif t == 3:
            n = 16
            size = side[p + 13] | (side[p + 14] << 8)
        elif t == 4 and size is not None:
            n = 1 + size
            size = None
        else:
            break                      # zero fill (or damage): end of the side
        if p + n > SIDE:
            break
        starts.append(p)
        p += n
    return starts + [p, 0xFFFF]


def patch_bios(bios):
    if len(bios) != 0x2000:
        raise ValueError("BIOS must be 8192 bytes")
    b = bytearray(bios)
    for off, orig, new in BIOS_PATCHES:
        if bios[off:off + len(orig)] != orig:
            raise ValueError("unknown BIOS: bytes at $%04X differ" % (0xE000 + off))
        b[off:off + len(new)] = new
    return bytes(b)
