# Testing

Everything is tested offline before it goes onto the cartridge: the cores
with Icarus Verilog, the menu in a 6502 + cartridge simulator.

## Cores: Icarus Verilog testbenches

```
cores/tb/run.sh          (Icarus Verilog 12; on Windows through WSL:
                          wsl -e sh /mnt/<path>/cores/tb/run.sh)
```

| Testbench | Covers |
|---|---|
| `tb_mmc1.v` | MMC1 serial port, PRG/CHR modes, mirroring, PRG RAM, SUROM |
| `tb_mmc3.v` | MMC3 banking, PRG RAM protect, scanline IRQ with a PPU fetch model (A12 filter, latch 0, BG/sprite table layouts) |
| `tb_mmc5.v` | MMC5 PRG/CHR/RAM, nametables, fill mode, ExRAM, scanline detection and IRQ from real PPU reads, 8x16 sets, extended attributes; monitors that the data buses are only driven when allowed |
| `tb_simple.v` | discrete mappers (`-Ptb_simple.M=<mapper>`): UxROM |
| `tb_fds_snd.v` | FDS sound against `tools/n8sim/fds_audio.py`, cycle for cycle (`fds_audio.py gen` writes the stimulus, `check` compares): wave, modulation, envelopes, master volume, halts, write protection, reads |
| `tb_fds.v` | FDS: memory map, registers, timer IRQ incl. the PAL correction (Zelda II's split line), BIOS stub, disk stream through the read window (lead-in, blocks, CRC, gaps, end of disk, the BIOS's short reset pulse), overrun -> CRC error bit, a write session with the block table update and the BIOS's flush byte, the side swap (manual; automatic: game polls vs. BIOS polls, threshold, pause reset, arming, the `$5720` stub, side by ID with wildcards, 2 and 4 sides); the lead-in is shortened to 200 byte times (`defparam`), ~15 s per run |

The testbenches drive real bus cycles (M2 low/high, data hold after the
falling edge) and, where it matters, a PPU model with per-dot fetches.
Icarus' `-P` only reaches parameters of the top module: testbenches set the
DUT's `MAPPER` on the instance, or (tb_simple) have their own parameter.

Each check set is validated with mutations: break one thing in the HDL
(sed on a temporary copy), the testbench must fail. Long testbenches
(MMC5: ~40 s per run) are best run in the background, one run per mutation.

## FDS: BIOS boot (`tools/n8sim/fds_boot.py`)

```
python tools/n8sim/fds_boot.py <DISKSYS.ROM> <game.fds> [--frames N] [--side N]
```

Runs the user's own BIOS dump, patched as the menu patches it
(`fdsdisk.py`: `.fds` sides, block tables, BIOS patch), on a Python model
of `map_fds.v`, from the BIOS reset vector. Prints both nametables (BIOS
font), the frame the game's code was first reached, the blocks read and
written, and lost bytes. NTSC only; base cycle counts (slightly
optimistic). The model has the automatic side swap too (`FDSBoard`:
`auto_ejects`, `id_swaps`). Zelda II (2026-11-26): license screen, all 16 blocks of side
A, game code from frame 743, no lost bytes; the BIOS needs 92-105 cycles
per byte after taking it (+ ~20 to take it) of the 149 available.

The menu side is covered too: when `run.py` sees a game start with mapper
index `$FE`, it checks what the menu sent to the FDS core (table port,
`$94`, CPLD `$09`), compares the tables entry by entry with
`fdsdisk.block_table` of the sides in PRG SRAM, checks the BIOS patch,
and then runs the BIOS on the FDS model with the PRG SRAM the menu
filled (`--fds-frames N`, default 900). `--fds-call ADDR` then calls a
game routine with NMI and timer off (`--fds-poke ADDR=HEX` first), e.g.
Zelda II's save at `8520`; with `--sram FILE` a second run (the power-on)
writes the save back into the `.fds` on the image. Card: `EDFC/DISKSYS.ROM`,
`MAPROUT.BIN` with `254 120`, `MAPS/120.RBF`, the `.fds` file.

## Menu: simulator (`tools/n8sim`)

```
python tools/n8sim/run.py menu/build/OS.BIN --sd card.img [options]
```

| Option | |
|---|---|
| `--frames N`, `--press KEYS@FRAME` | run time; buttons `A B s(elect) S(tart) U D L R` |
| `--dark-after N` | count frames with rendering off from frame N (flicker check; PPUDATA writes with rendering on are flagged only outside vblank) |
| `--our-boot-core` | the menu runs under our `255.RBF` (has the `$5000` window) |
| `--expect-rbf FILE` | the configuration stream must equal this RBF |
| `--abort-on-idle` | `$4402 = $03` during a stream aborts it (as on hardware) |
| `--sdsc`, `--trace-sd`, `--sd-reject-writes` | byte-addressed card, SD log, card refuses writes |
| `--sram FILE`, `--sram-dump P:OFF:LEN` | battery SRAM kept across runs (= power cycle), dump |
| `--no-signature` | loaded cores act like foreign cores (no `$5000` window) |
| `--region ntsc\|pal\|dendy` | console timing (cycles per frame) for the region detection |
| `--prg-dump OFF:LEN` | PRG RAM bytes at the end (e.g. to check a PAL patch) |

It reports the screen, PPU writes during rendering, CPU accesses to FPGA
memory while the FPGA is configured, SD protocol errors, the core start
(mapper and registers) and the CPU RAM the game starts with.

SD images: `tools/mk_sdimg.py <folder> <out.img>` with `--mb`, `--spc N`,
`--no-mbr`, `--fragment`, `--fsinfo` (real free count, as Windows writes it),
`--shuffle SEED` (random directory order).

FAT checks: `tools/fatcheck.py card.img [--tree] [--dump PATH]` - both FAT
copies, chains, cross-links, lost clusters, LFN checksums, duplicates,
FSInfo. Independent of the menu's code; WSL's `mtools` (`mdir -i img@@1M`)
is a second, foreign opinion.

Test builds of the menu: `ca65 -D SDW_TEST -I tests ...` (SD writes),
`-D FATW_TEST [-D FT_COUNT=n -D FT_BASE=n]` (creating files/directories).

## A/B test against a foreign core

To find out whether a fault comes from our core or from elsewhere, the same
game can be started on another core (e.g. the original firmware's, renamed):

- build a diagnostic menu: `ca65 -D AB_TEST` - cores numbered 200 and up are
  started without the `$5000` signature check;
- a MAPROUT that sends the mapper to that number (copy `cores/cores.txt`,
  change the line, `tools/mk_maprout.py <copy> <out>`);
- put the foreign core on the card as `MAPS/2NN.RBF`.

First use: Castlevania (USA) showed the same status bar fault on both cores
and on the complete original firmware - an NTSC game on a PAL console.
