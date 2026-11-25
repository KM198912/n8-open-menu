# n8-open backlog

## Open

- **Reset button = restart the game** (accepted as the initial behaviour,
  2026-11-25; power cycle = back to the menu). With the CRC-fixed loader and a
  core with `RET_MENU 1`, reset restarts the game cleanly, also when held for
  2-3 s. Before (cores without the latch) reset crashed with the game's
  backdrop colour. Open, low priority:
  - why the core never returns to menu mode (does M2 keep running during a
    reset on this console, so the M2 watchdog never fires?), and why the latch
    turned the crash into a clean restart;
  - a "back to menu" gesture for later (e.g. a button combo the core watches),
    since the long reset press does not work here.
- **Reset black screen in the combined NROM+MMC1 core** (2026-11-25, not
  chased): with both mappers in one `100.RBF` (selected at runtime by
  `map_idx` through a multiplexer), reset during Zelda gave a black screen
  without music; SMB reset fine. The split `101.RBF` resets Zelda cleanly.
  Zelda's reset code (`$FF50`) re-initialises all MMC1 registers before use,
  so the game and the MMC1 logic are ruled out; the cause was in the
  combined build's path. If a later core shows the same symptom, start
  here.
- **Core start-up clocks**: the CPLD only clocks the FPGA while bytes are
  streamed. `tools/pad_rbf.py` now pads >= 256 bytes 0xFF; the loader could
  also send extra 0xFF to `$4403` after the stream so it does not depend on
  the file.
- `hello.nes`: some letters red although the attribute table is now cleared
  (check whether the fixed ROM was on the card).
- Not implemented yet: Game Genie, save states, trainers, more
  mappers (next: VRC6).
- MMC5 phase 3-4: vertical split (Uchuu Keibitai SDF, Bandit Kings ending),
  audio on `cpu_exp`, saves > 8 KB (Koei: 32 KB). Open detail: the
  background prefetch of line 0 happens before "in frame" is set, so its two
  tiles get neither the 8x16 set B nor extended attributes (not seen yet).
- **VRC6 audio** (phase 2): banking + IRQ are done, see below.
  Audio level: per-chip default calibrated to the 2A03 ratio + a per-chip
  gain in the menu (Krikzz's "audio balance" is per chip, 0-200%; VRC6 needs
  ~160-200% there on stock/AV-modded Famicoms, r/everdrive 15c8w2v).
  The user's setup plays expansion audio (heard with VRC6 on the old firmware).
- **FDS** (own project): RAM adapter ($4020-$4033, timer IRQ, disk byte
  stream with the BIOS's timing), `.fds` sides in SRAM, writes back to SD,
  auto side swap (watch which side the BIOS asks for), FDS audio. BIOS from
  the user's own RAM adapter (`/EDFC/DISKSYS.ROM`), never shipped.
- Battery saves, open points: save sizes other than 8 KB (NES 2.0 header
  byte 10; SxROM 16/32 KB, MMC5) are not supported; names over 47 characters
  are cut (list keeps 51); deleted directory slots are not reused; the FAT
  writing was checked on hardware with the SC64 (FatFs) and the .sav
  contents, not yet with chkdsk/fatcheck on a raw image of the card.
- MMC3 gaps: four-screen boards (extra VRAM: Gauntlet, Rad Racer 2) and
  MMC6 (StarTropics, mapper 4 with different PRG RAM) are not supported.

## Done

- **NTSC games on PAL consoles** (2026-11-25): menu `src/region.s`
  measures the console (15-cycle loop between vblank flags: NTSC ~1985,
  PAL ~2217, Dendy ~2364 passes) and the game's region (NES 2.0 byte 12,
  iNES byte 9 with a clean header, file name); NTSC game on PAL -> `$86`
  bit 6 and the patch list (first entry: Castlevania (USA) `$F8CA` BEQ ->
  NOP NOP, checked against 12 original bytes). VRC6 core: PAL prescaler
  (1705 - 16 per cycle) + vblank hold (capped at 5400 cycles). B held with
  A = off. Hardware: Akumajou Densetsu and Castlevania (USA) keep their
  status bars on the PAL console; with B held both break again. Simulator
  `--region ntsc|pal|dendy`, `--prg-dump`. Further cycle-IRQ cores
  (VRC4/7, FME-7, Namco 163) should honour bit 6 the same way.
- **VRC6 phase 1** (2026-11-25): `cores/nrom/map_vrc6.v`, revisions
  `n8_vrc6a` / `n8_vrc6b` -> `124` / `126.RBF`; `$B003` mode 0 only (all
  three Konami games); `tb_vrc6.v` 53 checks incl. an NTSC/PAL PPU model,
  mutations caught. Hardware: Akumajou Densetsu.
- **Error line shows the mapper in decimal** (was hex: `$18` read as 18).

- **CNROM, AxROM, GxROM** (2026-11-25): `map_simple.v` branches, revisions
  `n8_cnrom` / `n8_axrom` / `n8_gxrom` -> `103` / `107` / `166.RBF`;
  `tb_simple.v` 17 / 20 / 19 checks, 7 mutations caught. Hardware:
  Solomon's Key, Battletoads, Super Mario Bros. / Duck Hunt.

- **UxROM** (2026-11-25): `cores/nrom/map_simple.v` (MAPPER 2), revision
  `n8_uxrom` -> `102.RBF`; `tb_simple.v` 30 checks, 5 mutations caught.
  Hardware: Castlevania (USA) fully playable. Its status bar scrolls with
  the level on this console - identical with the original firmware (own
  menu + 002.RBF), fine in FCEUX (NTSC): the NTSC game's sprite-0 wait loop
  times out inside the longer PAL vblank. Confirmed: Castlevania (Europe)
  keeps the status bar in place on the same setup. The console is PAL.
  Not a core fault.
- **Clean RAM at game start** (2026-11-25): the RAM loader clears zero
  page and pages 1, 2, 7 before the jump (pages 3-6 hold its code). Found
  while chasing the Castlevania status bar (page 7 was full of menu data;
  not the cause there, but games now start as from power-on).
- Test aids: `test/ab/` (A/B MAPROUT for foreign cores 200+), diagnostic
  `OS.BIN` build `-D AB_TEST` (no signature check for cores 200+),
  simulator `--no-signature` and RAM report at game start.

- **MMC5 phase 2: extended attributes** (2026-11-25): ExRAM byte latched
  in the middle of each background nametable read; the MMC5 answers the
  attribute read with the palette x4 (inferred - not documented; confirmed
  on hardware); pattern reads use $5130 + ExRAM 5:0 as a 4 KB page.
  `tb_mmc5` 107 checks, 7/8 mutations caught (the 8th is equivalent in the
  model). Hardware: Just Breed (kanji text, town, interiors = FCEUX),
  Nobunaga's Ambition II (map, crests, borders, portraits), Castlevania III
  unchanged. 708 LEs.

- **Sorted file list** (2026-11-25): folders first, then names ignoring
  case; insertion sort on a 128-byte index (`order` in BSS2, `list_sort` in
  `menu/src/main.s`), records stay in place. Full folder (128) ~0.57 s.
  Simulator: `mk_sdimg.py --shuffle` (it used to sort names itself).

- **MMC5 phase 1** (2026-11-25): `cores/nrom/map_mmc5.v`, revision
  `n8_mmc5` -> `105.RBF`. PRG modes 0-3 + 64 KB PRG RAM (save SRAM pages
  0-7), CHR modes + `$5130` + sets A/B (8x16), nametables incl. fill and
  ExRAM, scanline detection from PPU reads, IRQ, multiplier. First core that
  drives the data buses (gated in `top.v`: CPU bus only while M2 is high,
  SRAM `/OE` off; PPU bus only on claimed reads). `tb_mmc5.v` 89 checks with
  bus monitors, 11 mutations caught. 685 LEs, timing met. Hardware:
  Castlevania III title, intro, blocks 1-01..1-03, status bar steady,
  identical to FCEUX. Save record moved to SRAM page 9.

- **Battery saves to SD** (2026-11-25): raw 8 KB `/EDFC/SAVE/<rom>.sav`
  (emulator format). Game start loads or creates it (`menu/src/save.s`),
  the game plays in save SRAM page 0, the next power-on writes it back
  ("SAVING...", record in page 4, checks volume ID + entry; A retry /
  Select discard on errors). New: `sd_write` (CMD24), FAT32 writing
  (`menu/src/fatw.s`: allocation in all FATs + FSInfo, LFN entries, files,
  directories), `tools/fatcheck.py`, simulator `--sram`/`--sd-reject-writes`,
  test builds `menu/tests/sdw_test.s` and `fatw_test.s`. Hardware: Zelda
  save -> power cycle -> loaded back (name + sword); the .sav read via the
  SC64 is byte-exact (LINK, `5A`/`A5` markers).
- **Loading screen without flashing** (2026-11-25): "LOADING..." stays up
  during PRG, then one switch to black; no progress colours (photosensitivity).

- **MMC3 core** (2026-11-25): `cores/nrom/map_mmc3.v`, revision
  `n8_mmc3` -> `104.RBF`; testbench `cores/tb/tb_mmc3.v` with a PPU fetch
  model (55 checks, mutations caught). A12 filter = 4 falling M2 edges
  (3 counts the 8-9-dot line-end dip with BG at `$1000`). Hardware OK:
  SMB3 (IRQ status bar steady), Darkwing Duck (256 KB PRG + CHR).

- **One core per mapper** (2026-11-25): `top.v` parameter `MAPPER`, one
  Quartus revision per mapper in `cores/nrom/n8_nrom.qpf`, RBF number =
  100 + mapper (`100.RBF` NROM, `101.RBF` MMC1). See `cores/nrom/README.md`.
- **MMC1** (2026-11-25): `cores/nrom/map_mmc1.v`, Icarus testbench
  `cores/tb/tb_mmc1.v` (41 checks); Zelda (Europe) runs on hardware
  (overworld, cave, file select / PRG RAM).
- **Own menu core `255.RBF`** works (constrained build from
  `cores/nrom_noret`).

- **Flaky core loading: root cause found** (2026-11-25). The RAM loader read
  only the first CRC byte after each SD block; a second CRC byte of `$FE` was
  taken for the next data token and shifted the core. ~1/256 per sector, so
  some builds always failed, others always worked. Fixed (extra dummy read,
  as the BIOS at `$FF65`); the simulator now sends real CRC16.
- Timing constraints `cores/nrom/n8_nrom.sdc` (all met: clk +13 ns, M2 +40 ns,
  bus paths <= 12.1 ns of 25 ns).

- Milestone 1: own menu boots, SD init, FAT32, root listing (hardware OK).
- Milestone 2: browse + load + core from SD + game start (hardware OK with
  a core without `ret_menu`: hello.nes and Super Mario Bros.).
