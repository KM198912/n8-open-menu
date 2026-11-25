// n8-open: simple discrete-logic mappers for the EverDrive N8 clone, one per
// build (parameter MAPPER, folded at synthesis):
//   2  UxROM   16 KB at $8000 switchable, last 16 KB fixed at $C000, CHR RAM
// (CNROM 3, AxROM 7, GxROM 66 to follow as further branches.)
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

    wire rom_area = ~cpu_ce;                                // $8000-$FFFF
    wire ram_area =  cpu_ce & (cpu_addr[14:13] == 2'b11);   // $6000-$7FFF

    always @(negedge mclk) begin
        if (rst)
            bank <= 8'd0;
        else if (rom_area && !cpu_rw)
            bank <= cpu_dat;
    end

    // ---------------------------------------------------------------- PRG
    always @* begin
        if (!rom_area)
            prg_a = { 6'b000000, cpu_addr[12:10] };          // PRG RAM, 8 KB
        else if (MAPPER == 2)                                // UxROM
            prg_a = { (cpu_addr[14] ? 5'b11111 : bank[4:0]), cpu_addr[13:10] };
        else
            prg_a = { 4'b0000, cpu_addr[14:10] };
    end
    assign prg_rom = rom_area;
    assign prg_ram = ram_area & m2;
    assign prg_wr  = ram_area & m2 & ~cpu_rw;

    // ---------------------------------------------------------------- CHR
    assign chr_a   = { 6'b000000, ppu_addr[12:10] };         // UxROM: 8 KB CHR RAM
    assign chr_sel = ~ppu_addr[13];
    assign chr_wr  = chr_is_ram & ~ppu_addr[13] & ~ppu_wr;

    // ---------------------------------------------------------------- mirroring
    assign ciram_a10 = map_cfg[0] ? ppu_addr[10] : ppu_addr[11];
    assign ciram_sel = ppu_addr[13];

    assign irq = 1'b0;

endmodule
