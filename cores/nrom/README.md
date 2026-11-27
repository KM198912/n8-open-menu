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
| 9 MMC2      | `n8_mmc2` | `map_mmc2.v` | `/EDFC/MAPS/109.RBF`   |
| 10 MMC4     | `n8_mmc4` | `map_mmc2.v` | `/EDFC/MAPS/110.RBF`   |
| 21 VRC4a/c  | `n8_vrc21`| `map_vrc4.v` | `/EDFC/MAPS/121.RBF` |
| 22 VRC2a    | `n8_vrc22`| `map_vrc4.v` | `/EDFC/MAPS/122.RBF` |
| 23 VRC2b/4e | `n8_vrc23`| `map_vrc4.v` | `/EDFC/MAPS/123.RBF` |
| 24 VRC6a    | `n8_vrc6a`| `map_vrc6.v` | `/EDFC/MAPS/124.RBF` |
| 25 VRC2c/4b/4d | `n8_vrc25`| `map_vrc4.v` | `/EDFC/MAPS/125.RBF` |
| 26 VRC6b    | `n8_vrc6b`| `map_vrc6.v` | `/EDFC/MAPS/126.RBF` |
| 66 GxROM    | `n8_gxrom`| `map_simple.v` | `/EDFC/MAPS/166.RBF` |
| 69 FME-7    | `n8_fme7` | `map_fme7.v` | `/EDFC/MAPS/169.RBF`   |
| 71 Camerica | `n8_camerica` | `map_simple.v` | `/EDFC/MAPS/171.RBF` |
| 11 Color Dreams | `n8_cdream` | `map_simple.v` | `/EDFC/MAPS/111.RBF` |
| 34 BNROM / NINA-001 | `n8_m34` | `map_simple.v` | `/EDFC/MAPS/134.RBF` |
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
- `vrc_irq.v`: the Konami VRC IRQ (prescaler, cycle mode, NTSC-on-PAL
  correction), shared by VRC4 and VRC6.
- `aud_dac.v`: expansion audio DAC on `cpu_exp` (gain `$89`, sigma-delta),
  shared by VRC6, FDS and MMC5; `fds_snd.v`: the FDS sound unit;
  `mmc5_snd.v`: the MMC5's two pulses and PCM channel.
- `top.v`: board glue; a `generate` block instantiates only the mapper of
  this build. The core never drives the CPU data bus.
- `n8_nrom.sdc`: timing constraints, shared by all revisions.

Written from `docs/hw-interface.md`, `docs/pinout.md` and the public mapper
documentation; no Krikzz code.

## Build

All cores at once (from the repository root; runs Quartus from the command
line, one revision after another, logs in `test/build_logs/`, padded RBFs
and `MAPROUT.BIN` into `test/m2card/EDFC/`):
```
python tools/build_cores.py                  # everything in cores/cores.txt + 255.RBF
python tools/build_cores.py --only n8_mmc2   # single revisions
```
One revision by hand:

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
6. `docs/mappers.md`: the mapper's status, then `python tools/mk_assets.py`
   (README chart `assets/mappers.svg`) and commit the SVG with it.

## Test

| Result | Meaning |
|---|---|
| Game runs normally | menu mode, mapping and mirroring are right |
| Title screen garbled, but music plays | CHR side (`chr_map`, mirroring) |
| Black screen / hang right after choosing the game | menu-mode part (`osmap.v`) or loading |
| Brown/pink screen in the menu after choosing | core did not load (`$5000` probe failed) |

Reset button = restart the game; power cycle = back to the menu.
