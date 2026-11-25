#!/usr/bin/env python3
"""Consistency check of a FAT32 image (MBR or superfloppy), independent of
the menu's FAT code. Used to verify the menu's FAT writing (fatw.s).

  python fatcheck.py card.img [--tree] [--dump PATH]

Checks:
- all FAT copies identical, entries 0/1 sane
- every directory entry: LFN sequence numbers, checksum against the 8.3
  name, terminator/padding, no LFN without its 8.3 entry
- "." and ".." in subdirectories point at the right clusters
- every chain: starts at a valid cluster, ends with end-of-chain, no loop,
  no cluster used by two chains (cross-link), file size fits the chain
- lost clusters: allocated in the FAT but not reachable from any entry
- FSInfo: signatures; free count (if known) equals the real free count;
  next-free hint in range
Exit code 0 = no errors.
"""
import argparse
import struct
import sys

SECTOR = 512
EOC = 0x0FFFFFF8


class Vol:
    def __init__(self, path):
        self.f = open(path, "rb")
        s0 = self.sector(0)
        self.part = 0
        if s0[0x52:0x57] != b"FAT32":
            self.part = struct.unpack_from("<I", s0, 0x1C6)[0]
        v = self.sector(self.part)
        assert v[0x52:0x57] == b"FAT32", "no FAT32 volume"
        (self.bps, self.spc, self.res, self.nfats) = struct.unpack_from("<HBHB", v, 11)
        self.totsec = struct.unpack_from("<I", v, 32)[0]
        self.fatsz = struct.unpack_from("<I", v, 36)[0]
        self.root = struct.unpack_from("<I", v, 44)[0]
        self.fsinfo = struct.unpack_from("<H", v, 48)[0]
        self.fat_lba = self.part + self.res
        self.data_lba = self.fat_lba + self.nfats * self.fatsz
        self.nclus = (self.part + self.totsec - self.data_lba) // self.spc
        self.max = self.nclus + 2
        self.fats = [self.read(self.fat_lba + k * self.fatsz, self.fatsz) for k in range(self.nfats)]
        self.fat = [v & 0x0FFFFFFF for v in struct.unpack_from("<%dI" % self.max, self.fats[0])]
        self.errors = []

    def sector(self, lba):
        self.f.seek(lba * SECTOR)
        return self.f.read(SECTOR)

    def read(self, lba, n):
        self.f.seek(lba * SECTOR)
        return self.f.read(n * SECTOR)

    def cluster(self, c):
        return self.read(self.data_lba + (c - 2) * self.spc, self.spc)

    def err(self, msg):
        self.errors.append(msg)

    def chain(self, first, what):
        out, c, seen = [], first, set()
        while True:
            if not (2 <= c < self.max):
                self.err("%s: bad cluster %d in chain" % (what, c))
                return out
            if c in seen:
                self.err("%s: loop at cluster %d" % (what, c))
                return out
            seen.add(c)
            out.append(c)
            n = self.fat[c]
            if n >= EOC:
                return out
            if n == 0:
                self.err("%s: chain runs into free cluster after %d" % (what, c))
                return out
            c = n


def lfn_checksum(name11):
    s = 0
    for b in name11:
        s = (((s & 1) << 7) + (s >> 1) + b) & 0xFF
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("img")
    ap.add_argument("--tree", action="store_true")
    ap.add_argument("--dump", help="print the first bytes of this file (path with /)")
    a = ap.parse_args()
    v = Vol(a.img)

    for k in range(1, v.nfats):
        if v.fats[k] != v.fats[0]:
            diff = [i // 4 for i in range(0, len(v.fats[0]), 4) if v.fats[k][i:i + 4] != v.fats[0][i:i + 4]]
            v.err("FAT copy %d differs from FAT 0 at entries %s" % (k + 1, diff[:8]))

    owner = {}                      # cluster -> path
    files = {}                      # path -> (first, size)

    def claim(chain, path):
        for c in chain:
            if c in owner:
                v.err("cross-link: cluster %d in %s and %s" % (c, owner[c], path))
            owner[c] = path

    def walk(first, path, parent):
        chain = v.chain(first, path or "/")
        claim(chain, path or "/")
        data = b"".join(v.cluster(c) for c in chain)
        lfn, lfn_sum, lfn_next = [], None, None
        names = set()
        for i in range(0, len(data), 32):
            e = data[i:i + 32]
            if e[0] == 0:
                if lfn:
                    v.err("%s: LFN entries without 8.3 entry at the end" % (path or "/"))
                break
            if e[0] == 0xE5:
                lfn = []
                continue
            if e[11] == 0x0F:
                seq = e[0]
                if seq & 0x40:
                    if lfn:
                        v.err("%s: new LFN set while one is open" % (path or "/"))
                    lfn, lfn_sum, lfn_next = [], e[13], seq & 0x1F
                if (seq & 0x1F) != lfn_next or e[13] != lfn_sum:
                    v.err("%s: LFN sequence/checksum broken (seq %02X)" % (path or "/", seq))
                chars = e[1:11] + e[14:26] + e[28:32]
                lfn.insert(0, [struct.unpack_from("<H", chars, j)[0] for j in range(0, 26, 2)])
                lfn_next = (seq & 0x1F) - 1
                continue
            name11 = e[0:11]
            attr = e[11]
            clus = struct.unpack_from("<H", e, 20)[0] << 16 | struct.unpack_from("<H", e, 26)[0]
            size = struct.unpack_from("<I", e, 28)[0]
            short = name11[0:8].decode("ascii", "replace").rstrip()
            ext = name11[8:11].decode("ascii", "replace").rstrip()
            sname = short + ("." + ext if ext else "")
            name = sname
            if lfn:
                if lfn_next != 0:
                    v.err("%s: LFN set incomplete before %s" % (path or "/", sname))
                if lfn_sum != lfn_checksum(name11):
                    v.err("%s: LFN checksum %02X does not match %s (%02X)" %
                          (path or "/", lfn_sum, sname, lfn_checksum(name11)))
                units = [u for part in lfn for u in part]
                if 0 in units:
                    end = units.index(0)
                    if any(u != 0xFFFF for u in units[end + 1:]):
                        v.err("%s: LFN padding after the terminator is not FFFF (%s)" % (path or "/", sname))
                    units = units[:end]
                elif 0xFFFF in units:
                    v.err("%s: LFN padding without terminator (%s)" % (path or "/", sname))
                name = "".join(chr(u) for u in units)
                lfn = []
            if attr & 0x08:
                continue                # volume label
            if sname in (".", ".."):
                want = first if sname == "." else (0 if parent == v.root else parent)
                if path and clus != want:
                    v.err("%s: '%s' points at %d, expected %d" % (path, sname, clus, want))
                continue
            for n in {name.lower(), sname.lower()}:
                if n in names:
                    v.err("%s: duplicate name %s" % (path or "/", n))
                names.add(n)
            full = (path + "/" + name)
            if a.tree:
                print("%-50s %-12s %s clus %-6d size %d" % (full, sname, "DIR " if attr & 0x10 else "FILE", clus, size))
            if attr & 0x10:
                walk(clus, full, first)
            elif clus == 0:
                if size:
                    v.err("%s: size %d without clusters" % (full, size))
            else:
                ch = v.chain(clus, full)
                claim(ch, full)
                files[full] = (clus, size)
                cb = v.spc * SECTOR
                need = max(1, (size + cb - 1) // cb)
                if len(ch) != need:
                    v.err("%s: size %d needs %d clusters, chain has %d" % (full, size, need, len(ch)))

    walk(v.root, "", v.root)

    used = [c for c in range(2, v.max) if v.fat[c] != 0]
    lost = [c for c in used if c not in owner]
    if lost:
        v.err("%d lost clusters (allocated, not reachable): %s" % (len(lost), lost[:10]))
    free = v.nclus - len(used)

    fi = v.sector(v.part + v.fsinfo)
    if struct.unpack_from("<I", fi, 0)[0] != 0x41615252 or struct.unpack_from("<I", fi, 484)[0] != 0x61417272:
        v.err("FSInfo signatures broken")
    else:
        fcount, hint = struct.unpack_from("<II", fi, 488)
        if fcount != 0xFFFFFFFF and fcount != free:
            v.err("FSInfo free count %d, real %d" % (fcount, free))
        if hint != 0xFFFFFFFF and not (2 <= hint < v.max):
            v.err("FSInfo next-free hint %d out of range" % hint)
        print("FSInfo: free count %s, next free %s" %
              ("unknown" if fcount == 0xFFFFFFFF else fcount, "unknown" if hint == 0xFFFFFFFF else hint))

    if a.dump:
        if a.dump in files:
            c, size = files[a.dump]
            print("%s: cluster %d, %d bytes, first bytes %s" % (a.dump, c, size, v.cluster(c)[:16].hex(" ")))
        else:
            v.err("--dump: %s not found" % a.dump)

    print("clusters %d, used %d, free %d, files %d" % (v.nclus, len(used), free, len(files)))
    for e in v.errors:
        print("ERROR:", e)
    print("OK" if not v.errors else "%d errors" % len(v.errors))
    sys.exit(1 if v.errors else 0)


if __name__ == "__main__":
    main()
