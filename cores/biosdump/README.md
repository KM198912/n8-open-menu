# BIOS dump helper

Purpose: read the clone's BIOS flash (bootloader with the SD/FAT driver and
RBF loader) so its interface can be documented. Read-only, no soldering.

## Parts

- **Core** `n8_dump.qpf`: the NROM core sources from `../nrom/` built with
  `DUMP_HELPER=1`:
  - CPLD registers stay unlocked in game mode (bus mode `11`).
  - A write to `$5000` (bit 0 = 1) releases the PRG RAM at `$8000-$FFFF`, so
    the CPLD can show the flash there without a bus fight.
- **ROMs** `test/dump/biosdump0.nes` .. `biosdump3.nes` (`tools/mk_biosdump.py`):
  mapper 0, battery save. Each copies one 8 KB chunk of the flash window into
  the save RAM:
  | ROM | flash window |
  |---|---|
  | biosdump0 | `$8000-$9FFF` |
  | biosdump1 | `$A000-$BFFF` |
  | biosdump2 | `$C000-$DFFF` |
  | biosdump3 | `$E000-$FFFF` (reset vectors, most likely the bootloader) |

The ROMs never send a flash command; the only flash-related write is the
`$09` mode switch, which Krikzz's menu also uses for its read-only CFI query.

## Build

1. Open `n8_dump.qpf` in Quartus II 13.0 SP1, Start Compilation.
2. `python ..\..\tools\pad_rbf.py output_files\n8_dump.rbf 101` -> `101.RBF`

## Run (test SD card)

1. Copy `101.RBF` to `/EDFC/MAPS/`.
2. Copy `test/dump/MAPROUT.BIN` to `/EDFC/` (only change: mapper 0 -> 101).
3. Copy the four `biosdumpN.nes` to the card.
4. Start `biosdump3.nes` first. Backdrop colour:
   - green: data copied, looks like real content
   - yellow: all 8 KB identical, flash probably not visible
   - blue that stays blue: hung while the flash was switched in; power cycle
5. On green: press reset. The menu should store the save RAM on the SD card
   like any battery save. Copy that save file to the PC.
6. Repeat for chunks 0-2.

Afterwards restore the normal `MAPROUT.BIN` (mapper 0 -> 100 for the NROM
core, or 00 for the original).
