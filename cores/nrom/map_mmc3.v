// n8-open: mapper 4 (MMC3: TxROM boards) for the EverDrive N8 clone.
//
// Written from the public MMC3 documentation (behaviour), not from any
// existing HDL.
//
// CPU registers ($8000-$FFFF, A14:A13 = range, A0 = even/odd):
//   $8000 even  bank select: bits 2:0 register R0-R7, bit 6 PRG mode,
//               bit 7 CHR A12 inversion
//   $8001 odd   bank data for the selected register
//   $A000 even  mirroring: bit 0 = 0 vertical, 1 horizontal
//   $A001 odd   PRG RAM: bit 7 enable, bit 6 write protect
//   $C000 even  IRQ latch
//   $C001 odd   IRQ reload (counter cleared, reloaded on the next clock)
//   $E000 even  IRQ disable + acknowledge
//   $E001 odd   IRQ enable
//
// PRG (8 KB banks, "-2" = second-to-last, "-1" = last):
//   mode 0: $8000 R6, $A000 R7, $C000 -2, $E000 -1
//   mode 1: $8000 -2, $A000 R7, $C000 R6, $E000 -1
//   The fixed banks are all ones; the size mask in top.v (reg $84) cuts them
//   down to the real ROM size.
// CHR (with inversion bit = 0; 1 swaps the two pattern tables):
//   $0000 R0 (2 KB), $0800 R1 (2 KB), $1000-$1C00 R2-R5 (1 KB each)
//
// Scanline counter (MMC3B/C behaviour): clocked by a rise of PPU A12 after
// A12 was low for at least 4 falling M2 edges (~10 PPU dots, the threshold
// emulators use). That passes the one rise per scanline (switch to the other
// pattern table) and filters the 4-dot A12 dips between the sprite fetches
// and the 8-9-dot dip at the line end when the background is at $1000
// (3 edges would count that one as an extra scanline). On a clock: counter 0 or reload pending ->
// counter = latch, else counter - 1; then counter 0 with IRQ enabled ->
// IRQ line low until $E000 is written.
// A12 is sampled on the falling M2 edge, so the whole mapper runs in the M2
// clock domain; the IRQ can come up to one CPU cycle after the real chip's.
//
// Not supported: four-screen boards (extra VRAM) and MMC6 (StarTropics,
// different PRG RAM), see BACKLOG.md.

module map_mmc3 (
    input         mclk,          // M2 on a clock pin (register writes on falling edge)
    input         m2,
    input         rst,           // 1 while the menu map is active: power-on state
    input  [7:0]  cpu_dat,
    input  [14:0] cpu_addr,
    input         cpu_ce,        // /ROMSEL
    input         cpu_rw,
    input  [13:0] ppu_addr,
    input         ppu_wr,        // /WR
    input         chr_is_ram,

    output [18:10] prg_a,
    output         prg_rom,
    output         prg_ram,
    output         prg_wr,
    output [18:10] chr_a,
    output         chr_sel,
    output         chr_wr,
    output         ciram_a10,
    output         ciram_sel,
    output         irq
);

    reg [2:0] bank_sel = 3'd0;
    reg       prg_mode = 1'b0;
    reg       chr_inv  = 1'b0;
    reg [7:0] r0 = 8'd0, r1 = 8'd0, r2 = 8'd0, r3 = 8'd0;
    reg [7:0] r4 = 8'd0, r5 = 8'd0, r6 = 8'd0, r7 = 8'd0;
    reg       mirror   = 1'b0;   // 0 vertical, 1 horizontal
    reg       ram_en   = 1'b1;   // power-on: RAM usable without a $A001 write
    reg       ram_wp   = 1'b0;

    reg [7:0] irq_latch  = 8'd0;
    reg [7:0] irq_cnt    = 8'd0;
    reg       irq_reload = 1'b0;
    reg       irq_en     = 1'b0;
    reg       irq_flag   = 1'b0;
    reg [2:0] a12_low    = 3'd0; // falling M2 edges with A12 low (saturates at 4)

    wire rom_area = ~cpu_ce;                                // $8000-$FFFF
    wire ram_area =  cpu_ce & (cpu_addr[14:13] == 2'b11);   // $6000-$7FFF
    wire port_wr  =  rom_area & ~cpu_rw;
    wire [2:0] reg_no = { cpu_addr[14:13], cpu_addr[0] };

    // A12 filter: a scanline clock is a high sample after >= 4 low samples
    wire a12      = ppu_addr[12];
    wire irq_clk  = a12 & (a12_low == 3'd4);
    wire [7:0] cnt_next = (irq_cnt == 8'd0 || irq_reload) ? irq_latch : irq_cnt - 8'd1;

    always @(negedge mclk) begin
        if (rst) begin
            bank_sel <= 3'd0;  prg_mode <= 1'b0;  chr_inv <= 1'b0;
            r0 <= 8'd0; r1 <= 8'd0; r2 <= 8'd0; r3 <= 8'd0;
            r4 <= 8'd0; r5 <= 8'd0; r6 <= 8'd0; r7 <= 8'd0;
            mirror <= 1'b0;  ram_en <= 1'b1;  ram_wp <= 1'b0;
            irq_latch <= 8'd0;  irq_cnt <= 8'd0;  irq_reload <= 1'b0;
            irq_en <= 1'b0;  irq_flag <= 1'b0;  a12_low <= 3'd0;
        end else begin
            // scanline counter
            if (a12)
                a12_low <= 3'd0;
            else if (a12_low != 3'd4)
                a12_low <= a12_low + 3'd1;

            if (irq_clk) begin
                irq_cnt    <= cnt_next;
                irq_reload <= 1'b0;
                if (cnt_next == 8'd0 && irq_en)
                    irq_flag <= 1'b1;
            end

            // CPU registers (later assignments win over the counter above)
            if (port_wr) begin
                case (reg_no)
                    3'd0: begin
                              bank_sel <= cpu_dat[2:0];
                              prg_mode <= cpu_dat[6];
                              chr_inv  <= cpu_dat[7];
                          end
                    3'd1: case (bank_sel)
                              3'd0: r0 <= cpu_dat;
                              3'd1: r1 <= cpu_dat;
                              3'd2: r2 <= cpu_dat;
                              3'd3: r3 <= cpu_dat;
                              3'd4: r4 <= cpu_dat;
                              3'd5: r5 <= cpu_dat;
                              3'd6: r6 <= cpu_dat;
                              3'd7: r7 <= cpu_dat;
                          endcase
                    3'd2: mirror <= cpu_dat[0];
                    3'd3: begin
                              ram_en <= cpu_dat[7];
                              ram_wp <= cpu_dat[6];
                          end
                    3'd4: irq_latch <= cpu_dat;
                    3'd5: begin
                              irq_cnt    <= 8'd0;
                              irq_reload <= 1'b1;
                          end
                    3'd6: begin
                              irq_en   <= 1'b0;
                              irq_flag <= 1'b0;
                          end
                    3'd7: irq_en <= 1'b1;
                endcase
            end
        end
    end

    // ---------------------------------------------------------------- PRG
    reg [5:0] bank8;
    always @* begin
        case (cpu_addr[14:13])
            2'd0:    bank8 = prg_mode ? 6'b111110 : r6[5:0];
            2'd1:    bank8 = r7[5:0];
            2'd2:    bank8 = prg_mode ? r6[5:0] : 6'b111110;
            default: bank8 = 6'b111111;
        endcase
    end

    assign prg_a   = rom_area ? { bank8, cpu_addr[12:10] }
                              : { 6'b000000, cpu_addr[12:10] };   // PRG RAM, 8 KB
    assign prg_rom = rom_area;
    assign prg_ram = ram_area & m2 & ram_en;
    assign prg_wr  = ram_area & m2 & ram_en & ~ram_wp & ~cpu_rw;

    // ---------------------------------------------------------------- CHR
    wire       chr_hi = ppu_addr[12] ^ chr_inv;   // 1 = the 1 KB half
    reg  [7:0] bank1k;
    always @* begin
        if (!chr_hi)
            bank1k = ppu_addr[11] ? { r1[7:1], ppu_addr[10] } : { r0[7:1], ppu_addr[10] };
        else case (ppu_addr[11:10])
            2'd0:    bank1k = r2;
            2'd1:    bank1k = r3;
            2'd2:    bank1k = r4;
            default: bank1k = r5;
        endcase
    end

    assign chr_a   = { 1'b0, bank1k };
    assign chr_sel = ~ppu_addr[13];
    assign chr_wr  = chr_is_ram & ~ppu_addr[13] & ~ppu_wr;

    // ---------------------------------------------------------------- mirroring
    assign ciram_a10 = mirror ? ppu_addr[11] : ppu_addr[10];
    assign ciram_sel = ppu_addr[13];

    assign irq = irq_flag;

endmodule
