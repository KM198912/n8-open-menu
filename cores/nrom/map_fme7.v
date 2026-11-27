// n8-open: Sunsoft FME-7 (iNES mapper 69) for the EverDrive N8 clone.
// The 5B variant's audio is not implemented yet.
//
// Written from the public documentation (NESdev wiki: Sunsoft FME-7), not
// from any existing HDL.
//
// Registers: $8000-$9FFF command (4 bits), $A000-$BFFF parameter - a
// parameter write executes the selected command:
//   $0-$7  CHR 1 KB bank at PPU $0000 ... $1C00 (8 bits)
//   $8     CPU $6000-$7FFF: bit 7 RAM enable, bit 6 RAM (1) / ROM (0),
//          bits 5:0 ROM bank. RAM selected but disabled: open bus.
//   $9-$B  8 KB PRG bank at $8000 / $A000 / $C000 (6 bits); $E000 = last
//   $C     mirroring, by signal: CIRAM A10 = 0 PPU A10, 1 PPU A11, 2 low,
//          3 high
//   $D     IRQ control: bit 0 IRQ enable, bit 7 counter enable; any write
//          acknowledges the IRQ
//   $E/$F  IRQ counter low / high, set directly (no reload latch)
// IRQ: the 16-bit counter counts down every CPU cycle while enabled; the
// step from $0000 to $FFFF raises the IRQ (if enabled), held until a $D
// write. Not documented, chosen: the counter keeps counting after the wrap
// (a plain down counter); power-on state all 0 (RAM off, $6000 = ROM bank 0).
// PRG RAM: 8 KB (save SRAM page 0, like the other cores); the RAM bank bits
// are ignored - the board has one 8 KB save page. "Last" bank = all ones,
// cut to the ROM size by top.v; $6000 in ROM mode reads PRG ROM.
// No bus conflicts.
//
// NTSC game on a PAL console (map_cfg[6], set by the menu): the counter
// counts CPU cycles from the game's NMI. As the FDS timer (map_fds.v): in
// vblank it counts only the cycles NTSC has between NMI and the pre-render
// line, then holds until the PPU reads again (at most PAL_HOLD_MAX cycles);
// while the PPU renders it counts 16 per 15 cycles (a PAL line has 106 9/16
// CPU cycles, NTSC 113 2/3: exactly 15/16). This deliberately departs from
// the real chip; without the bit the counter behaves exactly like it.

module map_fme7 (
    input         mclk,          // M2 on a clock pin (falling edge)
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
    reg [3:0]  cmd   = 4'd0;
    reg [7:0]  chr [0:7];
    reg [7:0]  r6    = 8'd0;         // command $8
    reg [5:0]  prg8  = 6'd0, prgA = 6'd0, prgC = 6'd0;
    reg [1:0]  mir   = 2'd0;
    reg        irq_en = 1'b0, cnt_en = 1'b0, irq_p = 1'b0;
    reg [15:0] cnt   = 16'd0;
    reg [3:0]  p15   = 4'd0;         // PAL: every 15th counted cycle counts 2
    integer i;
    initial for (i = 0; i < 8; i = i + 1) chr[i] = 8'd0;

    wire rom_area = ~cpu_ce;                                // $8000-$FFFF
    wire ram_area =  cpu_ce & (cpu_addr[14:13] == 2'b11);   // $6000-$7FFF
    wire w_cmd = rom_area & ~cpu_rw & (cpu_addr[14:13] == 2'b00);   // $8000-$9FFF
    wire w_par = rom_area & ~cpu_rw & (cpu_addr[14:13] == 2'b01);   // $A000-$BFFF

    // ---------------------------------------------------------------- PAL correction
    localparam HOLD_IDLE_CLK = 64;       // 1.28 us without a PPU read: not rendering
    localparam PAL_HOLD_CYC  = 2380;     // 1 PAL line to the NMI (107) + 20 NTSC lines
    localparam PAL_HOLD_MAX  = 5400;     // PAL - NTSC vblank: 50 lines = 5328 cycles
    wire pal_fix = map_cfg[6];

    reg [2:0] rd_s = 3'b111;
    reg [6:0] idle_clk = 7'd0;
    reg       rendering = 1'b0;
    always @(posedge clk) begin
        rd_s <= { rd_s[1:0], ppu_rd };
        if (rd_s[2] & ~rd_s[1]) begin
            idle_clk  <= 7'd0;
            rendering <= 1'b1;
        end else if (idle_clk != HOLD_IDLE_CLK) begin
            idle_clk <= idle_clk + 7'd1;
        end else
            rendering <= 1'b0;
    end

    reg [1:0]  ren_m = 2'b00;
    reg [12:0] vbl = 13'd0;
    wire       ren  = ren_m[1];
    wire       hold = pal_fix & ~ren & (vbl >= PAL_HOLD_CYC) & (vbl < PAL_HOLD_CYC + PAL_HOLD_MAX);
    wire [1:0] step = (pal_fix && ren && p15 == 4'd14) ? 2'd2 : 2'd1;

    always @(negedge mclk) begin
        if (rst) begin
            cmd <= 4'd0;  r6 <= 8'd0;  prg8 <= 6'd0;  prgA <= 6'd0;  prgC <= 6'd0;
            mir <= 2'd0;  irq_en <= 1'b0;  cnt_en <= 1'b0;  irq_p <= 1'b0;  cnt <= 16'd0;
            p15 <= 4'd0;  ren_m <= 2'b00;  vbl <= 13'd0;
            for (i = 0; i < 8; i = i + 1) chr[i] <= 8'd0;
        end else begin
            // ---- frame position (PAL correction)
            ren_m <= { ren_m[0], rendering };
            if (ren)
                vbl <= 13'd0;
            else if (vbl != 13'h1FFF)
                vbl <= vbl + 13'd1;

            // ---- IRQ counter, one step per CPU cycle
            if (cnt_en && !hold) begin
                if (pal_fix && ren)
                    p15 <= (p15 == 4'd14) ? 4'd0 : p15 + 4'd1;
                cnt <= cnt - { 14'd0, step };
                if (cnt < { 14'd0, step } && irq_en)
                    irq_p <= 1'b1;                       // $0000 -> $FFFF
            end

            // ---- registers (writes override what the cycle computed)
            if (w_cmd)
                cmd <= cpu_dat[3:0];
            if (w_par) begin
                case (cmd)
                    4'h8: r6   <= cpu_dat;
                    4'h9: prg8 <= cpu_dat[5:0];
                    4'hA: prgA <= cpu_dat[5:0];
                    4'hB: prgC <= cpu_dat[5:0];
                    4'hC: mir  <= cpu_dat[1:0];
                    4'hD: begin
                              irq_en <= cpu_dat[0];
                              cnt_en <= cpu_dat[7];
                              irq_p  <= 1'b0;            // any write acknowledges
                          end
                    4'hE: cnt[7:0]  <= cpu_dat;
                    4'hF: cnt[15:8] <= cpu_dat;
                    default: chr[cmd[2:0]] <= cpu_dat;   // $0-$7
                endcase
            end
        end
    end

    // ---------------------------------------------------------------- PRG
    wire ram_sel = r6[6];                // $6000: RAM selected
    wire ram_on  = r6[6] & r6[7];        // ... and enabled
    always @* begin
        if (ram_area)
            prg_a = ram_sel ? { 6'b000000, cpu_addr[12:10] }        // PRG RAM, 8 KB
                            : { r6[5:0], cpu_addr[12:10] };         // ROM bank at $6000
        else case (cpu_addr[14:13])
            2'd0: prg_a = { prg8, cpu_addr[12:10] };
            2'd1: prg_a = { prgA, cpu_addr[12:10] };
            2'd2: prg_a = { prgC, cpu_addr[12:10] };
            default: prg_a = { 6'b111111, cpu_addr[12:10] };        // last 8 KB
        endcase
    end
    assign prg_rom = rom_area | (ram_area & ~ram_sel);
    assign prg_ram = ram_area & ram_on & m2;             // RAM selected, disabled: open bus
    assign prg_wr  = ram_area & ram_on & m2 & ~cpu_rw;

    // ---------------------------------------------------------------- CHR
    assign chr_a   = { 1'b0, chr[ppu_addr[12:10]] };
    assign chr_sel = ~ppu_addr[13];
    assign chr_wr  = chr_is_ram & ~ppu_addr[13] & ~ppu_wr;

    // ---------------------------------------------------------------- mirroring
    always @* begin
        case (mir)
            2'd0: ciram_a10 = ppu_addr[10];
            2'd1: ciram_a10 = ppu_addr[11];
            2'd2: ciram_a10 = 1'b0;
            default: ciram_a10 = 1'b1;
        endcase
    end
    assign ciram_sel = ppu_addr[13];

    assign irq = irq_p;
endmodule
