// n8-open: Konami VRC2 / VRC4 (iNES mappers 21, 22, 23, 25) for the
// EverDrive N8 clone, one per build (parameter MAPPER).
//
// Written from the public documentation (NESdev wiki: VRC2 and VRC4, VRC
// IRQ), not from any existing HDL.
//
// Register lines: the boards wire different CPU address lines to the chip's
// register select inputs. For iNES files without a submapper the wiki says
// mappers 21, 23 and 25 "each implement two address mappings at the same
// time" (the pairs do not overlap) and are presumed VRC4; here both pairs
// are ORed:
//   21  VRC4a (A1, A2)  + VRC4c (A6, A7)      VRC4
//   22  VRC2a (A1, A0)                         VRC2
//   23  VRC2b/VRC4f (A0, A1) + VRC4e (A2, A3)  VRC4
//   25  VRC2c/VRC4b (A1, A0) + VRC4d (A3, A2)  VRC4
// (register line 0, register line 1). Below, "sub" = {line 1, line 0}.
//
// Registers (sub in brackets):
//   $8000      8 KB PRG bank (5 bits): $8000, or $C000 in swap mode
//   $A000      8 KB PRG bank at $A000
//   $9000 (0)  mirroring: VRC4 0 V, 1 H, 2 one-screen lower, 3 upper;
//              VRC2 bit 0 only (every $9000-$9003 write here)
//   $9002 (2)  VRC4: bit 1 swap mode (switchable bank at $C000, the
//              second-last at $8000); bit 0 WRAM enable (not used, see below)
//   $B000-$E003  eight 1 KB CHR banks: register (page - $B) * 2 + line 1,
//              line 0 = 0: low nibble, 1: high bits (VRC4 5, VRC2 4: 9 / 8 bit
//              banks)
//   $F000-$F003  VRC4 IRQ: latch low / high nibble, control, acknowledge
//              (vrc_irq.v, the same IRQ as the VRC6; with the NTSC-on-PAL
//              correction of map_cfg[6])
// PRG: two switchable 8 KB banks, the second-last 8 KB at $C000 ($8000 in
// swap mode), the last 8 KB at $E000 ("last" = all ones, cut to the ROM size
// by top.v).
// Decisions (not the wiki's):
//   - 8 KB PRG RAM at $6000 always on, regardless of the VRC4 WRAM bit:
//     the VRC2's 1-bit "$6000 latch" that Contra (J) and Ganbare Goemon 2
//     read back works by itself (the RAM returns what was written); VRC4
//     games that switch WRAM never notice.
//   - VRC2a (22): the wiki documents the CHR value shifted right by one for
//     $B000-$B003; applied to all eight CHR registers here.

module map_vrc4 #(
    parameter MAPPER = 25
) (
    input         mclk,          // M2 on a clock pin
    input         m2,
    input         clk,           // board clock (PPU activity, PAL correction)
    input         ppu_rd,        // /RD
    input  [6:0]  map_cfg,       // bit 0: header mirroring, bit 6: NTSC game on PAL
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
    localparam VRC4 = (MAPPER != 22);

    reg [4:0] prg0 = 5'd0, prg1 = 5'd0;
    reg [1:0] mir  = 2'd0;
    reg       swap = 1'b0;
    reg [8:0] chr [0:7];
    reg [7:0] lat  = 8'd0;           // IRQ latch as written (two nibbles)
    integer i;
    initial for (i = 0; i < 8; i = i + 1) chr[i] = 9'd0;

    wire rom_area = ~cpu_ce;                                // $8000-$FFFF
    wire ram_area =  cpu_ce & (cpu_addr[14:13] == 2'b11);   // $6000-$7FFF
    wire [2:0] page = cpu_addr[14:12];                      // $8xxx = 0 ... $Fxxx = 7
    wire [14:0] a = cpu_addr;
    wire rl0 = (MAPPER == 21) ? (a[1] | a[6]) :
               (MAPPER == 22) ?  a[1] :
               (MAPPER == 23) ? (a[0] | a[2]) :
                                (a[1] | a[3]);              // 25
    wire rl1 = (MAPPER == 21) ? (a[2] | a[7]) :
               (MAPPER == 22) ?  a[0] :
               (MAPPER == 23) ? (a[1] | a[3]) :
                                (a[0] | a[2]);              // 25
    wire [1:0] sub = { rl1, rl0 };
    wire wr = rom_area & ~cpu_rw;
    wire [2:0] ci = { page[1:0] + 2'd1, rl1 };              // $B000 = 0 ... $E002 = 7

    always @(negedge mclk) begin
        if (rst) begin
            prg0 <= 5'd0;  prg1 <= 5'd0;  mir <= 2'd0;  swap <= 1'b0;  lat <= 8'd0;
            for (i = 0; i < 8; i = i + 1) chr[i] <= 9'd0;
        end else if (wr) begin
            case (page)
                3'd0: prg0 <= cpu_dat[4:0];                            // $8000
                3'd1: if (!VRC4)
                          mir <= { 1'b0, cpu_dat[0] };                 // VRC2: $9000-$9003
                      else if (sub == 2'd0)
                          mir <= cpu_dat[1:0];                         // VRC4: $9000
                      else if (sub == 2'd2)
                          swap <= cpu_dat[1];                          // VRC4: $9002
                3'd2: prg1 <= cpu_dat[4:0];                            // $A000
                3'd7: if (VRC4) begin                                  // $F000 IRQ
                          if (sub == 2'd0) lat[3:0] <= cpu_dat[3:0];
                          if (sub == 2'd1) lat[7:4] <= cpu_dat[3:0];
                      end
                default: begin                                         // $B000-$E003 CHR
                          if (!rl0)
                              chr[ci][3:0] <= cpu_dat[3:0];
                          else
                              chr[ci][8:4] <= VRC4 ? cpu_dat[4:0] : { 1'b0, cpu_dat[3:0] };
                      end
            endcase
        end
    end

    // ---------------------------------------------------------------- IRQ (VRC4)
    wire f_wr = VRC4 && wr && page == 3'd7;
    vrc_irq virq (
        .mclk(mclk), .clk(clk), .rst(rst), .ppu_rd(ppu_rd), .pal_fix(map_cfg[6]),
        .w_latch(f_wr && !rl1),
        .latch_d(rl0 ? { cpu_dat[3:0], lat[3:0] } : { lat[7:4], cpu_dat[3:0] }),
        .w_ctrl(f_wr && sub == 2'd2),
        .w_ack(f_wr && sub == 2'd3),
        .cpu_dat(cpu_dat), .irq(irq)
    );

    // ---------------------------------------------------------------- PRG
    wire sw = VRC4 & swap;
    always @* begin
        if (!rom_area)
            prg_a = { 6'b000000, cpu_addr[12:10] };                     // PRG RAM, 8 KB
        else case (cpu_addr[14:13])
            2'd0: prg_a = { (sw ? 6'b111110 : { 1'b0, prg0 }), cpu_addr[12:10] };   // $8000
            2'd1: prg_a = { 1'b0, prg1, cpu_addr[12:10] };                          // $A000
            2'd2: prg_a = { (sw ? { 1'b0, prg0 } : 6'b111110), cpu_addr[12:10] };   // $C000
            default: prg_a = { 6'b111111, cpu_addr[12:10] };                        // $E000
        endcase
    end
    assign prg_rom = rom_area;
    assign prg_ram = ram_area & m2;
    assign prg_wr  = ram_area & m2 & ~cpu_rw;

    // ---------------------------------------------------------------- CHR
    wire [8:0] creg = chr[ppu_addr[12:10]];
    assign chr_a   = (MAPPER == 22) ? { 1'b0, creg[8:1] } : creg;   // VRC2a: >> 1
    assign chr_sel = ~ppu_addr[13];
    assign chr_wr  = chr_is_ram & ~ppu_addr[13] & ~ppu_wr;

    // ---------------------------------------------------------------- mirroring
    always @* begin
        case (mir)
            2'd0: ciram_a10 = ppu_addr[10];          // vertical
            2'd1: ciram_a10 = ppu_addr[11];          // horizontal
            2'd2: ciram_a10 = 1'b0;                  // one-screen lower
            default: ciram_a10 = 1'b1;               // one-screen upper
        endcase
    end
    assign ciram_sel = ppu_addr[13];
endmodule
