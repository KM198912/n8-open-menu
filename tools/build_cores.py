#!/usr/bin/env python3
"""Build every FPGA core with Quartus (command line), pad the RBFs into the
card staging folder and regenerate MAPROUT.BIN - no clicking through the
revision dropdown.

  python tools/build_cores.py                 all cores in cores/cores.txt
                                              + the menu core (255.RBF)
  python tools/build_cores.py --only n8_mmc2,n8_mmc4
  python tools/build_cores.py --list          only show what would be built
  python tools/build_cores.py --quartus <dir with quartus_sh.exe>

quartus_sh: --quartus, else %QUARTUS_ROOTDIR%\\bin64 / bin, else the default
below. The builds run one after another (Quartus locks the project folder
while a revision compiles). Per build:
  - log:  test/build_logs/<revision>.log
  - the RBF must have been rewritten during this run and quartus_sh must
    exit with 0; only then it is padded (as tools/pad_rbf.py) into
    test/m2card/EDFC/MAPS/NNN.RBF
A failed core does not stop the others; failures are listed at the end.
Finally MAPROUT.BIN is generated from cores.txt into the staging folder.
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys
import time

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CORES_TXT = os.path.join(ROOT, "cores", "cores.txt")
STAGE = os.path.join(ROOT, "test", "m2card", "EDFC")
LOGS = os.path.join(ROOT, "test", "build_logs")
DEFAULT_QUARTUS = r"H:\altera\13.0sp1\quartus\bin64"
NROM_PROJ = ("cores/nrom", "n8_nrom")
MENU = ("cores/nrom_noret", "n8_noret", "n8_noret", 255)   # dir, project, revision, RBF
PREAMBLE = b"\x6A\xDE\xFF\x7F"
MIN_PAD = 256


def read_cores():
    """[(mapper, rbf, revision)] from cores.txt ("revision n8_xxx" in the
    comment; NROM's line has none: n8_nrom)"""
    out = []
    for n, raw in enumerate(open(CORES_TXT), 1):
        line, _, comment = raw.partition("#")
        line = line.strip()
        if not line:
            continue
        mapper, rbf = (int(x) for x in line.split())
        m = re.search(r"revision\s+(n8_\w+)", comment)
        if m:
            rev = m.group(1)
        elif mapper == 0:
            rev = "n8_nrom"
        else:
            sys.exit("cores.txt:%d: no 'revision n8_...' in the comment (mapper %d)" % (n, mapper))
        out.append((mapper, rbf, rev))
    return out


def find_quartus(arg):
    cands = []
    if arg:
        cands.append(arg)
    qr = os.environ.get("QUARTUS_ROOTDIR")
    if qr:
        cands += [os.path.join(qr, "bin64"), os.path.join(qr, "bin")]
    cands.append(DEFAULT_QUARTUS)
    for d in cands:
        exe = os.path.join(d, "quartus_sh.exe")
        if os.path.isfile(exe):
            return exe
        exe = os.path.join(d, "quartus_sh")
        if os.path.isfile(exe):
            return exe
    sys.exit("quartus_sh not found (tried: %s) - use --quartus <dir>" % ", ".join(cands))


def pad_rbf(data):
    pad = (-len(data)) % 512
    if pad < MIN_PAD:
        pad += 512
    return data + b"\xFF" * pad


def write_atomic(path, data):
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--only", help="comma-separated revisions (e.g. n8_mmc2,n8_noret)")
    ap.add_argument("--list", action="store_true", help="show the build list and stop")
    ap.add_argument("--quartus", help="folder containing quartus_sh(.exe)")
    args = ap.parse_args()

    cores = read_cores()
    jobs = []                                    # (dir, project, revision, rbf)
    seen = set()
    for mapper, rbf, rev in cores:
        if rev not in seen:
            seen.add(rev)
            jobs.append((NROM_PROJ[0], NROM_PROJ[1], rev, rbf))
    jobs.append(MENU)
    if args.only:
        want = set(x.strip() for x in args.only.split(",") if x.strip())
        unknown = want - set(j[2] for j in jobs)
        if unknown:
            sys.exit("unknown revision(s): %s" % ", ".join(sorted(unknown)))
        jobs = [j for j in jobs if j[2] in want]

    print("cores to build:")
    for d, proj, rev, rbf in jobs:
        print("  %-10s %s/%s.qpf -> %03d.RBF" % (rev, d, proj, rbf))
    if args.list:
        return

    qsh = find_quartus(args.quartus)
    print("quartus_sh: %s" % qsh)
    os.makedirs(LOGS, exist_ok=True)
    os.makedirs(os.path.join(STAGE, "MAPS"), exist_ok=True)

    results = []                                 # (rev, rbf, seconds, ok, info)
    t_all = time.time()
    for i, (d, proj, rev, rbf) in enumerate(jobs, 1):
        cwd = os.path.join(ROOT, *d.split("/"))
        out_rbf = os.path.join(cwd, "output_files", rev + ".rbf")
        log = os.path.join(LOGS, rev + ".log")
        print("[%d/%d] %s ..." % (i, len(jobs), rev), end=" ", flush=True)
        t0 = time.time()
        with open(log, "w") as lf:
            rc = subprocess.call([qsh, "--flow", "compile", proj, "-c", rev],
                                 cwd=cwd, stdout=lf, stderr=subprocess.STDOUT)
        secs = time.time() - t0
        if rc != 0:
            results.append((rev, rbf, secs, False, "quartus_sh exit %d, see %s" % (rc, os.path.relpath(log, ROOT))))
            print("FAILED (%d s)" % secs)
            continue
        if not os.path.exists(out_rbf) or os.path.getmtime(out_rbf) < t0:
            results.append((rev, rbf, secs, False, "no new %s, see %s" % (
                os.path.relpath(out_rbf, ROOT), os.path.relpath(log, ROOT))))
            print("FAILED: no new RBF (%d s)" % secs)
            continue
        data = open(out_rbf, "rb").read()
        if PREAMBLE not in data[:64]:
            results.append((rev, rbf, secs, False, "no Altera RBF preamble in %s" % os.path.relpath(out_rbf, ROOT)))
            print("FAILED: not an RBF (%d s)" % secs)
            continue
        padded = pad_rbf(data)
        write_atomic(os.path.join(STAGE, "MAPS", "%03d.RBF" % rbf), padded)
        results.append((rev, rbf, secs, True, hashlib.md5(padded).hexdigest()))
        print("ok (%d s)" % secs)

    # MAPROUT.BIN from cores.txt (as tools/mk_maprout.py)
    table = bytearray(b"\xFF" * 512)
    for mapper, rbf, _ in cores:
        table[mapper] = rbf
    write_atomic(os.path.join(STAGE, "MAPROUT.BIN"), bytes(table))

    print()
    print("%-10s %-8s %6s  %s" % ("revision", "RBF", "time", "result"))
    for rev, rbf, secs, ok, info in results:
        print("%-10s %03d.RBF %5ds  %s" % (rev, rbf, secs, ("ok  md5 " if ok else "FAILED  ") + info))
    print("MAPROUT.BIN: md5 %s (from cores/cores.txt)" % hashlib.md5(bytes(table)).hexdigest())
    print("total %d min, staging: %s" % ((time.time() - t_all) / 60, os.path.relpath(STAGE, ROOT)))
    failed = [r for r in results if not r[3]]
    if failed:
        print("%d FAILED: %s" % (len(failed), ", ".join(r[0] for r in failed)))
        sys.exit(1)


if __name__ == "__main__":
    main()
