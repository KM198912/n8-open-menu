// n8-open: Konami VRC IRQ (shared by map_vrc6.v and map_vrc4.v), with the
// NTSC-on-PAL correction.
//
// Written from the public documentation (NESdev wiki: VRC IRQ), not from any
// existing HDL. VRC4, VRC6 and VRC7 share this IRQ; the chips only differ in
// how the CPU writes the latch (VRC6: one byte, VRC4: two nibbles) - the
// caller does that and hands in the full byte.
//
// 8-bit counter counting up; clocked every CPU cycle (cycle mode) or by a
// prescaler of 341 - 3 per cycle, +341 when <= 0 (scanline mode: 114, 114,
// 113 cycles = 113 2/3 per NTSC line). On a clock at $FF it reloads the latch
// and raises the IRQ. Nothing is clocked while E = 0.
//   control write: A (bit 0, enable after acknowledge), E (bit 1, enable),
//                  M (bit 2, 1 = cycle mode); acknowledges, resets the
//                  prescaler, reloads the counter from the latch if E is set
//   acknowledge:   copies A into E
// The wiki's register section says a control write always resets the
// prescaler, its operation section "with E set"; this follows the register
// section (the counter is only reloaded with E set either way).
// Everything runs on the falling M2 edge: one step per CPU cycle; register
// writes override what the cycle computed.
//
// NTSC game on a PAL console (pal_fix = map_cfg[6], set by the menu): the
// VRC IRQ counts CPU cycles from the game's NMI, timed for NTSC. On PAL,
// vblank is 50 lines longer (the count runs out before the picture starts)
// and a line has 106 9/16 instead of 113 2/3 CPU cycles. With the bit set:
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
// where in vblank it starts. This deliberately departs from the real chip;
// without the bit the counter behaves exactly like the original.

module vrc_irq (
    input        mclk,           // M2 on a clock pin (falling edge)
    input        clk,            // board clock (PPU activity)
    input        rst,            // 1 while the menu map is active
    input        ppu_rd,         // /RD
    input        pal_fix,        // NTSC game on a PAL console
    input        w_latch,        // this CPU cycle writes the latch ...
    input  [7:0] latch_d,        // ... with this byte
    input        w_ctrl,         // this CPU cycle writes the control register
    input        w_ack,          // this CPU cycle writes the acknowledge register
    input  [7:0] cpu_dat,        // data of the control write
    output       irq
);
    localparam HOLD_IDLE_CLK  = 64;      // 1.28 us without a PPU read: not rendering
    localparam PAL_HOLD_SCAN  = 2238;    // vblank cycles counted, scanline mode:
                                         //  1 PAL line to the NMI (107) + 20 lines
                                         //  of 106 9/16 cycles
    localparam PAL_HOLD_CYC   = 2380;    // cycle mode: 107 + 20 NTSC lines (2273)
    localparam PAL_HOLD_MAX   = 5400;    // hold at most this long (PAL - NTSC
                                         //  vblank: 50 lines = 5328 cycles)

    reg [7:0] irq_latch = 8'd0;
    reg [7:0] irq_cnt   = 8'd0;
    reg signed [11:0] presc = 12'sd1705;     // 341 x 5
    reg       irq_a = 1'b0, irq_e = 1'b0, irq_m = 1'b0;
    reg       irq_p = 1'b0;                  // pending

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

            // ---- counter, one step per CPU cycle
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
            if (w_latch)
                irq_latch <= latch_d;
            if (w_ctrl) begin
                irq_a <= cpu_dat[0];
                irq_e <= cpu_dat[1];
                irq_m <= cpu_dat[2];
                irq_p <= 1'b0;
                presc <= 12'sd1705;
                if (cpu_dat[1])
                    irq_cnt <= irq_latch;
            end
            if (w_ack) begin
                irq_p <= 1'b0;
                irq_e <= irq_a;
            end
        end
    end

    assign irq = irq_p;
endmodule
