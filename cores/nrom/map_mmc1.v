// n8-open: mapper 1 (MMC1: SxROM boards) for the EverDrive N8 clone.
//
// Written from the public MMC1 documentation (behaviour), not from any
// existing HDL.
//
// CPU writes to $8000-$FFFF go through a 5-bit serial port, LSB first:
//   bit 7 set   -> reset the shift register, control |= $0C (PRG mode 3)
//   5th write   -> value goes to the register selected by A14:A13 of that write
//                    $8000 control   bits 1:0 mirroring, 3:2 PRG mode, 4 CHR mode
//                    $A000 CHR bank 0 (bit 4 also = PRG A18 on SUROM, 512 KB)
//                    $C000 CHR bank 1
//                    $E000 PRG bank
// A write in the CPU cycle directly after another write to $8000-$FFFF is
// ignored, as on the real chip (read-modify-write instructions write twice).
//
// PRG modes (16 KB banks at $8000 / $C000):
//   0,1  32 KB: {prg[3:1], A14}
//   2    $8000 = bank 0, $C000 = prg[3:0]
//   3    $8000 = prg[3:0], $C000 = last bank (power-on state)
// CHR: control bit 4 = 0 -> one 8 KB bank {chr0[4:1], A12}; 1 -> two 4 KB banks.
// Mirroring: 0 one-screen low, 1 one-screen high, 2 vertical, 3 horizontal.
// PRG RAM: 8 KB at $6000-$7FFF (save SRAM offset 0); the MMC1B "RAM
// disable" bit (prg[4]) is ignored for compatibility.
// Oversized bank numbers are cut down by the size masks in top.v
// (regs $84/$85), so smaller ROMs mirror correctly.

module map_mmc1 (
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
    output reg     ciram_a10,
    output         ciram_sel,
    output         irq
);

    reg [4:0] control = 5'b01100;
    reg [4:0] chr0    = 5'd0;
    reg [4:0] chr1    = 5'd0;
    reg [4:0] prg     = 5'd0;
    reg [4:0] sr      = 5'd0;    // shift register
    reg [2:0] cnt     = 3'd0;    // bits received
    reg       last_wr = 1'b0;    // previous CPU cycle wrote to $8000-$FFFF

    wire rom_area = ~cpu_ce;                                // $8000-$FFFF
    wire ram_area =  cpu_ce & (cpu_addr[14:13] == 2'b11);   // $6000-$7FFF
    wire port_wr  =  rom_area & ~cpu_rw;

    wire [4:0] value = { cpu_dat[0], sr[4:1] };             // after the 5th bit

    always @(negedge mclk) begin
        if (rst) begin
            control <= 5'b01100;
            chr0    <= 5'd0;
            chr1    <= 5'd0;
            prg     <= 5'd0;
            sr      <= 5'd0;
            cnt     <= 3'd0;
            last_wr <= 1'b0;
        end else begin
            last_wr <= port_wr;
            if (port_wr & ~last_wr) begin
                if (cpu_dat[7]) begin
                    sr      <= 5'd0;
                    cnt     <= 3'd0;
                    control <= control | 5'b01100;
                end else if (cnt == 3'd4) begin
                    case (cpu_addr[14:13])
                        2'd0: control <= value;
                        2'd1: chr0    <= value;
                        2'd2: chr1    <= value;
                        2'd3: prg     <= value;
                    endcase
                    sr  <= 5'd0;
                    cnt <= 3'd0;
                end else begin
                    sr  <= { cpu_dat[0], sr[4:1] };
                    cnt <= cnt + 3'd1;
                end
            end
        end
    end

    // ---------------------------------------------------------------- PRG
    reg [3:0] bank16;
    always @* begin
        case (control[3:2])
            2'd0, 2'd1: bank16 = { prg[3:1], cpu_addr[14] };
            2'd2:       bank16 = cpu_addr[14] ? prg[3:0] : 4'd0;
            default:    bank16 = cpu_addr[14] ? 4'hF : prg[3:0];
        endcase
    end

    assign prg_a   = rom_area ? { chr0[4], bank16, cpu_addr[13:10] }
                              : { 6'b000000, cpu_addr[12:10] };   // PRG RAM, 8 KB
    assign prg_rom = rom_area;
    assign prg_ram = ram_area & m2;
    assign prg_wr  = ram_area & m2 & ~cpu_rw;

    // ---------------------------------------------------------------- CHR
    wire [4:0] bank4 = control[4] ? (ppu_addr[12] ? chr1 : chr0)
                                  : { chr0[4:1], ppu_addr[12] };
    assign chr_a   = { 2'b00, bank4, ppu_addr[11:10] };
    assign chr_sel = ~ppu_addr[13];
    assign chr_wr  = chr_is_ram & ~ppu_addr[13] & ~ppu_wr;

    // ---------------------------------------------------------------- mirroring
    always @* begin
        case (control[1:0])
            2'd0: ciram_a10 = 1'b0;
            2'd1: ciram_a10 = 1'b1;
            2'd2: ciram_a10 = ppu_addr[10];
            default: ciram_a10 = ppu_addr[11];
        endcase
    end
    assign ciram_sel = ppu_addr[13];

    assign irq = 1'b0;

endmodule
