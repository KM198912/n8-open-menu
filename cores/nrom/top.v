// n8-open: board top level for the EverDrive N8 (clone), EP2C5T144C8.
//
// Written from the register/pin documentation in docs/hw-interface.md and
// docs/pinout.md. Port names match the pin assignments in n8_nrom.qsf.
//
// Structure:
//   n8_osmap   menu mode (mapper index $FF): registers $80-$88, memory windows
//   map_*      the one game mapper of this build (parameter MAPPER)
//   this file  selects menu or game and drives the board signals
//
// One core per mapper: each Quartus revision sets MAPPER and becomes
// /EDFC/MAPS/<100 + mapper>.RBF (see cores/cores.txt).
//
// Data buses: only a mapper that answers reads itself (MMC5: status,
// multiplier, ExRAM, fill/ExRAM nametables) drives them, and only through the
// gates below: the CPU bus while M2 is high and settled on a read the mapper
// claims, with the PRG and save SRAM outputs off; the PPU bus only during a
// PPU read the mapper claims (CIRAM and CHR SRAM are deselected then, the
// CHR buffer is open towards the PPU). All other mappers tie their claims
// to 0, so for them nothing changes: those buses stay undriven.

module n8_top #(
    // 1 = BIOS dump helper build (cores/biosdump): CPLD registers stay
    // unlocked in game mode, and a write to $5000 (bit 0) releases the PRG
    // RAM at $8000-$FFFF so the CPLD can show the BIOS flash there without a
    // bus fight. 0 = normal core.
    parameter DUMP_HELPER = 0,
    // 1 = after a reset from game mode, show the menu at $8000 without the
    // CPLD's "BIOS off" line (see osmap.v); 0 = old behaviour. The game
    // cores use 1 (the start-up failures once blamed on it were the SD CRC
    // bug in the loader); the menu core 255 (cores/nrom_noret) uses 0.
    parameter RET_MENU = 0,
    // iNES mapper of this build: 0 = NROM, 1 = MMC1, 2 = UxROM, 3 = CNROM,
    // 4 = MMC3, 5 = MMC5, 7 = AxROM, 20 = FDS, 24/26 = VRC6a/b, 66 = GxROM
    parameter MAPPER = 0
) (
    // CPU bus
    inout  [7:0]  cpu_dat,
    input  [14:0] cpu_addr,
    input         cpu_ce,      // /ROMSEL: low for $8000-$FFFF
    input         cpu_rw,
    input         cpu_m2,
    input         mclk,        // M2 again, on a clock-capable pin
    output        cpu_irq,
    output        cpu_exp,

    // PPU bus
    inout  [7:0]  ppu_dat,
    input  [13:0] ppu_addr,
    input         ppu_rd,      // /RD
    input         ppu_wr,      // /WR
    output        ppu_ciram_ce,
    output        ppu_ciram_a10,
    output        ppu_dir,     // CHR data buffer direction
    output        ppu_ex,      // CHR data buffer enable (active low)

    // PRG SRAM (A0-A9 come straight from the CPU bus)
    output [8:0]  prg_map,     // A10-A18
    output        prg_ce,      // active low
    output        prg_oe,      // active low
    output        prg_we,      // active low

    // CHR SRAM (A0-A9 come straight from the PPU bus)
    output [8:0]  chr_map,     // A10-A18
    output        chr_ce,      // active low
    output        chr_oe,      // active low
    output        chr_we,      // active low

    // save SRAM (shares the PRG address lines)
    output        ram_ce,      // active HIGH on this board
    output        ram_oe,      // active low
    output        ram_we,      // active low

    // misc
    input         clk,         // board oscillator
    output        max0,        // bus mode to the MAX II, bit 0
    output        max1,        // bus mode to the MAX II, bit 1
    input         max2         // from the MAX II: BIOS off
);

    // ------------------------------------------------------------------
    // Menu mode and its registers
    // ------------------------------------------------------------------
    wire [7:0]  map_idx;
    wire        os_mode = (map_idx == 8'hFF);
    wire [4:0]  prg_size;
    wire [5:0]  chr_size;
    wire        chr_is_ram;
    wire [6:0]  map_cfg;
    wire        bus_quiet;     // M2 stopped: console in reset
    wire        m2_ok;         // M2 high and settled

    wire [18:10] os_prg_a;
    wire        os_prg_rom, os_prg_ram, os_prg_wr;
    wire [18:10] os_chr_a;
    wire        os_chr_sel, os_chr_wr, os_ciram_a10, os_ciram_sel;

    n8_osmap #(.RET_MENU(RET_MENU)) osmap (
        .clk(clk), .mclk(mclk), .m2(cpu_m2),
        .cpu_dat(cpu_dat), .cpu_addr(cpu_addr), .cpu_ce(cpu_ce), .cpu_rw(cpu_rw),
        .ppu_addr(ppu_addr), .ppu_wr(ppu_wr),
        .bios_off(max2),
        .map_idx(map_idx), .prg_size(prg_size), .chr_size(chr_size),
        .chr_is_ram(chr_is_ram), .map_cfg(map_cfg), .aud_gain(aud_gain),
        .bus_quiet(bus_quiet), .m2_ok(m2_ok),
        .prg_a(os_prg_a), .prg_rom(os_prg_rom), .prg_ram(os_prg_ram), .prg_wr(os_prg_wr),
        .chr_a(os_chr_a), .chr_sel(os_chr_sel), .chr_wr(os_chr_wr),
        .ciram_a10(os_ciram_a10), .ciram_sel(os_ciram_sel)
    );

    // ------------------------------------------------------------------
    // Game mapper (one per build)
    // ------------------------------------------------------------------
    wire [18:10] gm_prg_a;
    wire        gm_prg_rom, gm_prg_ram, gm_prg_wr;
    wire [18:10] gm_chr_a;
    wire        gm_chr_sel, gm_chr_wr, gm_ciram_a10, gm_ciram_sel, gm_irq;
    wire [7:0]  gm_cpu_do, gm_ppu_do;    // data a mapper answers reads with ...
    wire        gm_cpu_oe, gm_ppu_oe;    // ... and when (claims, gated below)
    wire        gm_aud, gm_aud_en;       // expansion audio on cpu_exp (VRC6)
    wire        gm_prg_wok;              // game may write PRG SRAM (FDS RAM)
    wire [7:0]  aud_gain;                // $89

    // Only the mapper selected by MAPPER is built. Any game index in reg $83
    // (not $FF) runs it; MAPROUT.BIN decides which core a ROM gets.
    generate
        if (MAPPER == 1) begin : g_mmc1
            // MMC1 (registers held in power-on state while in menu mode)
            map_mmc1 mmc1 (
                .mclk(mclk), .m2(cpu_m2), .rst(os_mode), .cpu_dat(cpu_dat),
                .cpu_addr(cpu_addr), .cpu_ce(cpu_ce), .cpu_rw(cpu_rw),
                .ppu_addr(ppu_addr), .ppu_wr(ppu_wr),
                .chr_is_ram(chr_is_ram),
                .prg_a(gm_prg_a), .prg_rom(gm_prg_rom), .prg_ram(gm_prg_ram), .prg_wr(gm_prg_wr),
                .chr_a(gm_chr_a), .chr_sel(gm_chr_sel), .chr_wr(gm_chr_wr),
                .ciram_a10(gm_ciram_a10), .ciram_sel(gm_ciram_sel), .irq(gm_irq)
            );
            assign gm_cpu_oe = 1'b0;  assign gm_cpu_do = 8'h00;
            assign gm_ppu_oe = 1'b0;  assign gm_ppu_do = 8'h00;
            assign gm_aud = 1'b0;     assign gm_aud_en = 1'b0;
            assign gm_prg_wok = 1'b0;
        end else if (MAPPER == 4) begin : g_mmc3
            // MMC3 (scanline IRQ on PPU A12; held in power-on state in menu mode)
            map_mmc3 mmc3 (
                .mclk(mclk), .m2(cpu_m2), .rst(os_mode), .cpu_dat(cpu_dat),
                .cpu_addr(cpu_addr), .cpu_ce(cpu_ce), .cpu_rw(cpu_rw),
                .ppu_addr(ppu_addr), .ppu_wr(ppu_wr),
                .chr_is_ram(chr_is_ram),
                .prg_a(gm_prg_a), .prg_rom(gm_prg_rom), .prg_ram(gm_prg_ram), .prg_wr(gm_prg_wr),
                .chr_a(gm_chr_a), .chr_sel(gm_chr_sel), .chr_wr(gm_chr_wr),
                .ciram_a10(gm_ciram_a10), .ciram_sel(gm_ciram_sel), .irq(gm_irq)
            );
            assign gm_cpu_oe = 1'b0;  assign gm_cpu_do = 8'h00;
            assign gm_ppu_oe = 1'b0;  assign gm_ppu_do = 8'h00;
            assign gm_aud = 1'b0;     assign gm_aud_en = 1'b0;
            assign gm_prg_wok = 1'b0;
        end else if (MAPPER == 5) begin : g_mmc5
            // MMC5 (answers CPU and PPU reads; held in power-on state in menu mode)
            map_mmc5 mmc5 (
                .mclk(mclk), .m2(cpu_m2), .clk(clk), .rst(os_mode), .cpu_dat(cpu_dat),
                .cpu_addr(cpu_addr), .cpu_ce(cpu_ce), .cpu_rw(cpu_rw),
                .ppu_addr(ppu_addr), .ppu_rd(ppu_rd), .ppu_wr(ppu_wr), .ppu_dat(ppu_dat),
                .chr_is_ram(chr_is_ram),
                .prg_a(gm_prg_a), .prg_rom(gm_prg_rom), .prg_ram(gm_prg_ram), .prg_wr(gm_prg_wr),
                .chr_a(gm_chr_a), .chr_sel(gm_chr_sel), .chr_wr(gm_chr_wr),
                .ciram_a10(gm_ciram_a10), .ciram_sel(gm_ciram_sel), .irq(gm_irq),
                .cpu_do(gm_cpu_do), .cpu_oe(gm_cpu_oe), .ppu_do(gm_ppu_do), .ppu_oe(gm_ppu_oe),
                .aud_gain(aud_gain), .aud(gm_aud)
            );
            assign gm_aud_en = 1'b1;
            assign gm_prg_wok = 1'b0;
        end else if (MAPPER == 2 || MAPPER == 3 || MAPPER == 7 || MAPPER == 66 ||
                     MAPPER == 71 || MAPPER == 11 || MAPPER == 34) begin : g_simple
            // simple discrete mappers (map_simple.v)
            map_simple #(.MAPPER(MAPPER)) simple (
                .mclk(mclk), .m2(cpu_m2), .rst(os_mode), .cpu_dat(cpu_dat),
                .cpu_addr(cpu_addr), .cpu_ce(cpu_ce), .cpu_rw(cpu_rw),
                .ppu_addr(ppu_addr), .ppu_wr(ppu_wr),
                .chr_is_ram(chr_is_ram), .map_cfg(map_cfg),
                .prg_a(gm_prg_a), .prg_rom(gm_prg_rom), .prg_ram(gm_prg_ram), .prg_wr(gm_prg_wr),
                .chr_a(gm_chr_a), .chr_sel(gm_chr_sel), .chr_wr(gm_chr_wr),
                .ciram_a10(gm_ciram_a10), .ciram_sel(gm_ciram_sel), .irq(gm_irq)
            );
            assign gm_cpu_oe = 1'b0;  assign gm_cpu_do = 8'h00;
            assign gm_ppu_oe = 1'b0;  assign gm_ppu_do = 8'h00;
            assign gm_aud = 1'b0;     assign gm_aud_en = 1'b0;
            assign gm_prg_wok = 1'b0;
        end else if (MAPPER == 24 || MAPPER == 26) begin : g_vrc6
            // Konami VRC6 (26: A0/A1 swapped); held in power-on state in menu mode
            map_vrc6 #(.MAPPER(MAPPER)) vrc6 (
                .mclk(mclk), .m2(cpu_m2), .clk(clk), .ppu_rd(ppu_rd), .map_cfg(map_cfg),
                .rst(os_mode), .cpu_dat(cpu_dat),
                .cpu_addr(cpu_addr), .cpu_ce(cpu_ce), .cpu_rw(cpu_rw),
                .ppu_addr(ppu_addr), .ppu_wr(ppu_wr),
                .chr_is_ram(chr_is_ram),
                .prg_a(gm_prg_a), .prg_rom(gm_prg_rom), .prg_ram(gm_prg_ram), .prg_wr(gm_prg_wr),
                .chr_a(gm_chr_a), .chr_sel(gm_chr_sel), .chr_wr(gm_chr_wr),
                .ciram_a10(gm_ciram_a10), .ciram_sel(gm_ciram_sel), .irq(gm_irq),
                .aud_gain(aud_gain), .aud(gm_aud)
            );
            assign gm_cpu_oe = 1'b0;  assign gm_cpu_do = 8'h00;
            assign gm_ppu_oe = 1'b0;  assign gm_ppu_do = 8'h00;
            assign gm_aud_en = 1'b1;
            assign gm_prg_wok = 1'b0;
        end else if (MAPPER == 20) begin : g_fds
            // Famicom Disk System RAM adapter (map_fds.v); the menu loads the
            // BIOS, the disk sides and the block table
            map_fds fds (
                .mclk(mclk), .m2(cpu_m2), .clk(clk), .ppu_rd(ppu_rd), .map_cfg(map_cfg),
                .rst(os_mode), .cpu_dat(cpu_dat),
                .cpu_addr(cpu_addr), .cpu_ce(cpu_ce), .cpu_rw(cpu_rw),
                .ppu_addr(ppu_addr), .ppu_wr(ppu_wr),
                .prg_a(gm_prg_a), .prg_rom(gm_prg_rom), .prg_ram(gm_prg_ram), .prg_wr(gm_prg_wr),
                .chr_a(gm_chr_a), .chr_sel(gm_chr_sel), .chr_wr(gm_chr_wr),
                .ciram_a10(gm_ciram_a10), .ciram_sel(gm_ciram_sel), .irq(gm_irq),
                .cpu_do(gm_cpu_do), .cpu_oe(gm_cpu_oe),
                .aud_gain(aud_gain), .aud(gm_aud)
            );
            assign gm_ppu_oe = 1'b0;  assign gm_ppu_do = 8'h00;
            assign gm_aud_en = 1'b1;
            assign gm_prg_wok = 1'b1;
        end else if (MAPPER == 21 || MAPPER == 22 || MAPPER == 23 || MAPPER == 25) begin : g_vrc4
            // Konami VRC2 / VRC4 (map_vrc4.v; IRQ: vrc_irq.v, as the VRC6)
            map_vrc4 #(.MAPPER(MAPPER)) vrc4 (
                .mclk(mclk), .m2(cpu_m2), .clk(clk), .ppu_rd(ppu_rd), .map_cfg(map_cfg),
                .rst(os_mode), .cpu_dat(cpu_dat),
                .cpu_addr(cpu_addr), .cpu_ce(cpu_ce), .cpu_rw(cpu_rw),
                .ppu_addr(ppu_addr), .ppu_wr(ppu_wr),
                .chr_is_ram(chr_is_ram),
                .prg_a(gm_prg_a), .prg_rom(gm_prg_rom), .prg_ram(gm_prg_ram), .prg_wr(gm_prg_wr),
                .chr_a(gm_chr_a), .chr_sel(gm_chr_sel), .chr_wr(gm_chr_wr),
                .ciram_a10(gm_ciram_a10), .ciram_sel(gm_ciram_sel), .irq(gm_irq)
            );
            assign gm_cpu_oe = 1'b0;  assign gm_cpu_do = 8'h00;
            assign gm_ppu_oe = 1'b0;  assign gm_ppu_do = 8'h00;
            assign gm_aud = 1'b0;     assign gm_aud_en = 1'b0;
            assign gm_prg_wok = 1'b0;
        end else if (MAPPER == 9 || MAPPER == 10) begin : g_mmc2
            // MMC2 / MMC4 (CHR latches on PPU reads of tiles $FD/$FE)
            map_mmc2 #(.MAPPER(MAPPER)) mmc2 (
                .mclk(mclk), .m2(cpu_m2), .clk(clk), .rst(os_mode), .cpu_dat(cpu_dat),
                .cpu_addr(cpu_addr), .cpu_ce(cpu_ce), .cpu_rw(cpu_rw),
                .ppu_addr(ppu_addr), .ppu_rd(ppu_rd), .ppu_wr(ppu_wr),
                .chr_is_ram(chr_is_ram),
                .prg_a(gm_prg_a), .prg_rom(gm_prg_rom), .prg_ram(gm_prg_ram), .prg_wr(gm_prg_wr),
                .chr_a(gm_chr_a), .chr_sel(gm_chr_sel), .chr_wr(gm_chr_wr),
                .ciram_a10(gm_ciram_a10), .ciram_sel(gm_ciram_sel), .irq(gm_irq)
            );
            assign gm_cpu_oe = 1'b0;  assign gm_cpu_do = 8'h00;
            assign gm_ppu_oe = 1'b0;  assign gm_ppu_do = 8'h00;
            assign gm_aud = 1'b0;     assign gm_aud_en = 1'b0;
            assign gm_prg_wok = 1'b0;
        end else begin : g_nrom
            // NROM (MAPPER 0, also the default for the menu/dump builds)
            map_nrom nrom (
                .m2(cpu_m2),
                .cpu_addr(cpu_addr), .cpu_ce(cpu_ce), .cpu_rw(cpu_rw),
                .ppu_addr(ppu_addr), .ppu_wr(ppu_wr),
                .chr_is_ram(chr_is_ram), .map_cfg(map_cfg),
                .prg_a(gm_prg_a), .prg_rom(gm_prg_rom), .prg_ram(gm_prg_ram), .prg_wr(gm_prg_wr),
                .chr_a(gm_chr_a), .chr_sel(gm_chr_sel), .chr_wr(gm_chr_wr),
                .ciram_a10(gm_ciram_a10), .ciram_sel(gm_ciram_sel), .irq(gm_irq)
            );
            assign gm_cpu_oe = 1'b0;  assign gm_cpu_do = 8'h00;
            assign gm_ppu_oe = 1'b0;  assign gm_ppu_do = 8'h00;
            assign gm_aud = 1'b0;     assign gm_aud_en = 1'b0;
            assign gm_prg_wok = 1'b0;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Select menu or game
    // ------------------------------------------------------------------
    // dump helper: $5000-$5FFF write, bit 0 = release PRG RAM at $8000
    reg rom_released = 1'b0;
    always @(negedge mclk) begin
        if (DUMP_HELPER != 0 && cpu_ce && cpu_addr[14:12] == 3'b101 && !cpu_rw)
            rom_released <= cpu_dat[0];
    end
    wire gm_rom_on = (DUMP_HELPER != 0) ? ~rom_released : 1'b1;

    wire [18:10] prg_a     = os_mode ? os_prg_a     : gm_prg_a;
    wire        prg_rom    = os_mode ? os_prg_rom   : (gm_prg_rom & gm_rom_on);
    wire        prg_ram    = os_mode ? os_prg_ram   : gm_prg_ram;
    wire        prg_wr     = os_mode ? os_prg_wr    : gm_prg_wr;
    wire [18:10] chr_a     = os_mode ? os_chr_a     : gm_chr_a;
    wire        chr_sel    = os_mode ? os_chr_sel   : gm_chr_sel;
    wire        chr_wr     = os_mode ? os_chr_wr    : gm_chr_wr;
    wire        ciram_a10  = os_mode ? os_ciram_a10 : gm_ciram_a10;
    wire        ciram_sel  = os_mode ? os_ciram_sel : gm_ciram_sel;
    wire        irq        = os_mode ? 1'b0         : gm_irq;

    // size masks only apply to games' ROM accesses (never to PRG RAM bank
    // bits, e.g. MMC5's); the menu sees all memory
    wire [4:0] prg_mask = (os_mode | ~prg_rom) ? 5'b11111 : prg_size;
    wire [5:0] chr_mask = os_mode ? 6'b111111 : chr_size;

    assign prg_map = { prg_a[18:14] & prg_mask, prg_a[13:10] };
    assign chr_map = { chr_a[18:13] & chr_mask, chr_a[12:10] };

    // ------------------------------------------------------------------
    // Memory control
    // ------------------------------------------------------------------
    // PRG and save RAM are only enabled while M2 is high and settled, and not
    // while the console is in reset. PRG and save RAM are never enabled at the
    // same time.
    wire mem_ok = m2_ok & ~bus_quiet;

    assign prg_ce = mem_ok ? ~prg_rom : 1'b1;
    assign ram_ce = mem_ok ? (prg_ram & ~prg_rom) : 1'b0;
    // CPU reads the mapper answers itself: FPGA drives, SRAM outputs off
    wire cpu_drive = ~os_mode & gm_cpu_oe & cpu_rw & mem_ok;
    assign prg_oe = ~cpu_rw | cpu_drive;     // outputs only on CPU reads
    assign ram_oe = ~cpu_rw | cpu_drive;
    // games never write PRG RAM - except FDS, whose RAM lives there (its core
    // only raises prg_wr for the RAM and its disk write window)
    assign prg_we = os_mode ? ~prg_wr : ~(prg_wr & gm_prg_wok);
    assign ram_we = ~prg_wr;

    assign chr_ce = bus_quiet ? 1'b1 : ~chr_sel;
    assign chr_oe = ppu_rd;
    assign chr_we = ~chr_wr;

    // nametables in the console's CIRAM
    assign ppu_ciram_ce  = ~ciram_sel;
    assign ppu_ciram_a10 = ciram_a10;

    // CHR data buffer: off during CIRAM accesses, direction follows /RD
    assign ppu_ex  = ciram_sel;
    assign ppu_dir = ppu_rd;

    // ------------------------------------------------------------------
    // Data buses (see the rule at the top)
    // ------------------------------------------------------------------
    wire ppu_drive = ~os_mode & gm_ppu_oe & ~ppu_rd & ~bus_quiet;
    assign cpu_dat = cpu_drive ? gm_cpu_do : 8'hzz;
    assign ppu_dat = ppu_drive ? gm_ppu_do : 8'hzz;
    assign cpu_irq = irq ? 1'b0 : 1'bz;      // open drain
    assign cpu_exp = (~os_mode & gm_aud_en) ? gm_aud : 1'bz;   // expansion audio

    // MAX II bus mode: 11 = menu (CPLD registers unlocked), 01 = game (locked)
    assign max0 = 1'b1;
    assign max1 = os_mode | (DUMP_HELPER != 0);

endmodule
