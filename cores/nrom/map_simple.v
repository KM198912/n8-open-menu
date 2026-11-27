// n8-open: simple discrete-logic mappers for the EverDrive N8 clone, one per
// build (parameter MAPPER, folded at synthesis):
//   2  UxROM   16 KB at $8000 switchable (bits 4:0), last 16 KB fixed at $C000,
//              CHR RAM, header mirroring
//   3  CNROM   PRG fixed 16/32 KB, 8 KB CHR bank (bits 5:0), header mirroring
//   7  AxROM   32 KB PRG bank (bits 3:0), CHR RAM, one-screen mirroring from
//              bit 4 (0 = lower, 1 = upper nametable)
//  11  Color Dreams  32 KB PRG bank (bits 1:0), 8 KB CHR bank (bits 7:4),
//              header mirroring (bits 3:2 only feed the lockout defeat)
//  34  BNROM and NINA-001 in one: BNROM's register at $8000-$FFFF (bits
//              1:0 = 32 KB PRG); NINA-001's at $7FFD (bit 0 = 32 KB PRG),
//              $7FFE / $7FFF (4 KB CHR banks at $0000 / $1000), with 8 KB PRG
//              RAM at $6000 (the writes go to the RAM too). Emulators pick
//              the board by CHR size (<= 8 KB: BNROM); here both work at
//              once instead - BNROM games never write $7FFD-$7FFF, NINA games
//              never write $8000-$FFFF, and the CHR registers start at 0 and
//              1 = BNROM's unbanked 8 KB. Our decision, not the wiki's; power-
//              on values are undefined there.
//  66  GxROM   32 KB PRG bank (bits 5:4), 8 KB CHR bank (bits 1:0), header
//              mirroring
//  71  Camerica / Codemasters (BF909x): 16 KB at $8000 from writes to
//              $C000-$FFFF (bits 3:0), last 16 KB fixed at $C000, CHR RAM,
//              no PRG RAM on the boards. Mirroring from the header, except
//              Fire Hawk (BF9097): $8000-$9FFF bit 4 selects one screen.
//              Micro Machines and Ultimate Stuntman write $00 to $8000 at
//              start, so - as FCEUX does (NESdev wiki) - one-screen
//              mirroring takes over only after a write to $9000-$9FFF;
//              writes to $8000-$8FFF are ignored. Power-on state of the bank
//              register: not documented, 0 here.
//
// Written from the public mapper documentation (NESdev wiki), not from any
// existing HDL. One register: any CPU write to $8000-$FFFF, taken on the
// falling edge of M2, cleared while the menu map is active. The original
// boards have bus conflicts (the ROM drives the bus during the write); here
// the SRAM output is off on writes, so the CPU value always arrives - games
// avoid conflicts, so this is only more tolerant.
// Oversized bank numbers are cut by the size masks in top.v (reg $84).
// Like NROM: 8 KB PRG RAM at $6000 (save SRAM offset 0), header mirroring
// from map_cfg[0] (1 = vertical).

module map_simple #(
    parameter MAPPER = 2
) (
    input         mclk,          // M2 on a clock pin (register write on falling edge)
    input         m2,
    input         rst,           // 1 while the menu map is active
    input  [7:0]  cpu_dat,
    input  [14:0] cpu_addr,
    input         cpu_ce,        // /ROMSEL
    input         cpu_rw,
    input  [13:0] ppu_addr,
    input         ppu_wr,        // /WR
    input         chr_is_ram,
    input  [6:0]  map_cfg,

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

    reg [7:0] bank = 8'd0;
    reg       fh_on = 1'b0;          // mapper 71: one-screen mode seen ($9000 write)
    reg       fh_scr = 1'b0;         // mapper 71: its screen (bit 4)
    reg [3:0] chr0 = 4'd0;           // mapper 34 (NINA-001): $7FFE, 4 KB at $0000
    reg [3:0] chr1 = 4'd1;           // mapper 34 (NINA-001): $7FFF, 4 KB at $1000

    wire rom_area = ~cpu_ce;                                // $8000-$FFFF
    wire ram_area =  cpu_ce & (cpu_addr[14:13] == 2'b11);   // $6000-$7FFF

    always @(negedge mclk) begin
        if (rst) begin
            bank <= 8'd0;  fh_on <= 1'b0;  fh_scr <= 1'b0;  chr0 <= 4'd0;  chr1 <= 4'd1;
        end else if (MAPPER == 34 && ram_area && !cpu_rw && cpu_addr[12:2] == 11'h7FF) begin
            case (cpu_addr[1:0])                         // NINA-001: $7FFD-$7FFF
                2'd1: bank <= { 7'd0, cpu_dat[0] };
                2'd2: chr0 <= cpu_dat[3:0];
                2'd3: chr1 <= cpu_dat[3:0];
                default: ;
            endcase
        end else if (rom_area && !cpu_rw) begin
            if (MAPPER != 71 || cpu_addr[14])            // 71: bank at $C000-$FFFF
                bank <= cpu_dat;
            if (MAPPER == 71 && cpu_addr[14:12] == 3'b001) begin   // 71: $9000-$9FFF
                fh_on  <= 1'b1;
                fh_scr <= cpu_dat[4];
            end
        end
    end

    // ---------------------------------------------------------------- PRG
    always @* begin
        if (!rom_area)
            prg_a = { 6'b000000, cpu_addr[12:10] };          // PRG RAM, 8 KB
        else if (MAPPER == 2)                                // UxROM
            prg_a = { (cpu_addr[14] ? 5'b11111 : bank[4:0]), cpu_addr[13:10] };
        else if (MAPPER == 71)                               // Camerica
            prg_a = { (cpu_addr[14] ? 5'b11111 : { 1'b0, bank[3:0] }), cpu_addr[13:10] };
        else if (MAPPER == 7)                                // AxROM: 32 KB
            prg_a = { bank[3:0], cpu_addr[14:10] };
        else if (MAPPER == 66)                               // GxROM: 32 KB
            prg_a = { 2'b00, bank[5:4], cpu_addr[14:10] };
        else if (MAPPER == 11 || MAPPER == 34)               // Color Dreams / 34: 32 KB
            prg_a = { 2'b00, bank[1:0], cpu_addr[14:10] };
        else                                                 // CNROM: fixed
            prg_a = { 4'b0000, cpu_addr[14:10] };
    end
    assign prg_rom = rom_area;
    assign prg_ram = ram_area & m2;
    assign prg_wr  = ram_area & m2 & ~cpu_rw;

    // ---------------------------------------------------------------- CHR
    // CNROM / GxROM: 8 KB CHR bank; UxROM / AxROM / Camerica: 8 KB CHR RAM
    assign chr_a   = (MAPPER == 3)  ? { bank[5:0], ppu_addr[12:10] } :
                     (MAPPER == 66) ? { 4'b0000, bank[1:0], ppu_addr[12:10] } :
                     (MAPPER == 11) ? { 2'b00, bank[7:4], ppu_addr[12:10] } :
                     (MAPPER == 34) ? { 3'b000, (ppu_addr[12] ? chr1 : chr0), ppu_addr[11:10] } :
                                      { 6'b000000, ppu_addr[12:10] };
    assign chr_sel = ~ppu_addr[13];
    assign chr_wr  = chr_is_ram & ~ppu_addr[13] & ~ppu_wr;

    // ---------------------------------------------------------------- mirroring
    assign ciram_a10 = (MAPPER == 7) ? bank[4] :                 // AxROM: one screen
                       (MAPPER == 71 && fh_on) ? fh_scr :          // Fire Hawk: one screen
                       map_cfg[0] ? ppu_addr[10] : ppu_addr[11];   // header
    assign ciram_sel = ppu_addr[13];

    assign irq = 1'b0;

endmodule
