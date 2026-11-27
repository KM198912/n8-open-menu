# test/ - local only

Everything in this folder except this file is ignored by git: it holds game
data and firmware that must not be published, plus generated files.

| Path | What | Source |
|---|---|---|
| `m2card/` | staging copy of the SD card: `EDFC/OS.BIN`, `EDFC/MAPROUT.BIN`, `EDFC/MAPS/*.RBF`, test ROMs | built here; ROMs from your own carts |
| `sdroot/`, `sdroot_many/` | folders the simulator's SD images are built from | as above |
| `*.img` | FAT32 images for the simulator | `python tools/mk_sdimg.py <folder> <out.img>` |
| `dump/` | dumps from the original cartridge (BIOS, MAPROUT, cores, saves) - research only | your own hardware; never commit |
| `ab/` | A/B test set for foreign cores, see `docs/testing.md` | generated |
| `release/` | release folder, zip and mapper chart (`n8-open-<version>-mappers.png`) | `test/mk_release.py` (local), chart: `python tools/mk_mapchart.py` |

Building a card folder from scratch:

```
menu\build.bat                                   -> menu/build/OS.BIN
python tools/mk_maprout.py cores/cores.txt test/m2card/EDFC/MAPROUT.BIN
python tools/pad_rbf.py cores/nrom/output_files/<revision>.rbf <NNN> test/m2card/EDFC/MAPS
```
