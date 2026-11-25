# EverDrive N8 (clone) - menu hardware interface

Status: work in progress, 2026-11-24.
Source: static analysis of Krikzz OS v1.26 (plain 6502, cc65-compiled C) for
interoperability. Only register addresses, bits and sequences are recorded
here. No code is copied; the open menu is written from scratch.

Confidence tags: **[confirmed]** seen unambiguously in code or tested on the
clone, **[likely]** consistent usage, **[guess]** needs a hardware test.

## OS.BIN loading [confirmed]

- File: `/EDFC/OS.BIN`, 57344 bytes.
- `0x0000-0x1FFF`: CHR, 8 KB (menu font, normal 2bpp tiles).
- `0x2000-0x5FFF`: unused (v1.26 fills `0x2000-0x3FFF` with `0xAA`, the rest with `0x00`).
- `0x6000-0xDFFF`: PRG, 32 KB, mapped to CPU `$8000-$FFFF`, vectors at `$FFFA`.
- The clone bootloader starts a plain image. Tested 2026-11-24 with our own
  red-backdrop test (`tools/mk_testos.py`).
- PRG is RAM while the menu runs: v1.26 rewrites its own vectors at `$FFFA-$FFFF`.
- **Entry point is `$8000`, not the reset vector.** The BIOS sets reg `$09` = 1
  and does `JMP $8000` (seen in the BIOS dump at `$FF0D`). Our first menu build
  had an `RTI` at `$8000` and crashed (sky-blue screen) although its reset
  vector was correct.

## Architecture (Krikzz mapper sample, 2013) [confirmed]

Source: `fpga-mapper-sample` (Quartus 12.0 SP2 project for EP2C5T144C8, top
`main.v`, OS map `map_255.v`, sample mappers 0, 2, 11). Reference only: the
sample has no license, so no Verilog is copied into this project. Pin numbers
are hardware facts and are listed in `pinout.md`.

- **Every RBF contains the "OS map" (mapper index 255)** next to its game
  mappers. After configuration the core starts in OS map mode
  (`map_idx = $FF`); the menu-mode registers below live in the FPGA.
- **The MAX II CPLD sits on the same bus** and has its own registers. The
  FPGA drives two mode lines to it (`max0`, `max1`): `11` = CPLD registers
  unlocked (OS map active), `01` = locked (game running), `00` = LED/bus
  spy, `10` = force bus outputs. A third line (`max2`) comes back as
  `bios_off`.
- **The Cyclone II is configured in passive serial mode** (DATA0, DCLK,
  nCONFIG, nSTATUS, CONF_DONE are wired), which fits the MAX II streaming RBFs
  from SD or the BIOS flash.
- **Memories:** CPU A0-A9 go straight to the SRAMs; the FPGA drives the upper
  address lines (`prg_map[8:0]` = PRG A10-A18, `chr_map[8:0]` = CHR A10-A18)
  and all chip enables. The save SRAM shares the PRG address lines
  (`ram_ce/oe/we`).
- **Reset to menu:** the core watches M2. When M2 stops (the console's reset
  button holds the CPU), the core returns to `map_idx = $FF` after a timeout.
  The timeout is short or long depending on reg `$88` bit 0.

## Register access [confirmed]

| Address | Access | Function |
|---|---|---|
| `$4400` | W | register index |
| `$4401` | R/W | data of the selected register |

Decoded in `$4400-$45FF`, mirrored every 4 bytes (`addr[1:0]` = 0 index,
1 data). FPGA register writes only take effect while the OS map is active.

## FPGA registers (OS map, all write-only) [confirmed]

| Reg | Name in sample | Bits | Function |
|---|---|---|---|
| `$80` | PRG_MAPA | 7:0 | 2 KB page of PRG RAM shown at **`$4800-$4FFF`** (read/write). This is how the menu loads game PRG. |
| `$81` | SRM_MAPA | 5:0 | 8 KB page of the **save SRAM** shown at `$6000-$7FFF`. The menu uses `$08` for itself (SRAM offset 64 KB) and `$00-$03` for saves. |
| `$82` | CHR_MAPA | 6:0 | 4 KB page of CHR RAM: PPU `$1000-$1FFF` = page n, `$0000-$0FFF` = page n-1. The menu loads CHR through `$2006/$2007`. |
| `$83` | MAPPER | 7:0 | **active mapper index**; `$FF` = OS map. Writing a game mapper index switches the core into game mode (the start stub does this). |
| `$84` | PRG_SIZE | 4:0 | PRG mask on A14-A18 (16 KB units) |
| `$85` | CHR_SIZE | 5:0, 7 | CHR mask on A13-A18 (8 KB units); bit 7 = CHR RAM present (passed to the mapper as `map_cfg[7]`) |
| `$86` | MAP_CFG | 6:0 | mapper config bits (`map_cfg[6:0]`); e.g. mapper 0: bit 0 = mirroring (1 = vertical) |
| `$87` | GG | 7:0 | Game Genie: a read resets the code index, then 4 writes per code (compare value, replacement value, address high with bit 7 = compare enable, address low), up to 5 codes; matches CPU reads in `$8000-$FFFF` |
| `$88` | CART_CFG | 0 | reset mode: 0 = short M2 timeout, 1 = long timeout before returning to the menu. Probably the menu option "Reset to game" (ON = a short reset restarts the game) **[likely]** |

Memory map in OS map mode:
- `$8000-$FFFF`: the menu's PRG, at PRG/SRAM offset `$18000-$1FFFF`. With
  `bios_off` set by the CPLD, this range comes from the **save SRAM**, not
  from PRG RAM. That is why the sample mapper warns games not to write to the
  top 64 KB of the battery RAM ("it may damage os code").
- `$6000-$7FFF`: save SRAM window (reg `$81`).
- `$4800-$4FFF`: PRG RAM window (reg `$80`).

Save SRAM keeps its contents through power-off and the BIOS boot
**[confirmed 2026-11-25]**: Zelda's `$5A`/`$A5` markers in page 0 (the
game's `$6000-$7FFF` in our cores) were still there after a power cycle,
read by the menu. All battery games share page 0, so saves have to be
copied to/from SD per game.

## CPLD interface from the BIOS dump [confirmed in code, 2026-11-24]

Origin: very likely Krikzz's N8 bootloader (or directly derived from it) - its
error screen sends the user to krikzz.com for "nesos.zip".

**Boot files** (name table at `$ECBD`): the BIOS looks up `/EDFC`, `/EDFC/MAPS`,
`/EDFC/OS.BIN` and **`/EDFC/MAPS/255.RBF`**. It loads `255.RBF` from the SD card
as the **menu-mode core** (the core `OS.BIN` runs under) and stops with
"ERROR: 1x - System files not found!" if a file is missing:
`10` EDFC, `11` MAPS, `12` OS.BIN (by order), `13` 255.RBF (seen on hardware
2026-11-25 after deleting it).

Source: 16 KB BIOS window read with `tools/mk_biosdump.py` + the dump helper
core (`test/dump/bios16k.bin`; the window appears twice in `$8000-$FFFF`).
Reset vector `$FC40`, NMI/IRQ `$FFCB`. A jump table of BIOS functions sits at
`$FC1E` (`$FC53, $FC64, $FC77, $FC7F, $FD11, $FD4A, $FD8B, $FDD8, $FE31,
$FE53, $FE5B, $FF27, $FC87, $FE96, $FF34, $FF0D, $FFA7`).

Besides the indexed pair `$4400/$4401`, the CPLD decodes two direct ports:

| Address | Dir | Function |
|---|---|---|
| `$4402` | W | transfer mode: `$03` idle (set at reset), `$05` while streaming SD data into the FPGA configuration |
| `$4403` | R | status: bit 0 = SPI transfer done, bit 1 = USB byte available, bit 2 = USB ready to send |
| `$4403` | W | one byte of FPGA configuration data (used while `$4402 = $05`) |

CPLD registers behind `$4400/$4401`:

| Reg | Dir | Function |
|---|---|---|
| `$00` | R/W | **SPI data (SD card)**: a write sends a byte, a read returns the received byte. With reg `$02` bit 2 set, every read clocks the next byte (sends `$FF`) **and returns the byte of the previous transfer** (confirmed on hardware 2026-11-24: probe offset 01). So after enabling auto-read, the first read is stale; a sector is then 512 plain `LDA $4401` |
| `$01` | R/W | USB FIFO data (FTDI-style; the clone has no USB connector) |
| `$02` | R/W | control: bit 0 = SPI speed (set/cleared by `$FE31`), **bit 1 = SD chip select** (1 = deselected), **bit 2 = auto-read mode**, bit 3 = a setting the BIOS writes from one of its options (`$D56B`, from `$056B` bit 0) - **not CONF_DONE** (an earlier version of this document claimed that; disproved on hardware 2026-11-24). Reads `$09` right after boot |
| `$05` | W | FPGA configuration data byte (used when configuring from the flash) |
| `$06` | W | FPGA **nCONFIG**: write `0`, wait, write `1`, wait -> the FPGA clears and waits for a new bitstream |
| `$07` | R/W | **flash bank**: 16 KB bank of the BIOS flash shown at `$8000` (and mirrored at `$C000`) in flash mode |
| `$09` | R/W | bits 1:0 = source of `$8000-$FFFF` (see below). **bit 3 = save states on** (Krikzz option [3]), **bit 4 = set before every game start** (v1.26 `$AEFA-$AF57`). With save states off Krikzz's menu starts games with `$11`. Our tests with `$01` (bit 4 missing) and `$19` (save-state bit wrongly set) both crashed on reset; `$11` under test 2026-11-24 |

SD card access (SPI mode), as done by the BIOS:
- **Command** (`$FDD8`): CS low (reg `$02` bit 1 = 0), send `$FF`, command
  byte, 4 argument bytes (big-endian), CRC, then `$FF $FF`; read until the
  response is not `$FF`.
- **Read sectors** (`$FD11`): set auto-read (reg `$02` bit 2), select reg `$00`,
  wait for the data token `$FE`, read 512 bytes, skip the CRC, repeat per
  sector; clear auto-read at the end. `$FD4A` does the same into PPU `$2007`
  (CHR loading).
- **Write sector** (`$FC87`): send `$FF $FF $FC` (multi-block write token),
  512 data bytes, then wait for the card.

Loading a core (RBF) into the FPGA:
- From SD (`$FF34` path): reg `$06` nCONFIG pulse, auto-read on, `$4402 = $05`,
  then for each SD byte `LDA $4401 / STA $4403`; `$4402 = $03` at the end.
- From the flash (`$C06C`): reg `$06` pulse, then for flash banks 1-4 (reg `$07`)
  write the 16 KB at `$8000` byte by byte to reg `$05`. **The boot core lives in
  flash banks 1-4 (64 KB).**
- No status bit for "configured" is known; the BIOS streams the core and just carries on.

Clone menu (2015, the one on the card), readable part `$A000-$DFFF`:
`$09 = $05` somewhere in the menu (`$B2E0`); before a normal game bits 2 and 4
are CLEARED (`$AF9F`, so games run with `$01`), set for FDS (`$AF89`), bit 3
for save states. It also reads a register `$8A` (`$AF67`) that v1.26 does not
use. Core loading is not in the readable part (no `$4402/$4403`, no reg `$06`
access): it sits in the scrambled blocks or calls the BIOS jump table.

**Reset from a game** (2026-11-24): with our menu the CPU crashed after reset
(screen keeps the game's backdrop, the BIOS does not run - it would set palette
`$05` first). With `$09` = `$01`, `$19` and `$11` at game start alike. With the
clone menu, reset returned to its menu. Working theory: after a console reset
the CPLD does not raise `max2` ("BIOS off") again, so nothing answers at
`$FFFC`. Our cores now show the menu image at `$8000` by themselves after a
reset from game mode (`ret_menu` in `cores/nrom/osmap.v`). **Open:** why the
CPLD behaves differently after the clone menu (scrambled code / BIOS calls).

Krikzz option block (v1.26, pointer at `$04A7`): [0] file sorting, [1] reset to game (-> FPGA `$88`),
[2] swap A/B, [3] save state (-> CPLD `$09` bit 3), [4]/[5] save/load state keys (-> `$8B`/`$8C`), [6] audio balance.

## CPLD registers (MAX II), first notes

Everything v1.26 touches that the OS map does not decode belongs to the CPLD:
reads `$00-$1F` (see the read test below) and the accesses to `$09`, `$0A`,
`$8B`, `$8C`, `$8F`, `$90`. The CPLD is wired to the microSD slot and the BIOS
flash and configures the FPGA, so **SD access and RBF loading go through
these registers**. Their protocol is still open.

| Reg | Seen in v1.26 | Notes |
|---|---|---|
| `$09` | R/W, read-modify-write of bits 4 and 3; also written `$09` | **bits 1:0 = what appears at `$8000-$FFFF`** [confirmed in code]: `01` = menu (save SRAM), `10` = BIOS flash (M29W160, command interface live). v1.26 switches to `10` only from code running in RAM at `$0400`. |
| `$0A` | R | |
| `$8B`, `$8C` | W | save/load state key combos (Krikzz options [4]/[5]), `$FF` = save states off **[confirmed in v1.26]** |
| `$8F` | W | |
| `$90` | W `$1A`, just before the game start path | |

## Mapper files (Krikzz documentation) [confirmed]

- Mapper cores are `/EDFC/MAPS/NNN.RBF`: plain Quartus RBF output, unchanged.
- Size should be a multiple of 512, padded with `0xFF`. File names must be
  upper case (the OS may not find lower-case names copied from Linux).
- One RBF can implement several mappers. The OS selects the active one by
  writing its index to reg `$83`.
- `MAPROUT.BIN` = two tables of 256 bytes, one byte per iNES mapper number,
  value = RBF number (decimal file name), `0xFF` = not supported:
  - offset `0x000`: normal mappers
  - offset `0x100`: save-state mappers. With save states on, the OS checks this
    table first and falls back to the normal table when it holds `0xFF`.
  - entry `0xFF` in both tables: reserved for the OS, always `0xFF`.
  - entry `0xFE`: FDS.
- The original N8 can also load an RBF over USB straight into the FPGA (no SD
  write; active until reset). The clone board has no USB connector, so this
  path does not exist here.

Menu error codes seen on the clone:
- `ERROR:A1`: the RBF named in `MAPROUT.BIN` is missing from `/EDFC/MAPS/`.

## Read test on the clone [confirmed, 2026-11-24]

`tools/mk_regdump.py`: reads registers `$00-$1F` and `$80-$9F` right after boot,
then again about 1 s later. Both snapshots were identical.

| Reg | Value |
|---|---|
| `$00` | `$7A` |
| `$01` | `$00` |
| `$02` | `$09` |
| `$03-$06` | `$01` |
| `$07` | `$00` |
| `$08-$1F` | `$01` |
| `$80-$9F` | `$44` |

- **`$80-$9F` are write-only.** `$44` is open bus: the last byte on the data
  bus was the high byte of the operand address `$4401`.
- **`$00-$07` return individual values.** `$00 = $7A` and `$02 = $09` are
  candidates for core ID/version bytes.
- **`$08-$1F` all read `$01`.** Either an undecoded default, or registers that
  read back 1 after boot. Writing them and reading back would tell.
- No register changed within 1 s, so none of these are free-running counters.

## Game start sequence [confirmed]

1. Rendering and DMC off, PPU palette cleared.
2. A small stub is copied to RAM at `$0400` and executed from there.
3. The stub writes index `$83`, waits for vblank, writes the start value to `$4401`,
   disables the APU frame IRQ, sets SP=`$FD`, pushes P=`$34`, clears A/X/Y,
   and jumps through the game's reset vector `($FFFC)`.

## BIOS flash access in v1.26 [confirmed] - SAFETY

v1.26 copies two routines to RAM (`$0400`) that switch reg `$09` to flash mode:
- **CFI query**: `$98` to `$80AA`, read 256 bytes from `$8000`, then `$F0` (read mode).
- **Chip erase**: the standard AMD/ST sequence (`$AA`/`$55`/`$80`/`$AA`/`$55`/`$10`
  to `$8AAA`/`$8555`), part of the BIOS update. It is only run when a RAM
  variable holds `$AA`.

**Rule for our code: never write a flash command sequence.** A chip erase wipes
the bootloader, and the cart then needs a programmer to recover. Reads in
flash mode are harmless.

## Open questions

1. **SD and RBF loading: answered** by the BIOS dump (see above). Still to
   verify on hardware with our own menu.
2. Meaning of the rest of the 2 MB flash (banks beyond 0-4) and of reg `$02`
   bit 0. The v1.26 read of `$87` is the Game Genie index reset.
