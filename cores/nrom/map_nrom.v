// n8-open: mapper 0 (NROM) for the EverDrive N8 clone.
//
// PRG: 16 or 32 KB at $8000-$FFFF. A 16 KB game appears twice because the
//      menu sets the PRG size mask (reg $84) so that A14 is forced low.
// PRG RAM: optional 8 KB at $6000-$7FFF (Family BASIC style boards).
// CHR: 8 KB ROM (read-only) or RAM (writable when reg $85 bit 7 is set).
// Mirroring: map_cfg[0] = 1 -> vertical (CIRAM A10 = PPU A10),
//            map_cfg[0] = 0 -> horizontal (CIRAM A10 = PPU A11).
//
// Game data sits at offset 0 in PRG and CHR RAM, where the menu loads it.

module map_nrom (
    input         m2,
    input  [14:0] cpu_addr,
    input         cpu_ce,        // /ROMSEL
    input         cpu_rw,
    input  [13:0] ppu_addr,
    input         ppu_wr,        // /WR
    input         chr_is_ram,
    input  [6:0]  map_cfg,

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

    wire rom_area = ~cpu_ce;                                // $8000-$FFFF
    wire ram_area =  cpu_ce & (cpu_addr[14:13] == 2'b11);   // $6000-$7FFF

    // ROM: A10-A14 from the CPU; RAM: 8 KB at offset 0 of the save SRAM
    assign prg_a   = rom_area ? { 4'b0000, cpu_addr[14:10] } : { 6'b000000, cpu_addr[12:10] };
    assign prg_rom = rom_area;
    assign prg_ram = ram_area & m2;
    assign prg_wr  = ram_area & m2 & ~cpu_rw;

    assign chr_a   = { 6'b000000, ppu_addr[12:10] };
    assign chr_sel = ~ppu_addr[13];
    assign chr_wr  = chr_is_ram & ~ppu_addr[13] & ~ppu_wr;

    assign ciram_a10 = map_cfg[0] ? ppu_addr[10] : ppu_addr[11];
    assign ciram_sel = ppu_addr[13];

    assign irq = 1'b0;

endmodule
