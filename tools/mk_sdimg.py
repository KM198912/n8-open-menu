#!/usr/bin/env python3
"""Build a FAT32 SD card image from a folder, for the n8-open simulator.

  python mk_sdimg.py <folder> <out.img> [--mb 64] [--spc 8] [--no-mbr]

- MBR with one partition (type 0x0C) at LBA 2048, unless --no-mbr
  ("superfloppy": the volume starts at LBA 0, as some cards are formatted).
- FAT32, 512-byte sectors, --spc sectors per cluster (1..64), 2 FATs.
- Long file names are written as LFN entries plus an 8.3 alias, so the menu
  can be tested with both.
- Files are stored in folder order; directories may span several clusters.
"""
import argparse
import os
import random
import struct

SECTOR = 512
SHUFFLE = None                          # --shuffle SEED: directory entry order


class Fat32:
    def __init__(self, total_sectors, spc, part_lba):
        self.spc = spc
        self.part_lba = part_lba
        self.reserved = 32
        vol = total_sectors - part_lba
        # FAT size: iterate until stable
        fat_sz = 1
        while True:
            clusters = (vol - self.reserved - 2 * fat_sz) // spc
            need = (clusters + 2) * 4
            new = (need + SECTOR - 1) // SECTOR
            if new == fat_sz:
                break
            fat_sz = new
        self.fat_sz = fat_sz
        self.clusters = clusters
        self.vol = vol
        self.fat = [0] * (clusters + 2)
        self.fat[0] = 0x0FFFFFF8
        self.fat[1] = 0x0FFFFFFF
        self.next_free = 2
        self.data = {}                  # cluster -> bytes
        self.chains = {}                # first cluster -> cluster list
        self.cluster_bytes = spc * SECTOR

    fragment = False                    # file chains use every other cluster

    def alloc_chain(self, nbytes, contiguous=False):
        n = max(1, (nbytes + self.cluster_bytes - 1) // self.cluster_bytes)
        step = 2 if (self.fragment and not contiguous) else 1
        chain = [self.next_free + i * step for i in range(n)]
        for i, c in enumerate(chain):
            self.fat[c] = chain[i + 1] if i < n - 1 else 0x0FFFFFFF
        self.next_free = chain[-1] + 1
        assert self.next_free < len(self.fat), "image too small"
        self.chains[chain[0]] = chain
        return chain[0], n

    def store(self, first, payload):
        cb = self.cluster_bytes
        chain = self.chains[first]
        for k, i in enumerate(range(0, max(len(payload), 1), cb)):
            self.data[chain[k]] = payload[i:i + cb]


def short_name(name, used):
    base, ext = os.path.splitext(name)
    ext = ext[1:]
    clean = lambda s: "".join(ch for ch in s.upper() if ch.isalnum() or ch in "_-~!#$%&'()@^{}")  # noqa: E731
    b, e = clean(base), clean(ext)[:3]
    if b[:8] == base.upper() and e == ext.upper() and len(base) <= 8 and (b, e) not in used:
        used.add((b, e))
        return b.ljust(8).encode() + e.ljust(3).encode(), False
    for n in range(1, 1000):
        tail = "~%d" % n
        cand = (b[:8 - len(tail)] + tail, e)
        if cand not in used:
            used.add(cand)
            return cand[0].ljust(8).encode() + e.ljust(3).encode(), True
    raise ValueError("too many similar names")


def lfn_entries(name, sname):
    csum = 0
    for ch in sname:
        csum = (((csum & 1) << 7) + (csum >> 1) + ch) & 0xFF
    u = name.encode("utf-16-le")
    chars = [u[i:i + 2] for i in range(0, len(u), 2)]
    chars.append(b"\x00\x00")
    while len(chars) % 13:
        chars.append(b"\xFF\xFF")
    parts = [chars[i:i + 13] for i in range(0, len(chars), 13)]
    out = []
    for i, p in enumerate(parts):
        seq = i + 1
        if i == len(parts) - 1:
            seq |= 0x40
        e = bytes([seq]) + b"".join(p[0:5]) + bytes([0x0F, 0, csum]) + \
            b"".join(p[5:11]) + b"\x00\x00" + b"".join(p[11:13])
        out.append(e)
    return list(reversed(out))


def dir_entry(sname, attr, cluster, size):
    return sname + struct.pack("<BBBHHHHHHHI", attr, 0, 0, 0, 0x0021, 0x0021,
                               cluster >> 16, 0, 0x0021, cluster & 0xFFFF, size)


def build_dir(fs, path, parent_cluster, my_cluster=None):
    """Returns the cluster of this directory. Root: parent_cluster=None."""
    entries = []
    used = set()
    names = sorted(os.listdir(path), key=str.lower)
    if SHUFFLE is not None:             # as if copied in random order
        random.Random("%d:%s" % (SHUFFLE, os.path.basename(path))).shuffle(names)
    children = []
    for n in names:
        full = os.path.join(path, n)
        sname, needs_lfn = short_name(n, used)
        if n.upper() != n or needs_lfn:
            entries.extend(lfn_entries(n, sname))
        if os.path.isdir(full):
            children.append((full, sname, len(entries)))
            entries.append(None)        # filled once the child cluster is known
        else:
            data = open(full, "rb").read()
            if data:
                first, _ = fs.alloc_chain(len(data))
                fs.store(first, data)
            else:
                first = 0
            entries.append(dir_entry(sname, 0x20, first, len(data)))

    extra = 0 if parent_cluster is None else 2
    nbytes = (len(entries) + extra + 1) * 32
    if my_cluster is None:
        my_cluster, _ = fs.alloc_chain(nbytes, contiguous=True)
    else:                               # root: already allocated, maybe extend
        pass
    for full, sname, idx in children:
        c = build_dir(fs, full, my_cluster)
        entries[idx] = dir_entry(sname, 0x10, c, 0)
    blob = b""
    if parent_cluster is not None:
        blob += dir_entry(b".          ", 0x10, my_cluster, 0)
        blob += dir_entry(b"..         ", 0x10, 0 if parent_cluster == 2 else parent_cluster, 0)
    blob += b"".join(entries)
    fs.store(my_cluster, blob)
    return my_cluster


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder")
    ap.add_argument("out")
    ap.add_argument("--mb", type=int, default=64)
    ap.add_argument("--spc", type=int, default=8)
    ap.add_argument("--no-mbr", action="store_true")
    ap.add_argument("--fragment", action="store_true", help="store files in every other cluster")
    ap.add_argument("--fsinfo", action="store_true", help="real free count + next-free hint in FSInfo (as Windows writes them)")
    ap.add_argument("--shuffle", type=int, help="write directory entries in a random order (seed)")
    a = ap.parse_args()
    global SHUFFLE
    SHUFFLE = a.shuffle

    total = a.mb * 1024 * 1024 // SECTOR
    part_lba = 0 if a.no_mbr else 2048
    fs = Fat32(total, a.spc, part_lba)
    fs.fragment = a.fragment

    # root directory: reserve enough clusters up front
    n_root = len(os.listdir(a.folder))
    root, _ = fs.alloc_chain((n_root * 8 + 2) * 32, contiguous=True)
    build_dir(fs, a.folder, None, root)

    img = bytearray(total * SECTOR) if total * SECTOR <= 256 * 1024 * 1024 else None
    assert img is not None, "use --mb <= 256"

    if not a.no_mbr:
        mbr = bytearray(SECTOR)
        struct.pack_into("<B3sB3sII", mbr, 446, 0x00, b"\xFE\xFF\xFF", 0x0C, b"\xFE\xFF\xFF",
                         part_lba, fs.vol)
        mbr[510:512] = b"\x55\xAA"
        img[0:SECTOR] = mbr

    vbr = bytearray(SECTOR)
    vbr[0:3] = b"\xEB\x58\x90"
    vbr[3:11] = b"N8OPEN  "
    struct.pack_into("<HBHBHHBHHHII", vbr, 11, SECTOR, a.spc, fs.reserved, 2, 0, 0, 0xF8, 0,
                     63, 255, part_lba, fs.vol)
    struct.pack_into("<IHHIHH", vbr, 36, fs.fat_sz, 0, 0, root, 1, 6)
    struct.pack_into("<BBBI11s8s", vbr, 64, 0x80, 0, 0x29, 0x12345678, b"N8TEST     ", b"FAT32   ")
    vbr[510:512] = b"\x55\xAA"
    base = part_lba * SECTOR
    img[base:base + SECTOR] = vbr
    img[base + 6 * SECTOR:base + 7 * SECTOR] = vbr          # backup boot sector
    fsinfo = bytearray(SECTOR)
    struct.pack_into("<I", fsinfo, 0, 0x41615252)
    free_count, hint = 0xFFFFFFFF, 0xFFFFFFFF
    if a.fsinfo:
        free_count = sum(1 for c in range(2, fs.clusters + 2) if fs.fat[c] == 0)
        hint = fs.next_free
    struct.pack_into("<III", fsinfo, 484, 0x61417272, free_count, hint)
    fsinfo[510:512] = b"\x55\xAA"
    img[base + SECTOR:base + 2 * SECTOR] = fsinfo

    fat_bytes = b"".join(struct.pack("<I", v) for v in fs.fat)
    for k in range(2):
        off = base + (fs.reserved + k * fs.fat_sz) * SECTOR
        img[off:off + len(fat_bytes)] = fat_bytes

    data_off = base + (fs.reserved + 2 * fs.fat_sz) * SECTOR
    for c, payload in fs.data.items():
        off = data_off + (c - 2) * fs.cluster_bytes
        img[off:off + len(payload)] = payload

    with open(a.out, "wb") as f:
        f.write(img)
    print("wrote %s: %d MB, %s, spc %d, %d clusters, FAT %d sectors, root cluster %d, %d clusters used"
          % (a.out, a.mb, "superfloppy" if a.no_mbr else "MBR @2048", a.spc, fs.clusters,
             fs.fat_sz, root, fs.next_free - 2))


if __name__ == "__main__":
    main()
