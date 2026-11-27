# n8-open menu (`OS.BIN`)

Open replacement for the cartridge's menu, written in 6502 assembly (ca65)
from `docs/hw-interface.md`. The cartridge's BIOS (in its flash) loads it from
`/EDFC/OS.BIN` and jumps to `$8000`.

## Features

- Browse the SD card (FAT32, MBR or superfloppy, SDSC/SDHC): folders first,
  then files alphabetically (case-insensitive), long file names.
  Up/Down (auto-repeat), Left/Right page, A on a folder opens it, B back.
  Up to 127 entries per folder. `/EDFC` (firmware, cores, BIOS, saves) is
  not listed.
- Select: `SUPPORTED MAPPERS` - the mapper numbers the card's
  `/EDFC/MAPROUT.BIN` routes to a core, and whether FDS is supported
  (`src/mapinfo.s`). B goes back.
- A on a ROM: the file menu, a box over the list (Up/Down, A confirms,
  B closes); `SELECT + LOAD` (highlighted first) starts the game. `SELECT + LOAD` / `SELECT ONLY` store the game as the last
  game (and start it / go back to the list); `START: <name>` above the
  status line shows it, also after power-off. Start loads it from any
  folder (B then leads back to where you were); if the file is no longer
  there: `ERROR 4C`. Details: `src/lastgame.s`. `ROM INFO`: info screen (mapper, PRG/CHR sizes, mirroring, battery,
  trainer, iNES/NES 2.0, whether a core exists); for `.fds` images the
  header, sides, game code/version, whether `DISKSYS.ROM` is there and the
  FDS core.
- Start a game: iNES header -> `/EDFC/MAPROUT.BIN` -> `/EDFC/MAPS/NNN.RBF`;
  PRG into PRG RAM, CHR via the PPU, then the core is streamed from SD into
  the FPGA by code running in CPU RAM (`src/ramload.s`), CPU RAM is cleared
  as after power-on, and the game starts through its reset vector.
  "LOADING..." stays on screen during PRG; no flashing colours.
- NTSC games on a PAL console: region detection, IRQ correction in the
  cores (`$86` bit 6) and verified patches for known cases
  (`src/region.s`); B held with A starts without it. See `../README.md`.
- Battery saves: raw 8 KB `/EDFC/SAVE/<rom name>.sav` (the format emulators
  use), loaded at game start, written back at the next power-on
  ("SAVING..."). Details and safety checks: `src/save.s`.
- FDS disk images (`.fds`, with or without the 16-byte header, up to 4
  sides): need the user's own BIOS dump as `/EDFC/DISKSYS.ROM` (8 KB) and
  the FDS core (`MAPROUT.BIN` entry `$FE`). The menu patches four
  instructions of the BIOS (checked against the original bytes), copies
  the sides, block tables and side IDs for the core and starts the BIOS;
  side A is inserted. Side swap: automatic - on a "change side" screen the
  disk is ejected after about a second and the next side goes in; when the
  game asks the BIOS for a particular side, the core inserts that one.
  Manual fallback: hold Select + Down for about a second. Saves: what the game
  writes to side A goes back into the `.fds` file at the next menu start
  ("SAVING...", a few seconds; only changed sectors are written). Writes to
  other sides are lost at power-off (the battery RAM holds one side).
  Details: `src/fds.s`, `cores/nrom/map_fds.v`.
- Errors: `ERROR xx` on the status line; codes are listed at the top of
  `src/sd.s`, `src/fat32.s`, `src/fatw.s`, `src/loader.s`, `src/save.s`,
  `src/fds.s`.
  If a core cannot be started, the screen turns one steady colour (see
  `src/ramload.s`); power-cycle to recover.

Not yet: Game Genie, save states, trainers, save sizes other than 8 KB.

## Source

| File | |
|---|---|
| `src/main.s` | entry, variables, list display, sorting, main loop |
| `src/sd.s` | SD card over the CPLD's SPI port (read, write) |
| `src/fat32.s` | mount, directories, long names, file streams |
| `src/fatw.s` | FAT32 writing: allocation, entries, files, directories |
| `src/loader.s` | iNES header, MAPROUT lookup, PRG/CHR loading |
| `src/fds.s` | FDS images: detection, BIOS patch, sides, block tables |
| `src/ramload.s` | code that runs from CPU RAM while the FPGA is reconfigured |
| `src/save.s` | battery saves |
| `src/rominfo.s` | the info screen |
| `src/region.s` | console/game region, NTSC-on-PAL decision, patch list |
| `tests/` | test builds (`-D SDW_TEST`, `-D FATW_TEST`) and `hello.nes` |

## Build

`build.bat` (cc65 on `PATH`, or `set CC65=<cc65 bin folder>`) ->
`build/OS.BIN` and the test ROM `build/hello.nes`.

Testing in the simulator: see `../docs/testing.md`.
