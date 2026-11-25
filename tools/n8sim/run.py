#!/usr/bin/env python3
"""Run an OS.BIN in the n8-open simulator and print the screen.

Usage:
  python run.py OS.BIN [--sd card.img] [--frames N] [--hexfont] [--trace-sd]
                       [--press BUTTONS@FRAME ...]

Stops after N frames (default 300) or when the CPU sits in a tight loop with
interrupts off. Prints the nametable as text, the SD command log and stats.
--hexfont: tiles 1-16 are hex digits (mk_regdump.py font).
--press:  e.g. "D@120" holds Down from frame 120 for 2 frames;
          letters A B s(elect) S(tart) U D L R.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cpu6502 import CPU            # noqa: E402
from n8hw import N8Board           # noqa: E402

BUTTONS = {'A': 0x01, 'B': 0x02, 's': 0x04, 'S': 0x08, 'U': 0x10, 'D': 0x20, 'L': 0x40, 'R': 0x80}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("os_bin")
    ap.add_argument("--sd")
    ap.add_argument("--frames", type=int, default=300)
    ap.add_argument("--min-frames", type=int, default=0, help="ignore self-loops before this frame")
    ap.add_argument("--hexfont", action="store_true")
    ap.add_argument("--trace-sd", action="store_true")
    ap.add_argument("--sdsc", action="store_true", help="emulate a byte-addressed SDSC card")
    ap.add_argument("--sd-reject-writes", action="store_true", help="card answers every written block with a write error")
    ap.add_argument("--no-signature", action="store_true", help="loaded cores have no $5000 signature window (foreign cores)")
    ap.add_argument("--sram", help="battery save SRAM image: loaded at start (if it exists), saved at the end")
    ap.add_argument("--sram-dump", action="append", default=[], help="PAGE:OFFSET:LEN (hex) of save SRAM to print at the end")
    ap.add_argument("--immediate", action="store_true", help="auto-read returns the byte it clocks (hardware: previous byte)")
    ap.add_argument("--expect-rbf", help="RBF file the config stream must match")
    ap.add_argument("--abort-on-idle", action="store_true", help="$4402 = $03 mid-stream aborts the FPGA configuration")
    ap.add_argument("--our-boot-core", action="store_true", help="menu runs under our own 255.RBF (has the $5000 window)")
    ap.add_argument("--press", action="append", default=[])
    args = ap.parse_args()

    msgs = []
    board = N8Board(args.os_bin, args.sd, log=msgs.append, sdhc=not args.sdsc, expect_rbf=args.expect_rbf,
                    reject_writes=args.sd_reject_writes, no_signature=args.no_signature)
    if args.sram and os.path.exists(args.sram):
        data = open(args.sram, "rb").read()
        # the BIOS has just put the menu PRG into $18000-$1FFFF: keep it
        board.sram[0:0x18000] = data[0:0x18000]
        board.sram[0x20000:] = data[0x20000:len(board.sram)]
    board.autoread_pipelined = not args.immediate
    board.abort_on_idle = args.abort_on_idle
    board.our_core = args.our_boot_core
    cpu = CPU(board)
    cpu.reset()
    cpu.pc = 0x8000         # the BIOS enters OS.BIN with JMP $8000, not the reset vector

    presses = []
    for p in args.press:
        keys, frame = p.split("@")
        mask = 0
        for k in keys:
            mask |= BUTTONS[k]
        presses.append((int(frame), mask))

    frame = 0
    next_vblank = N8Board.CYCLES_PER_FRAME
    stuck_pc, stuck_count = None, 0
    while frame < args.frames and not cpu.halted:
        pc = cpu.pc
        cpu.step()
        if cpu.cycles >= next_vblank:
            next_vblank += N8Board.CYCLES_PER_FRAME
            frame += 1
            board.ppu.vblank = True
            if board.ppu.ctrl & 0x80:
                cpu.nmi_pending = True
            board.joy = 0
            for f, m in presses:
                if f <= frame < f + 2:
                    board.joy |= m
        # tight self-loop (JMP *) with NMI off: program is done
        if cpu.pc == pc and not (board.ppu.ctrl & 0x80) and frame >= args.min_frames:
            break

    charmap = None
    if args.hexfont:
        charmap = lambda t: "0123456789ABCDEF"[t - 1] if 1 <= t <= 16 else " "  # noqa: E731
    print(board.screen_text(charmap))
    print("-" * 32)
    print("frames %d, cycles %d, PC $%04X%s" % (frame, cpu.cycles, cpu.pc,
          ", HALTED on unknown opcode $%02X" % board.read(cpu.pc) if cpu.halted else ""))
    print("backdrop colour (palette $3F00): $%02X, rendering %s" % (board.ppu.pal[0], "on" if board.ppu.mask & 0x08 else "off"))
    print("FPGA regs:", " ".join("$%02X=$%02X" % kv for kv in sorted(board.fpga_regs.items())))
    print("CPLD: ctl=$%02X mem=$%02X nCONFIG pulses=%d, FPGA %s, config: %s, bugs: %d" %
          (board.ctl, board.mem_mode, board.nconfig_pulses, board.fpga, board.cfg_result, board.bug_count))
    if board.sd and args.trace_sd:
        print("SD log:")
        for line in board.sd.log:
            print("  " + line)
    elif board.sd:
        print("SD commands:", len(board.sd.log))
    if board.sd:
        print("SD protocol errors:", len(board.sd.errors))
        for e in board.sd.errors[:10]:
            print("  " + e)
    for m in msgs[:40]:
        print("note:", m)
    if board.ram_at_start is not None:
        r = board.ram_at_start
        print("RAM at game start, non-zero bytes: zp %d, page1 %d, page2 %d, pages3-6 %d, page7 %d" % (
            sum(1 for b in r[0:0x100] if b), sum(1 for b in r[0x100:0x200] if b),
            sum(1 for b in r[0x200:0x300] if b), sum(1 for b in r[0x300:0x700] if b),
            sum(1 for b in r[0x700:0x800] if b)))
    for d in args.sram_dump:
        page, off, n = (int(x, 16) for x in d.split(":"))
        base = page * 0x2000 + off
        print("SRAM page %X +%04X: %s" % (page, off, board.sram[base:base + n].hex(" ")))
    if args.sram:
        with open(args.sram, "wb") as f:
            f.write(board.sram)


if __name__ == "__main__":
    main()
