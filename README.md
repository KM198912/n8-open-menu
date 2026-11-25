# n8-open

Open firmware for the EverDrive N8 clone cartridge (NES, 72-pin): menu,
loader and FPGA mapper cores, written from scratch.

The cartridge: Altera Cyclone II EP2C5 (mapper cores), MAX II CPLD (bus
glue, SD card, FPGA configuration), 512 KB PRG and CHR SRAM, 256 KB
battery-backed save SRAM, the BIOS in flash. n8-open replaces what lives on
the SD card - `/EDFC/OS.BIN`, `/EDFC/MAPROUT.BIN` and `/EDFC/MAPS/*.RBF`;
the cartridge's own BIOS stays as it is and starts it.

## Status

| | |
|---|---|
| Menu | browse (FAT32, long names, sorted), ROM info, game start, battery saves to SD |
| Menu core | `255.RBF` |
| NROM (0) | `100.RBF` |
| MMC1 (1) | `101.RBF` |
| UxROM (2) | `102.RBF` |
| MMC3 (4) | `104.RBF` |
| MMC5 (5) | `105.RBF` - banking, ExRAM, fill mode, scanline IRQ, extended attributes; no split screen, no audio yet |

Planned: VRC6, CNROM/AxROM/GxROM, MMC5 split and audio, FDS. Open items
and test results: `BACKLOG.md`.

## Layout

| Path | |
|---|---|
| `menu/` | the menu, 6502 assembly (cc65) - see `menu/README.md` |
| `cores/nrom/` | all game cores (one Quartus revision per mapper) - see `cores/nrom/README.md` |
| `cores/nrom_noret/` | the menu core `255.RBF` |
| `cores/tb/` | Icarus Verilog testbenches |
| `cores/cores.txt` | mapper -> core table, turned into `MAPROUT.BIN` |
| `tools/` | simulator, SD image and FAT tools, `MAPROUT.BIN` and RBF helpers |
| `docs/` | hardware interface and pinout as found, testing |

## Building

- Cores: Quartus II 13.0 SP1 Web Edition (the last version with Cyclone II).
  Open `cores/nrom/n8_nrom.qpf`, pick the revision, compile, then
  `python tools/pad_rbf.py cores/nrom/output_files/<revision>.rbf <NNN> <card>/EDFC/MAPS`.
- Menu: cc65, `menu/build.bat` -> `menu/build/OS.BIN`.
- `MAPROUT.BIN`: `python tools/mk_maprout.py cores/cores.txt <card>/EDFC/MAPROUT.BIN`.
- Tests: Icarus Verilog 12 and Python 3, see `docs/testing.md`.

## How it is written

The cores and the menu are written from public documentation (NESdev wiki)
and from measurements and analysis of the hardware; no code from the
original firmware or from other cores is used. Where the documentation
leaves a detail open, the source says what was inferred and how it was
confirmed.

No game ROMs, BIOS images or firmware dumps are part of this repository.

## License

n8-open is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option)
any later version. See `LICENSE`.

Whoever distributes built cores (`.RBF`) or menus (`OS.BIN`) must offer the
corresponding sources under the same terms.
