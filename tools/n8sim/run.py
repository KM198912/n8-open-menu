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
import fds_boot                    # noqa: E402

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
    ap.add_argument("--region", choices=["ntsc", "pal", "dendy"], default="ntsc", help="console timing (cycles per frame)")
    ap.add_argument("--prg-dump", action="append", default=[], help="OFFSET:LEN (hex) of PRG RAM to print at the end")
    ap.add_argument("--sram", help="battery save SRAM image: loaded at start (if it exists), saved at the end")
    ap.add_argument("--sram-dump", action="append", default=[], help="PAGE:OFFSET:LEN (hex) of save SRAM to print at the end")
    ap.add_argument("--immediate", action="store_true", help="auto-read returns the byte it clocks (hardware: previous byte)")
    ap.add_argument("--expect-rbf", help="RBF file the config stream must match")
    ap.add_argument("--abort-on-idle", action="store_true", help="$4402 = $03 mid-stream aborts the FPGA configuration")
    ap.add_argument("--our-boot-core", action="store_true", help="menu runs under our own 255.RBF (has the $5000 window)")
    ap.add_argument("--press", action="append", default=[])
    ap.add_argument("--sram-kb", type=int, choices=[128, 256], default=256,
                    help="save SRAM the menu can address (128: A17 not reaching the chip)")
    ap.add_argument("--dark-after", type=int, default=None,
                    help="count frames with rendering off from this frame on (flicker check)")
    ap.add_argument("--fds-call", help="FDS: after --fds-frames, call this game routine (hex address, A = 0) "
                    "with NMI and timer off, and report A (e.g. Zelda II's save: 8520)")
    ap.add_argument("--fds-poke", action="append", default=[], help="FDS: ADDR=HEXBYTES written to CPU memory before --fds-call")
    ap.add_argument("--fds-frames", type=int, default=900,
                    help="FDS game start ($83 = $FE): frames to run the BIOS on the FDS core model")
    args = ap.parse_args()

    msgs = []
    N8Board.CYCLES_PER_FRAME = {"ntsc": 29780, "pal": 33248, "dendy": 35464}[args.region]
    board = N8Board(args.os_bin, args.sd, log=msgs.append, sdhc=not args.sdsc, expect_rbf=args.expect_rbf,
                    reject_writes=args.sd_reject_writes, no_signature=args.no_signature)
    if args.sram and os.path.exists(args.sram):
        data = open(args.sram, "rb").read()
        # pages 0-8 survive power-off; the BIOS has just rewritten pages 9-15
        # ($12000-$1FFFF) from OS.BIN: keep those
        board.sram[0:0x12000] = data[0:0x12000]
        board.sram[0x20000:] = data[0x20000:len(board.sram)]
    board.autoread_pipelined = not args.immediate
    board.sram_mask = args.sram_kb * 1024 - 1
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
    fds = None
    vbl_len = {"ntsc": 2273, "pal": 7459, "dendy": 2273}[args.region]
    dark = []
    while frame < args.frames and not cpu.halted:
        pc = cpu.pc
        cpu.step()
        board.ppu.now = cpu.cycles
        if fds is None and board.fpga == "game" and board.map_idx == 0xFE:
            fds = fds_hand_over(board, cpu, args.fds_frames, args.fds_call, args.fds_poke)
            break
        if cpu.cycles >= next_vblank:
            next_vblank += N8Board.CYCLES_PER_FRAME
            frame += 1
            board.ppu.vblank = True
            board.ppu.vbl_end = cpu.cycles + vbl_len
            if args.dark_after is not None and frame >= args.dark_after and not board.ppu.mask & 0x18:
                dark.append(frame)
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
    if fds is not None:
        print(fds)
    if args.dark_after is not None:
        print("frames with rendering off from frame %d: %d %s" % (args.dark_after, len(dark), dark[:20]))
    for d in args.prg_dump:
        off, n = (int(x, 16) for x in d.split(":"))
        print("PRG +%05X: %s" % (off, board.prg[off:off + n].hex(" ")))
    for d in args.sram_dump:
        page, off, n = (int(x, 16) for x in d.split(":"))
        base = page * 0x2000 + off
        print("SRAM page %X +%04X: %s" % (page, off, board.sram[base:base + n].hex(" ")))
    if args.sram:
        with open(args.sram, "wb") as f:
            f.write(board.sram)


def fds_hand_over(board, cpu, frames, call=None, pokes=()):
    """The menu started an FDS game: check what it sent to the core, then
    run the BIOS on the FDS core model with the PRG SRAM the menu filled."""
    out = []
    port = board.fds_port
    words, lo, addr_ok = [], None, port[:2] == [(0x91, 0), (0x92, 0)]
    side_reg = None
    ids, id_p = [[0] * 10 for _ in range(4)], None
    for idx, v in port[2:]:
        if idx == 0x96:
            id_p = v & 0x3F
        elif idx == 0x97 and id_p is not None:
            if id_p & 15 <= 9:
                ids[id_p >> 4][id_p & 15] = v
            id_p = (id_p + 1) & 0x3F
        elif idx == 0x93:
            if lo is None:
                lo = v
            else:
                words.append(lo | (v << 8))
                lo = None
        elif idx == 0x94:
            side_reg = v
    out.append("FDS start: table port address reset %s, %d entries, $94 = %s, CPLD $09 = $%02X, regs %s" % (
        "ok" if addr_ok else "MISSING", len(words), "$%02X" % side_reg if side_reg is not None else "never",
        board.mem_mode, " ".join("$%02X=$%02X" % kv for kv in sorted(board.fpga_regs.items()) if kv[0] < 0x90)))
    tables = fds_boot.tables_from_core(words)
    ref = [fds_boot.fdsdisk.block_table(fds_boot.side_bytes(board.prg, board.sram, i)) for i in range(4)]
    used = [i for i in range(4) if tables[i] and tables[i][0] != 0xFFFF]
    out.append("  tables equal to fdsdisk.block_table of the sides in SRAM: %s" % (
        "yes" if all(tables[i] == ref[i] for i in used) else "NO"))
    bios_ok = (board.prg[0x81CE:0x81D4] == bytes.fromhex("200057200457") and
               board.prg[0x8729:0x872C] == bytes.fromhex("200857") and
               board.prg[0x8445:0x8448] == bytes.fromhex("202057"))
    out.append("  BIOS at $08000 patched: %s" % ("yes" if bios_ok else "NO"))
    ref_ids = [list(fds_boot.fdsdisk.side_id(fds_boot.side_bytes(board.prg, board.sram, i))) for i in range(4)]
    out.append("  side IDs sent ($96/$97) equal to block 1 $0F-$18 of the sides: %s" % (
        "yes" if id_p is not None and all(ids[i] == ref_ids[i] for i in used) else "NO"))
    for i, t in enumerate(tables):
        if t and t[0] != 0xFFFF:
            out.append("  side %d: %d blocks, end %d" % (i, len(t) - 2, t[-2]))
    fb = fds_boot.FDSBoard(board.prg, tables, side=(side_reg or 0) & 3, ram=board.ram, log=lambda s: None,
                           sram=board.sram, ids=ids)
    cpu.bus = fb
    cpu.irq_line = fb.irq_line
    frame, next_vblank, game_frame = 0, cpu.cycles + 29780, None
    while frame < frames and not cpu.halted:
        c = cpu.step()
        fb.advance(c if c else 2)
        if cpu.cycles >= next_vblank:
            next_vblank += 29780
            frame += 1
            fb.ppu.vblank = True
            if fb.ppu.ctrl & 0x80:
                cpu.nmi_pending = True
        if game_frame is None and 0x6000 <= cpu.pc < 0xE000:
            game_frame = frame
    out.append("== FDS nametable $2800")
    out.append(fds_boot.nt_text(fb.ppu, 0x2800))
    out.append("== FDS: %d frames, PC $%04X%s, game code from frame %s, blocks read %s, lost bytes %d" % (
        frame, cpu.pc, " HALTED" if cpu.halted else "", game_frame, fb.blocks_read[:40], fb.lost))
    if call:
        for p in pokes:
            addr, data = p.split("=")
            for k, byte in enumerate(bytes.fromhex(data)):
                fb.write(int(addr, 16) + k, byte)
        fb.write(0x4022, 0)                          # timer off
        fb.ram[0xFF] &= 0x7F                         # game NMI off (BIOS owns $00-$0F)
        fb.ppu.ctrl &= 0x7F
        cpu.nmi_pending = False
        fb.ram[0x7F0:0x7F3] = bytes([0x4C, 0xF0, 0x07])  # trap: JMP $07F0
        cpu.push(0x07)
        cpu.push(0xEF)
        cpu.a = 0
        cpu.pc = int(call, 16)
        end = cpu.cycles + 40 * 1789773
        while cpu.cycles < end and cpu.pc != 0x07F0 and not cpu.halted:
            c = cpu.step()
            fb.advance(c if c else 2)
        out.append("== FDS call $%s: %s, A = $%02X, blocks written %s" % (
            call, "returned" if cpu.pc == 0x07F0 else "DID NOT RETURN", cpu.a, fb.written))
    return "\n".join(out)


if __name__ == "__main__":
    main()
