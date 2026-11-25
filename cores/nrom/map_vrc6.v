// n8-open: Konami VRC6 (mappers 24 = VRC6a, 26 = VRC6b) for the EverDrive N8
// clone. Phase 1: banking, mirroring, PRG RAM, IRQ. The sound channels
// ($9000-$B002) are not implemented yet; writes there are ignored.
//
// Written from the public documentation (NESdev wiki: VRC6, VRC IRQ), not
// from any existing HDL.
//
// Registers: only CPU A0, A1 and A12-A15 are decoded (mirrors: addr & $F003).
// Mapper 26 is the same chip with A0 and A1 swapped on the board - for all
// registers, IRQ included.
//   $8000-$8003  16 KB PRG bank at $8000 (bits 3:0)
//   $B003        bit 7 PRG RAM enable, bits 3:2 mirroring (0 vertical,
//                1 horizontal, 2 one-screen lower, 3 one-screen upper),
//                bits 1:0 PPU banking mode, bit 4 nametables from CHR ROM,
//                bit 5 CHR A10 rules
//   $C000-$C003  8 KB PRG bank at $C000 (bits 4:0); $E000-$FFFF = last 8 KB
//   $D000-$D003  CHR 1 KB banks R0-R3 ($0000-$0FFF)
//   $E000-$E003  CHR 1 KB banks R4-R7 ($1000-$1FFF)
//   $F000        IRQ latch
//   $F001        IRQ control: bit 0 A (enable after acknowledge), bit 1 E
//                (enable), bit 2 M (1 = cycle mode); acknowledges, resets the
//                prescaler, reloads the counter from the latch if E is set
//   $F002        IRQ acknowledge: copies A into E
// The wiki lists $8000 and $C000 only; $8001-$8003 / $C001-$C003 are taken
// as the same register (only A0/A1 would tell them apart).
//
// $B003: Konami's three VRC6 games (Akumajou Densetsu, Madara, Esper Dream 2)
// only write $20/$24/$28/$2C/$A0/$A4/$A8/$AC: bit 5 set, PPU mode 0, CIRAM
// nametables. Only that is implemented: modes 1-3, CHR-ROM nametables
// (bit 4) and the bit-5-clear A10 rules are not (see BACKLOG.md).
//
// IRQ (VRC IRQ): 8-bit counter counting up; clocked every CPU cycle (cycle
// mode) or by a prescaler of 341 - 3 per cycle, +341 when <= 0 (scanline
// mode: 114, 114, 113 cycles = 113 2/3 per NTSC line). On a clock at $FF it
// reloads the latch and raises the IRQ. Nothing is clocked while E = 0.
// The wiki's register section says a $F001 write always resets the
// prescaler, its operation section "with E set"; this follows the register
// section (the counter is only reloaded with E set either way).
// Everything runs on the falling M2 edge: one step per CPU cycle.
//
// NTSC game on a PAL console (map_cfg[6] = 1, set by the menu): the VRC IRQ
// counts CPU cycles from the game's NMI, timed for NTSC. On PAL, vblank is
// 50 lines longer (the count runs out before the picture starts) and a line
// has 106 9/16 instead of 113 2/3 CPU cycles. With the bit set:
//   - scanline mode uses the PAL line length (prescaler step 16 instead of
//     15 on the common base 1705 = 341 x 5);
//   - in vblank the counter runs only as long as it would on NTSC between
//     NMI and the pre-render line (20 lines), then holds until the PPU reads
//     again (pre-render line) - at most PAL_HOLD_MAX cycles, so with
//     rendering off it never stops for long.
// The frame position comes from the PPU's reads: none for HOLD_IDLE_CLK
// board clocks = not rendering (the reads are 2 dots apart while rendering).
// For a game that sets its IRQ in NMI (the usual pattern) only the hold's
// length matters - it takes ~50 PAL lines out of the vblank count - not
// where in vblank it starts.
// This deliberately departs from the real chip; without the bit the core
// behaves exactly like a VRC6.

module map_vrc6 #(
    parameter MAPPER = 24
) (
    input         mclk,          // M2 on a clock pin
    input         m2,
    input         clk,           // board clock (PPU activity, PAL correction)
    input         ppu_rd,        // /RD
    input  [6:0]  map_cfg,       // bit 6: NTSC game on a PAL console
    input         rst,           // 1 while the menu map is active
    input  [7:0]  cpu_dat,
    input  [14:0] cpu_addr,
    input         cpu_ce,        // /ROMSEL
    input         cpu_rw,
    input  [13:0] ppu_addr,
    input         ppu_wr,        // /WR
    input         chr_is_ram,

    output reg [18:10] prg_a,
    output         prg_rom,
    output         prg_ram,
    output         prg_wr,
    output [18:10] chr_a,
    output         chr_sel,
    output         chr_wr,
    output reg     ciram_a10,
    output         ciram_sel,
    output         irq
);

    reg [3:0] prg16 = 4'd0;
    reg [4:0] prg8  = 5'd0;
    reg [7:0] b003  = 8'd0;
    reg [7:0] r0 = 8'd0, r1 = 8'd0, r2 = 8'd0, r3 = 8'd0;
    reg [7:0] r4 = 8'd0, r5 = 8'd0, r6 = 8'd0, r7 = 8'd0;

    reg [7:0] irq_latch = 8'd0;
    reg [7:0] irq_cnt   = 8'd0;
    reg signed [11:0] presc = 12'sd1705;     // 341 x 5
    reg       irq_a = 1'b0, irq_e = 1'b0, irq_m = 1'b0;
    reg       irq_p = 1'b0;                  // pending

    wire rom_area = ~cpu_ce;                                // $8000-$FFFF
    wire ram_area =  cpu_ce & (cpu_addr[14:13] == 2'b11);   // $6000-$7FFF
    wire [2:0] page = cpu_addr[14:12];                      // $8xxx = 0 ... $Fxxx = 7
    // logical A1:A0 (VRC6b: swapped on the board)
    wire [1:0] sub  = (MAPPER == 26) ? { cpu_addr[0], cpu_addr[1] } : cpu_addr[1:0];
    wire       wr   = rom_area & ~cpu_rw;

    // ---------------------------------------------------------------- PAL correction
    localparam HOLD_IDLE_CLK  = 64;      // 1.28 us without a PPU read: not rendering
    localparam PAL_HOLD_SCAN  = 2238;    // vblank cycles counted, scanline mode:
                                         //  1 PAL line to the NMI (107) + 20 lines
                                         //  of 106 9/16 cycles
    localparam PAL_HOLD_CYC   = 2380;    // cycle mode: 107 + 20 NTSC lines (2273)
    localparam PAL_HOLD_MAX   = 5400;    // hold at most this long (PAL - NTSC
                                         //  vblank: 50 lines = 5328 cycles)
    wire pal_fix = map_cfg[6];

    // clk domain: is the PPU rendering (reading)?
    reg [2:0] rd_s = 3'b111;
    reg [6:0] idle_clk = 7'd0;
    reg       rendering = 1'b0;
    always @(posedge clk) begin
        rd_s <= { rd_s[1:0], ppu_rd };
        if (rd_s[2] & ~rd_s[1]) begin            // a PPU read started
            idle_clk  <= 7'd0;
            rendering <= 1'b1;
        end else if (idle_clk != HOLD_IDLE_CLK) begin
            idle_clk <= idle_clk + 7'd1;
        end else
            rendering <= 1'b0;
    end

    // mclk domain: CPU cycles since the PPU stopped reading (vblank start)
    reg [1:0]  ren_m = 2'b00;
    reg [12:0] vbl = 13'd0;
    wire       ren = ren_m[1];
    wire [12:0] hold_from = irq_m ? PAL_HOLD_CYC : PAL_HOLD_SCAN;
    wire       hold = pal_fix & ~ren & (vbl >= hold_from) & (vbl < hold_from + PAL_HOLD_MAX);

    // IRQ clock for this CPU cycle (prescaler step: 15 NTSC, 16 PAL)
    wire signed [11:0] p_next = presc - (pal_fix ? 12'sd16 : 12'sd15);
    wire       tick = irq_e & ~hold & (irq_m | (p_next <= 12'sd0));

    always @(negedge mclk) begin
        if (rst) begin
            prg16 <= 4'd0;  prg8 <= 5'd0;  b003 <= 8'd0;
            r0 <= 8'd0; r1 <= 8'd0; r2 <= 8'd0; r3 <= 8'd0;
            r4 <= 8'd0; r5 <= 8'd0; r6 <= 8'd0; r7 <= 8'd0;
            irq_latch <= 8'd0;  irq_cnt <= 8'd0;  presc <= 12'sd1705;
            vbl <= 13'd0;       ren_m <= 2'b00;
            irq_a <= 1'b0;  irq_e <= 1'b0;  irq_m <= 1'b0;  irq_p <= 1'b0;
        end else begin
            // ---- frame position (PAL correction)
            ren_m <= { ren_m[0], rendering };
            if (ren)
                vbl <= 13'd0;
            else if (vbl != 13'h1FFF)
                vbl <= vbl + 13'd1;

            // ---- IRQ counter, one step per CPU cycle
            if (irq_e && !irq_m && !hold)
                presc <= (p_next <= 12'sd0) ? p_next + 12'sd1705 : p_next;
            if (tick) begin
                if (irq_cnt == 8'hFF) begin
                    irq_cnt <= irq_latch;
                    irq_p   <= 1'b1;
                end else
                    irq_cnt <= irq_cnt + 8'd1;
            end

            // ---- register writes (later assignments win)
            if (wr) begin
                case (page)
                    3'd0: prg16 <= cpu_dat[3:0];                        // $8000
                    3'd3: if (sub == 2'd3) b003 <= cpu_dat;             // $B003
                    3'd4: prg8 <= cpu_dat[4:0];                         // $C000
                    3'd5: case (sub)                                    // $D000
                              2'd0: r0 <= cpu_dat;
                              2'd1: r1 <= cpu_dat;
                              2'd2: r2 <= cpu_dat;
                              default: r3 <= cpu_dat;
                          endcase
                    3'd6: case (sub)                                    // $E000
                              2'd0: r4 <= cpu_dat;
                              2'd1: r5 <= cpu_dat;
                              2'd2: r6 <= cpu_dat;
                              default: r7 <= cpu_dat;
                          endcase
                    3'd7: case (sub)                                    // $F000
                              2'd0: irq_latch <= cpu_dat;
                              2'd1: begin                               // control
                                        irq_a <= cpu_dat[0];
                                        irq_e <= cpu_dat[1];
                                        irq_m <= cpu_dat[2];
                                        irq_p <= 1'b0;
                                        presc <= 12'sd1705;
                                        if (cpu_dat[1])
                                            irq_cnt <= irq_latch;
                                    end
                              2'd2: begin                               // acknowledge
                                        irq_p <= 1'b0;
                                        irq_e <= irq_a;
                                    end
                              default: ;
                          endcase
                    default: ;                                          // audio (phase 2)
                endcase
            end
        end
    end

    // ---------------------------------------------------------------- PRG
    always @* begin
        if (!rom_area)
            prg_a = { 6'b000000, cpu_addr[12:10] };                     // PRG RAM, 8 KB
        else if (!cpu_addr[14])
            prg_a = { 1'b0, prg16, cpu_addr[13:10] };                   // 16 KB at $8000
        else if (!cpu_addr[13])
            prg_a = { 1'b0, prg8, cpu_addr[12:10] };                    // 8 KB at $C000
        else
            prg_a = { 6'b111111, cpu_addr[12:10] };                     // last 8 KB
    end
    assign prg_rom = rom_area;
    assign prg_ram = ram_area & m2 & b003[7];
    assign prg_wr  = ram_area & m2 & b003[7] & ~cpu_rw;

    // ---------------------------------------------------------------- CHR (mode 0)
    reg [7:0] cbank;
    always @* begin
        case (ppu_addr[12:10])
            3'd0: cbank = r0;
            3'd1: cbank = r1;
            3'd2: cbank = r2;
            3'd3: cbank = r3;
            3'd4: cbank = r4;
            3'd5: cbank = r5;
            3'd6: cbank = r6;
            default: cbank = r7;
        endcase
    end
    assign chr_a   = { 1'b0, cbank };
    assign chr_sel = ~ppu_addr[13];
    assign chr_wr  = chr_is_ram & ~ppu_addr[13] & ~ppu_wr;

    // ---------------------------------------------------------------- mirroring
    always @* begin
        case (b003[3:2])
            2'd0: ciram_a10 = ppu_addr[10];          // vertical
            2'd1: ciram_a10 = ppu_addr[11];          // horizontal
            2'd2: ciram_a10 = 1'b0;                  // one-screen lower
            default: ciram_a10 = 1'b1;               // one-screen upper
        endcase
    end
    assign ciram_sel = ppu_addr[13];

    assign irq = irq_p;

endmodule
