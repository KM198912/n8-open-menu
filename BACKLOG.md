# n8-open backlog

## Open

- **Menu: last game / quick start** (like Krikzz's menu; decided 2026-11-26,
  after FDS). Phase 1, the popup, done in simulation 2026-11-27: Select on
  a file opens a box (`FILE MENU`: `SELECT + LOAD` / `SELECT ONLY` /
  `ROM INFO`, Krikzz's order; Up/Down, A confirms, B closes - our buttons,
  not Krikzz's B-select/A-back). Grey box from a second font set made at
  start-up (plane 1 set), BG palettes 1/2 (highlight yellow), drawn and
  removed with rendering on. Hardware: works (2026-11-27). Phase 2 done in
  simulation 2026-11-27 (`menu/src/lastgame.s`): `SELECT ONLY` / `SELECT +
  LOAD` store the record in the last directory-list slot of save SRAM page
  8 (`$7FC0`; `MAX_ENTRIES` 128 -> 127): `"N8LG"`, volume ID, folder
  cluster, file cluster + size, first 23 characters of the long name. Page 8
  checked against the BIOS dump: only pages 9-15 are written at power-on
  (`$F080`); the one page-8 select (`$C13E`) is followed by PPU writes
  only; the full SRAM test at `$C27F` is not part of the normal boot (saves
  in pages 0/7 survive). Row 27 shows `START: <name>`; Start (no longer
  "open" like A) pushes the current folder, opens the stored one, finds the
  entry by cluster + size, puts the cursor on it and starts it through the
  normal path; not there: error `$4C` LAST GAME NOT FOUND, B leads back.
  Simulator: store -> power cycle (`--sram`) -> `START:` line -> Start from
  another folder starts `hello.nes` (PRG checked); `SELECT + LOAD`; file
  not in the folder -> `4C`; B after an error -> previous folder; a
  folder with 150 files fills slot 127 and leaves the record intact; no
  dark frames. Not covered by the simulator: a card with another volume
  ID (both test images share `12345678`). Hardware test open.
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
  mappers.
- MMC5 phase 3-4: vertical split (Uchuu Keibitai SDF, Bandit Kings ending),
  audio on `cpu_exp`, saves > 8 KB (Koei: 32 KB). Open detail: the
  background prefetch of line 0 happens before "in frame" is set, so its two
  tiles get neither the 8x16 set B nor extended attributes (not seen yet).
- **Expansion audio level**: `AUD_GAIN_DEFAULT` (128 = 1.0) is not
  calibrated yet. Needs a recording of `menu/tests/vrc6_tone.nes` on an
  original N8 (VRC6 vs 2A03 pulse per pitch), then a per-chip default + a
  per-chip gain in the menu (Krikzz's "audio balance" is per chip, 0-200%;
  VRC6 needs ~160-200% there on stock/AV-modded Famicoms, r/everdrive 15c8w2v).
  FDS sounds right by ear at gain 1.0 (Zelda II, 2026-11-27); a measured
  per-chip calibration is only still open for VRC6.
- **FDS** (phase 1 = core done in simulation, see Done; BIOS = the user's
  own dump `/EDFC/DISKSYS.ROM`, CRC32 `5E607DCF`, never shipped; the
  original firmware carries Nintendo's BIOS inside `254.RBF`/`OS.BIN`):
  - phase 2, menu: done in simulation (see Done); first hardware test:
    Zelda II. If it misbehaves, suspect CPLD `$09` bit 2 first (set as
    the clone menu does for FDS, meaning unknown). Side swap: manual and
    automatic, see Done.
  - phase 3, saves: done, Zelda II's save survives power cycles on hardware.
    Only side A is kept: games that save to another side lose that save at
    power-off. Possible later: keep the side the game last wrote to (copy
    it into the save SRAM on the swap), or let the user pick the side.
  - phase 4, auto swap: done, hardware 2026-11-27 (see Done). Open: SMB
    retest on the auto-swap build (ran fine on the build before). Known
    limit: a game that polls `$4032` from its own code during normal play
    gets one eject (short "insert disk" or a reset to the title) - watch
    for it with every new game.
  - not supported: programs reading `$4031` themselves instead of through
    the BIOS (own loaders, some copy protections) get `$00`.
- ROM info screen: long file names break at column 31 mid-word
  ("Super Mario Bros. (Japan).fd" / "s", seen 2026-11-27). Break at a space
  (or before the extension), or cut with an ellipsis. `menu/src/rominfo.s`.
- Battery saves, open points: save sizes other than 8 KB (NES 2.0 header
  byte 10; SxROM 16/32 KB, MMC5) are not supported; names over 47 characters
  are cut (list keeps 51); deleted directory slots are not reused; the FAT
  writing was checked on hardware with the SC64 (FatFs) and the .sav
  contents, not yet with chkdsk/fatcheck on a raw image of the card.
- MMC3 gaps: four-screen boards (extra VRAM: Gauntlet, Rad Racer 2) and
  MMC6 (StarTropics, mapper 4 with different PRG RAM) are not supported.

## Done

- **Menu: `/EDFC` hidden** (2026-11-27, simulation): `dir_load` skips the
  root's folder with the 8.3 name `EDFC`; everything inside it is found by
  name (`find_edfc`), so cores, `DISKSYS.ROM`, saves and the info screen's
  core check are unaffected. Simulator: root list without it, `hello.nes`
  starts, ROM INFO "SUPPORTED: YES", Zelda II (FDS) starts, a nested
  `NES/EDFC/` stays visible, last game + Start still work.

- **FDS phase 4: automatic side swap** (2026-11-27; hardware: Zelda II -
  "CHANGE SIDE B" goes on by itself, the save survives power-off; Dracula
  II, 2 sides, password game - side changes by itself in game).
  Found in the simulator first (real BIOS, Zelda II driven through name
  entry and player select): the game shows "CHANGE SIDE B" without a BIOS
  call, its own code (`$844F`) polls `$4032` once per frame for "no disk",
  then (`$8456`) for "inserted", and only then loads through the BIOS. So
  two parts in `map_fds.v`: (1) eject after 60 `$4032` reads by game code
  (the operand fetch before the read is outside `$E000-$FFFF`), each
  within 100000 cycles of the last, then the next side; armed only by a
  BIOS disk check since the last auto eject. (2) A 4th BIOS patch, `$E445`
  JSR `$E6E3` -> JSR `$5720`: a core stub copies the game's wanted ID
  (10 bytes, `$FF` = any) to `$5710-$5719` before the drive starts; the
  core compares it with every loaded side's block 1 `$0F-$18` (menu ->
  `$96/$97`, staged at PRG `$0A800`) and inserts the matching side at once
  if the inserted one does not match (4 sides / 2 disks). `tb_fds` 131
  checks (32 new), 16 mutations; menu run in `n8sim` (IDs sent = the
  sides' block 1 bytes, 4 patches); Zelda II in the `fds_boot` model:
  "CHANGE SIDE B" ~frame 2205, eject 2268, side B 2333, in game ~2860,
  no button pressed. Select + Down stays as the manual fallback.

- **FDS phase 5: audio** (2026-11-26; hardware 2026-11-27: BIOS logo chime
  and Zelda II's FDS layer audible, level right by ear, recording clean:
  peak -14 dBFS, notes in tune, no aliasing):
  `cores/nrom/fds_snd.v`
  - wave RAM, wave unit, modulation (the wiki's pitch formula), both
  envelopes, master volume, 1-pole low-pass ~2.4 kHz; out through the new
  shared `aud_dac.v` (VRC6 moved to it, `tb_vrc6` unchanged 77/77). Bit
  meanings where the wiki contradicts itself: Disch's FDS.txt. Reference
  model `tools/n8sim/fds_audio.py`; `tb_fds_snd` replays 220,295 bus cycles
  on the core and the model - identical in every cycle (pre-filter level,
  filtered level, register reads); 16 mutations all caught. Open: `$4083`
  bit 7 "envelopes 4x faster" (wiki diagram only).
- **Save records lost at power-off - battery saves too** (2026-11-26):
  the BIOS loads OS.BIN into save SRAM pages 9-15 at every power-on (dump,
  `$F080`), and the save record had lived in page 9 since the MMC5 work.
  Both records (battery `"N8SV"`, FDS `"N8FD"`, the latter now with the
  8.3 name) moved to `$0FFDC-$0FFFF`, the 36 bytes behind FDS side A. The
  simulator now boots like the BIOS (OS.BIN into pages 9-15) and first
  reproduced the loss; then both round trips pass: FDS (the `.fds` changes
  by exactly the marker) and battery (`.sav` written, record cleared).
  Hardware (2026-11-26): Zelda II's save survives a power cycle,
  "SAVING..." shown. A battery `.nes` across a power cycle: not yet
  re-tested on hardware since the move.
- **FDS phase 3: saves to SD** (2026-11-26, simulation only): disk side A
  lives in the battery-backed save SRAM at `$00000-$0FFFF`, sides B-D in PRG
  SRAM. Only one side: the chip is 256 KB (LP62S2048) but only 128 KB are
  reachable (hardware test: `$20000` lands on `$00000`, A17 not driven by
  the FPGA; see `docs/hw-interface.md`). FDS save record `"N8FD"` in
  page 9; at the next menu start ("SAVING...") every sector of side A
  is compared with the save SRAM and only changed ones are written
  back into the `.fds` (in place; volume ID, long name, cluster and size
  checked first; header never touched). Simulator round trip: menu ->
  Zelda II -> the game's save routine with a marker in its RAM -> power-on
  run -> the `.fds` on the image differs in exactly the 17 marker bytes,
  FAT clean (also with the simulator's `--sram-kb 128` board model). Also fixed: FDS error codes `$4A`/`$4B` clashed with the
  battery-save ones -> now `$50-$54`; `$48`/`$4A`/`$4B` got texts.
- **FDS: manual side swap** (2026-11-26, simulation only): the core reads
  pad 1 along with the game (first 8 `$4016` reads after a strobe);
  Select + Down held ~0.9 s ejects the disk for ~1 s, then the next side
  goes in (wraps to A; side count from the menu via `$95`). Once per press.
  `tb_fds` 87 checks + 5 mutations; with the real BIOS: a game-style change
  loop (BIOS pad read + `$4032`) sees the swap and `LoadFiles` loads
  Zelda II's GROUND-0 from side B byte-exact. Hardware (2026-11-26, PAL
  console): Zelda II - menu -> BIOS -> side A, player created and saved
  ("WAIT"), "CHANGE SIDE B" -> Select + Down -> side B loads, the game
  starts in the palace with the status bar in place (timer PAL fix). First
  attempt gave ERR.07: the card still had the menu without the side count
  (`$95`), so the core swapped A -> A.
- **FDS: Zelda II's save failed with ERR.24** (2026-11-26, found on
  hardware, reproduced in the simulator by calling the game's save routine
  `$8520`). Two core bugs in the write path: (1) the byte the BIOS writes
  after the last data byte of a block (`$E729`, replaced by the CRC on a real
  drive) was stored as data - block 2 grew to 3 bytes and the blocks after
  it were dropped; now a third BIOS patch (`$E729 -> JSR $5708`) marks it
  and the core skips it. (2) the transfer flag from write mode survived the
  switch to read mode and fired the next read's IRQ at once; `$4025` with
  bit 6 clear now clears it (the flag only exists while its condition
  holds). Simulator: `WriteFile` returns 0 including the BIOS's read-back.
  `tb_fds` with a 200-byte lead-in (15 s per run instead of ~1 min).
- **No flicker when moving the cursor** (2026-11-26): every Up/Down used to
  redraw the whole list with rendering off (one black frame per step). Now
  only the `>` moves (in vblank); when the page scrolls, the rows are
  redrawn with the picture on, 2 per vblank (NTSC/Dendy) or 6 (PAL).
  Simulator: `--dark-after` counts frames with rendering off (0 while
  navigating), and PPUDATA writes are only flagged outside vblank.
- **FDS phase 2: menu** (2026-11-26, simulation only): `menu/src/fds.s`.
  `.fds` detection (fwNES header or raw `*NINTENDO-HVC*`), up to 4 sides;
  `/EDFC/DISKSYS.ROM` -> PRG `$08000`, checked and patched; sides ->
  `$10000 + n x $10000`; block tables staged at `$0A000`, sent by the RAM
  code once the core is up (`$91-$93`, then `$94` = side A); `$84 = $1F`,
  CHR RAM, `$86` bit 6 on PAL, CPLD `$09 = $15`. Errors `$4A`-`$4D`; the
  no-core line says `FDS`. Simulator end to end (`run.py` hands over to
  the FDS model at `$83 = $FE`): RBF stream = file, tables = reference,
  BIOS boots Zelda II from the menu-filled PRG SRAM; `hello.nes` still
  starts; missing / altered BIOS -> `4A` / `4B`.
- **FDS phase 1: core** (2026-11-26, simulation only, not built yet):
  `cores/nrom/map_fds.v`, revision `n8_fds` -> `120.RBF` (`MAPROUT` `$FE`).
  The SRAMs take A0-A9 from the console bus, so the core cannot fetch disk
  bytes itself: the patched BIOS reads/writes them through 1 KB windows
  (`$5800`/`$5C00`) via an 8-byte stub the core serves at `$5700`. Disk
  in `.fds` form + block table (no gaps/CRCs in SRAM); timing 149 1/3
  cycles per byte, lead-in 3537 / gaps 122 byte times; overrun -> CRC
  error bit (ERR.27, never silent corruption); timer IRQ with the PAL
  correction (Zelda II's split: NTSC line 31, PAL without fix 296, with
  fix 30). `tb_fds.v` (+ mutations), `tools/n8sim/fds_boot.py`: the
  user's BIOS boots Zelda II (license screen, side A, game code). Found by
  the boot run, not the testbench: the BIOS's ~27-cycle reset pulse must
  restart the head at once.
- **VRC6 audio** (2026-11-26): `map_vrc6.v` two pulses (duty, M bit,
  E = 0 resets the step) + sawtooth, `$9003` halt and >> 4 / >> 8; mix
  0..61 x gain (`$89`, menu writes `AUD_GAIN_DEFAULT` = 128), first-order
  sigma-delta DAC at 3.125 MHz (clk/16) with clamp, out on `cpu_exp` only
  in game mode. `tb_vrc6.v` 77 checks, 11 mutations caught. Test ROM
  `menu/tests/vrc6_tone.s` (8 parts: 2A03 vs VRC6 pulse at 440/110/55 Hz,
  saw, silence). Hardware: on an original N8 the test ROM plays every part
  and the menu runs; on our clone only part 1 (2A03) is audible, while
  Akumajou Densetsu's VRC6 bass comes through - a limit of that clone's
  board, not of the core.
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
- Test aids: an A/B MAPROUT for foreign cores (numbers 200+), diagnostic
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
