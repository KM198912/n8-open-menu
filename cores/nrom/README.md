# Game cores for the EverDrive N8 clone (one core per mapper)

All game cores are built from the same sources in this folder. Each Quartus
revision sets the `MAPPER` parameter and becomes its own RBF:

| iNES mapper | Revision  | Module       | Card file              |
|-------------|-----------|--------------|------------------------|
| 0 NROM      | `n8_nrom` | `map_nrom.v` | `/EDFC/MAPS/100.RBF`   |
| 1 MMC1      | `n8_mmc1` | `map_mmc1.v` | `/EDFC/MAPS/101.RBF`   |
| 2 UxROM     | `n8_uxrom`| `map_simple.v` | `/EDFC/MAPS/102.RBF` |
| 3 CNROM     | `n8_cnrom`| `map_simple.v` | `/EDFC/MAPS/103.RBF` |
| 7 AxROM     | `n8_axrom`| `map_simple.v` | `/EDFC/MAPS/107.RBF` |
| 24 VRC6a    | `n8_vrc6a`| `map_vrc6.v` | `/EDFC/MAPS/124.RBF` |
| 26 VRC6b    | `n8_vrc6b`| `map_vrc6.v` | `/EDFC/MAPS/126.RBF` |
| 66 GxROM    | `n8_gxrom`| `map_simple.v` | `/EDFC/MAPS/166.RBF` |
| 4 MMC3      | `n8_mmc3` | `map_mmc3.v` | `/EDFC/MAPS/104.RBF`   |
| 5 MMC5      | `n8_mmc5` | `map_mmc5.v` | `/EDFC/MAPS/105.RBF`   |
| FDS (`$FE`) | `n8_fds`  | `map_fds.v`  | `/EDFC/MAPS/120.RBF`   |

Numbering: RBF number = 100 + mapper (above 155: pick a free number).
FDS has no iNES mapper; it is `MAPPER 20` (the number old iNES documents
used for the disk system) and `MAPROUT.BIN` entry `$FE`, as the original
menu does.
`cores/cores.txt` is the table `tools/mk_maprout.py` turns into
`/EDFC/MAPROUT.BIN`. The menu core `255.RBF` is built from
`cores/nrom_noret` (same sources, `RET_MENU 0`, `MAPPER` default 0).

Sources:
- `osmap.v`: menu mode (mapper index `$FF`), registers `$80`-`$88`, M2
  watchdog, `$5000` signature window. Game Genie (`$87`) is not implemented.
- `map_*.v`: one module per mapper, same port list as `map_nrom.v`
  (MMC1/MMC3 also take `mclk`, `rst`, `cpu_dat` for their registers; MMC5
  also `clk`, `ppu_rd`, `ppu_dat` and answers reads via `cpu_do/cpu_oe`,
  `ppu_do/ppu_oe`, which `top.v` gates). FDS (`map_fds.v`) answers its
  registers and a code stub the same way, and is the only core that may
  write PRG SRAM in game mode (`prg_wok`: its RAM and disk image live
  there). How the disk reaches the CPU despite the SRAM taking A0-A9 from
  the console bus: see the comment at the top of `map_fds.v`.
- `aud_dac.v`: expansion audio DAC on `cpu_exp` (gain `$89`, sigma-delta),
  shared by VRC6 and FDS; `fds_snd.v`: the FDS sound unit.
- `top.v`: board glue; a `generate` block instantiates only the mapper of
  this build. The core never drives the CPU data bus.
- `n8_nrom.sdc`: timing constraints, shared by all revisions.

Written from `docs/hw-interface.md`, `docs/pinout.md` and the public mapper
documentation; no Krikzz code.

## Build

1. Open `n8_nrom.qpf` in Quartus II 13.0 SP1 (last version with Cyclone II).
2. Pick the revision in the toolbar drop-down (or Project > Revisions).
3. Processing > Start Compilation -> `output_files/<revision>.rbf`.
4. Check: Timing Analyzer summary all slacks positive, no critical warnings.
5. Pad and copy (from the repository root):
   ```
   python tools/pad_rbf.py cores/nrom/output_files/n8_mmc1.rbf 101 test/m2card/EDFC/MAPS
   ```

## Adding a mapper

1. `map_<name>.v` with the same outputs as `map_nrom.v`.
2. `top.v`: parameter comment + a `generate` branch `if (MAPPER == N)`.
3. A revision: copy `n8_mmc1.qsf` to `n8_<name>.qsf`, set
   `set_parameter -name MAPPER N`, add the `.v` file to all `.qsf` files
   (also `cores/nrom_noret` and `cores/biosdump`), add the revision to
   `n8_nrom.qpf`.
4. `cores/cores.txt`: `N  100+N`, then rebuild `MAPROUT.BIN`.
5. Testbench in `cores/tb` (instance `n8_top #(.MAPPER(N))`), add it to
   `run.sh`, run it before the first Quartus build:
   `MSYS_NO_PATHCONV=1 wsl -e sh /mnt/h/osdev/n8-open/cores/tb/run.sh`

## Test

| Result | Meaning |
|---|---|
| Game runs normally | menu mode, mapping and mirroring are right |
| Title screen garbled, but music plays | CHR side (`chr_map`, mirroring) |
| Black screen / hang right after choosing the game | menu-mode part (`osmap.v`) or loading |
| Brown/pink screen in the menu after choosing | core did not load (`$5000` probe failed) |

Reset button = restart the game; power cycle = back to the menu.
