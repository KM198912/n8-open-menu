// n8-open: MMC2 (mapper 9, PxROM: Punch-Out!!) and MMC4 (mapper 10, FxROM)
// for the EverDrive N8 clone, one per build (parameter MAPPER).
//
// Written from the public documentation (NESdev wiki: MMC2, MMC4), not from
// any existing HDL.
//
// Registers (falling M2; each fills its 4 KB window - the wiki gives the
// ranges $A000-$AFFF ... $F000-$FFFF):
//   $A000  PRG bank (4 bits): MMC2 8 KB at $8000, MMC4 16 KB at $8000
//   $B000  CHR 4 KB at $0000 while latch 0 = $FD      (5 bits)
//   $C000  CHR 4 KB at $0000 while latch 0 = $FE
//   $D000  CHR 4 KB at $1000 while latch 1 = $FD
//   $E000  CHR 4 KB at $1000 while latch 1 = $FE
//   $F000  mirroring, bit 0: 0 vertical, 1 horizontal
// PRG: MMC2 $A000-$FFFF = the last three 8 KB banks, no PRG RAM (the NES
// board); MMC4 $C000-$FFFF = the last 16 KB, 8 KB PRG RAM at $6000 (save
// SRAM offset 0, as the other cores). "Last" = all ones, cut to the ROM
// size by the PRG mask in top.v (reg $84).
//
// Latches: a PPU read of a trigger address switches the latch AFTER the
// read - the trigger tile itself is still drawn from the old bank (wiki).
// Sprite and background fetches alike.
//   MMC2  latch 0: exactly $0FD8 -> $FD, $0FE8 -> $FE
//         latch 1: $1FD8-$1FDF -> $FD, $1FE8-$1FEF -> $FE
//   MMC4  both latches by range ($0FD8-$0FDF / $0FE8-$0FEF, as latch 1)
// Here: the address is taken while /RD is low, the latch changes on the
// rising /RD edge (board clock, two-flop synchronised).
// Not documented: the latches' power-on state - $FE here (games set them in
// their first frame anyway).

module map_mmc2 #(
    parameter MAPPER = 9
) (
    input         mclk,          // M2 on a clock pin (register write on falling edge)
    input         m2,
    input         clk,           // board clock (PPU read tracking)
    input         rst,           // 1 while the menu map is active
    input  [7:0]  cpu_dat,
    input  [14:0] cpu_addr,
    input         cpu_ce,        // /ROMSEL
    input         cpu_rw,
    input  [13:0] ppu_addr,
    input         ppu_rd,        // /RD
    input         ppu_wr,        // /WR
    input         chr_is_ram,

    output reg [18:10] prg_a,
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
    localparam MMC4 = (MAPPER == 10);

    reg [3:0] prg_r = 4'd0;          // $A000
    reg [4:0] chr_r [0:3];           // $B000, $C000, $D000, $E000
    reg       mir   = 1'b0;          // $F000
    integer i;
    initial for (i = 0; i < 4; i = i + 1) chr_r[i] = 5'd0;

    wire rom_area = ~cpu_ce;                                // $8000-$FFFF
    wire ram_area =  cpu_ce & (cpu_addr[14:13] == 2'b11);   // $6000-$7FFF

    always @(negedge mclk) begin
        if (rst) begin
            prg_r <= 4'd0;  mir <= 1'b0;
            for (i = 0; i < 4; i = i + 1) chr_r[i] <= 5'd0;
        end else if (rom_area && !cpu_rw) begin
            case (cpu_addr[14:12])
                3'b010: prg_r    <= cpu_dat[3:0];           // $A000
                3'b011: chr_r[0] <= cpu_dat[4:0];           // $B000
                3'b100: chr_r[1] <= cpu_dat[4:0];           // $C000
                3'b101: chr_r[2] <= cpu_dat[4:0];           // $D000
                3'b110: chr_r[3] <= cpu_dat[4:0];           // $E000
                3'b111: mir      <= cpu_dat[0];             // $F000
                default: ;
            endcase
        end
    end

    // ---------------------------------------------------------------- PRG
    always @* begin
        if (ram_area)
            prg_a = { 6'b000000, cpu_addr[12:10] };                     // PRG RAM (MMC4)
        else if (MMC4)
            prg_a = cpu_addr[14] ? { 5'b11111, cpu_addr[13:10] }         // last 16 KB
                                 : { 1'b0, prg_r, cpu_addr[13:10] };
        else
            prg_a = (cpu_addr[14:13] == 2'b00) ? { 2'b00, prg_r, cpu_addr[12:10] }
                                               : { 4'b1111, cpu_addr[14:10] };  // last 24 KB
    end
    assign prg_rom = rom_area;
    assign prg_ram = MMC4 ? (ram_area & m2) : 1'b0;
    assign prg_wr  = MMC4 ? (ram_area & m2 & ~cpu_rw) : 1'b0;

    // ---------------------------------------------------------------- latches (clk)
    reg [2:0]  rd_s = 3'b111;
    reg [13:0] rd_addr = 14'd0;
    reg        latch0 = 1'b1, latch1 = 1'b1;    // 1 = $FE, 0 = $FD
    wire rd_fall = rd_s[2] & ~rd_s[1];
    wire rd_rise = ~rd_s[2] & rd_s[1];
    // trigger: $xFD8 / $xFE8, the whole row $xFD8-$xFDF / $xFE8-$xFEF where
    // ranges apply (MMC2 latch 1, both MMC4 latches)
    wire range = MMC4 | rd_addr[12];
    wire t_fd = (rd_addr[11:3] == 9'h1FB) && (range || rd_addr[2:0] == 3'd0);   // $xFD8
    wire t_fe = (rd_addr[11:3] == 9'h1FD) && (range || rd_addr[2:0] == 3'd0);   // $xFE8
    always @(posedge clk) begin
        rd_s <= { rd_s[1:0], ppu_rd };
        if (rst) begin
            latch0 <= 1'b1;  latch1 <= 1'b1;
        end else begin
            if (rd_fall)
                rd_addr <= ppu_addr;                    // stable while /RD is low
            if (rd_rise && !rd_addr[13] && (t_fd || t_fe)) begin
                if (rd_addr[12])
                    latch1 <= t_fe;
                else
                    latch0 <= t_fe;
            end
        end
    end

    // ---------------------------------------------------------------- CHR
    wire [4:0] cbank = ppu_addr[12] ? (latch1 ? chr_r[3] : chr_r[2])
                                    : (latch0 ? chr_r[1] : chr_r[0]);
    assign chr_a   = { 2'b00, cbank, ppu_addr[11:10] };
    assign chr_sel = ~ppu_addr[13];
    assign chr_wr  = chr_is_ram & ~ppu_addr[13] & ~ppu_wr;

    // ---------------------------------------------------------------- mirroring
    assign ciram_a10 = mir ? ppu_addr[11] : ppu_addr[10];
    assign ciram_sel = ppu_addr[13];

    assign irq = 1'b0;

endmodule
