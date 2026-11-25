# n8-open menu (`OS.BIN`)

Open replacement for the cartridge's menu, written in 6502 assembly (ca65)
from `docs/hw-interface.md`. The cartridge's BIOS (in its flash) loads it from
`/EDFC/OS.BIN` and jumps to `$8000`.

## Features

- Browse the SD card (FAT32, MBR or superfloppy, SDSC/SDHC): folders first,
  then files alphabetically (case-insensitive), long file names.
  Up/Down (auto-repeat), Left/Right page, A/Start open, B back.
- Select on a ROM: info screen (mapper, PRG/CHR sizes, mirroring, battery,
  trainer, iNES/NES 2.0, whether a core exists).
- Start a game: iNES header -> `/EDFC/MAPROUT.BIN` -> `/EDFC/MAPS/NNN.RBF`;
  PRG into PRG RAM, CHR via the PPU, then the core is streamed from SD into
  the FPGA by code running in CPU RAM (`src/ramload.s`), CPU RAM is cleared
  as after power-on, and the game starts through its reset vector.
  "LOADING..." stays on screen during PRG; no flashing colours.
- Battery saves: raw 8 KB `/EDFC/SAVE/<rom name>.sav` (the format emulators
  use), loaded at game start, written back at the next power-on
  ("SAVING..."). Details and safety checks: `src/save.s`.
- Errors: `ERROR xx` on the status line; codes are listed at the top of
  `src/sd.s`, `src/fat32.s`, `src/fatw.s`, `src/loader.s`, `src/save.s`.
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
| `src/ramload.s` | code that runs from CPU RAM while the FPGA is reconfigured |
| `src/save.s` | battery saves |
| `src/rominfo.s` | the info screen |
| `tests/` | test builds (`-D SDW_TEST`, `-D FATW_TEST`) and `hello.nes` |

## Build

`build.bat` (cc65 on `PATH`, or `set CC65=<cc65 bin folder>`) ->
`build/OS.BIN` and the test ROM `build/hello.nes`.

Testing in the simulator: see `../docs/testing.md`.
