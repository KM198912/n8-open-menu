// n8-open: testbench for the NROM/MMC1 core (n8_top), run with Icarus Verilog:
//   iverilog -g2005 -o tb_mmc1 tb_mmc1.v ../nrom/top.v ../nrom/osmap.v ../nrom/map_nrom.v ../nrom/map_mmc1.v
//   vvp tb_mmc1
// Drives NES CPU bus cycles (M2 low: address/RW, M2 high: data, registers on
// the falling edge) and checks the chip-select and address outputs.
`timescale 1ns/1ps

module tb_mmc1;
    // board clock 50 MHz
    reg clk = 0;
    always #10 clk = ~clk;

    // CPU bus
    reg  [15:0] a = 16'h0000;
    reg         rw = 1;
    reg         m2 = 0;
    reg  [7:0]  dout = 8'h00;
    reg         drive = 0;
    wire [7:0]  cpu_dat = drive ? dout : 8'hzz;
    // PPU bus
    reg  [13:0] pa = 14'h0000;
    reg         ppu_rd = 1, ppu_wr = 1;
    wire [7:0]  ppu_dat;

    wire [8:0] prg_map, chr_map;
    wire prg_ce, prg_oe, prg_we, chr_ce, chr_oe, chr_we, ram_ce, ram_oe, ram_we;
    wire ppu_ciram_ce, ppu_ciram_a10, ppu_dir, ppu_ex, cpu_irq, cpu_exp, max0, max1;

    n8_top #(.MAPPER(1)) dut (
        .cpu_dat(cpu_dat), .cpu_addr(a[14:0]), .cpu_ce(~a[15]), .cpu_rw(rw),
        .cpu_m2(m2), .mclk(m2), .cpu_irq(cpu_irq), .cpu_exp(cpu_exp),
        .ppu_dat(ppu_dat), .ppu_addr(pa), .ppu_rd(ppu_rd), .ppu_wr(ppu_wr),
        .ppu_ciram_ce(ppu_ciram_ce), .ppu_ciram_a10(ppu_ciram_a10),
        .ppu_dir(ppu_dir), .ppu_ex(ppu_ex),
        .prg_map(prg_map), .prg_ce(prg_ce), .prg_oe(prg_oe), .prg_we(prg_we),
        .chr_map(chr_map), .chr_ce(chr_ce), .chr_oe(chr_oe), .chr_we(chr_we),
        .ram_ce(ram_ce), .ram_oe(ram_oe), .ram_we(ram_we),
        .clk(clk), .max0(max0), .max1(max1), .max2(1'b1)
    );

    integer fails = 0, checks = 0;

    // values captured late in the M2-high phase of the last cycle
    reg [8:0] s_prg_map, s_chr_map;
    reg s_prg_ce, s_ram_ce, s_ram_we, s_prg_we, s_a10;

    // one CPU cycle: 280 ns M2 low, 280 ns M2 high
    task cycle(input [15:0] addr, input wr, input [7:0] d);
        begin
            m2 = 0; a = addr; rw = ~wr; dout = d; drive = wr;
            #280;
            m2 = 1;
            #240;
            s_prg_map = prg_map; s_prg_ce = prg_ce; s_ram_ce = ram_ce;
            s_ram_we = ram_we; s_prg_we = prg_we; s_a10 = ppu_ciram_a10;
            s_chr_map = chr_map;
            #40;
            m2 = 0;
            #10;                    // data hold after the falling edge (6502)
            drive = 0;
        end
    endtask

    task rd(input [15:0] addr);  begin cycle(addr, 0, 8'h00); end endtask
    task wr(input [15:0] addr, input [7:0] d);  begin cycle(addr, 1, d); rd(16'h0000); end endtask

    // menu-mode register write through $4400/$4401
    task reg_w(input [7:0] idx, input [7:0] v);
        begin wr(16'h4400, idx); wr(16'h4401, v); end
    endtask

    // MMC1 serial write: 5 bits LSB first, each followed by a read cycle
    task mmc1_w(input [15:0] addr, input [4:0] v);
        integer i;
        begin
            for (i = 0; i < 5; i = i + 1)
                wr(addr, {7'b0, v[i]});
        end
    endtask

    task check(input [255:0] what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                $display("FAIL %0s: got %0h want %0h", what, got, want);
            end
        end
    endtask

    // 16 KB PRG bank seen by a CPU read at addr (prg_map[8:4] = A14-A18)
    task prg_bank(input [15:0] addr, input [4:0] want, input [255:0] what);
        begin rd(addr); check(what, s_prg_map[8:4], want); check({what, " /CE"}, s_prg_ce, 0); end
    endtask

    task ppu_at(input [13:0] addr);  begin pa = addr; #20; end endtask

    initial begin
        repeat (20) rd(16'h0000);            // let the M2 watchdog settle

        // ---- set up like the loader: 128 KB PRG, 128 KB CHR ROM, mapper 1
        reg_w(8'h84, 8'h07);                 // PRG mask: 8 x 16 KB
        reg_w(8'h85, 8'h0F);                 // CHR mask: 16 x 8 KB, ROM
        reg_w(8'h86, 8'h00);
        reg_w(8'h88, 8'h00);
        reg_w(8'h83, 8'h01);                 // -> game mode, MMC1

        // power-on state: PRG mode 3 -> $8000 = bank 0, $C000 = last bank (7)
        prg_bank(16'h8000, 5'd0, "power-on $8000");
        prg_bank(16'hC000, 5'd7, "power-on $C000 last bank");

        // PRG bank register = 5 (mode 3: switchable at $8000)
        mmc1_w(16'hE000, 5'd5);
        prg_bank(16'h8000, 5'd5, "mode 3 $8000 = prg");
        prg_bank(16'hC000, 5'd7, "mode 3 $C000 fixed");

        // control = mode 2 (fixed first) + vertical mirroring: %01010
        mmc1_w(16'h8000, 5'b01010);
        prg_bank(16'h8000, 5'd0, "mode 2 $8000 fixed 0");
        prg_bank(16'hC000, 5'd5, "mode 2 $C000 = prg");
        ppu_at(14'h2400); rd(16'h0000); check("vertical $2400 -> A10=1", s_a10, 1);
        ppu_at(14'h2800); rd(16'h0000); check("vertical $2800 -> A10=0", s_a10, 0);

        // control = 32 KB mode + horizontal: %00011 ; prg 5 -> banks 4/5
        mmc1_w(16'h8000, 5'b00011);
        prg_bank(16'h8000, 5'd4, "32K $8000");
        prg_bank(16'hC000, 5'd5, "32K $C000");
        ppu_at(14'h2400); rd(16'h0000); check("horizontal $2400 -> A10=0", s_a10, 0);
        ppu_at(14'h2800); rd(16'h0000); check("horizontal $2800 -> A10=1", s_a10, 1);

        // one-screen high: %00001
        mmc1_w(16'h8000, 5'b00001);
        ppu_at(14'h2000); rd(16'h0000); check("one-screen high", s_a10, 1);

        // reset bit: control |= $0C -> mode 3 again ($C000 = last bank)
        wr(16'h8000, 8'h80);
        prg_bank(16'hC000, 5'd7, "reset bit -> mode 3");

        // shift register restarts after the reset bit: 2 bits, reset, then 5 bits
        wr(16'hE000, 8'h01); wr(16'hE000, 8'h01);
        wr(16'hE000, 8'h80);
        mmc1_w(16'hE000, 5'd2);
        prg_bank(16'h8000, 5'd2, "shift reset mid-sequence");

        // consecutive-cycle writes: the second one is ignored (RMW double write)
        // write bits 1,1 back to back (counts as one), then 4 more single writes
        cycle(16'hE000, 1, 8'h01); cycle(16'hE000, 1, 8'h00); rd(16'h0000);
        wr(16'hE000, 8'h01); wr(16'hE000, 8'h00); wr(16'hE000, 8'h00); wr(16'hE000, 8'h00);
        prg_bank(16'h8000, 5'd3, "consecutive write ignored");

        // CHR: 4 KB mode (control bit 4), chr0 = 3, chr1 = 9
        mmc1_w(16'h8000, 5'b11111);
        mmc1_w(16'hA000, 5'd3);
        mmc1_w(16'hC000, 5'd9);
        ppu_at(14'h0000); rd(16'h0000); check("4K CHR $0000 -> bank 3", s_chr_map[8:2], 3);
        ppu_at(14'h1000); rd(16'h0000); check("4K CHR $1000 -> bank 9", s_chr_map[8:2], 9);
        // 8 KB mode: chr0 = 6 -> banks 6/7
        mmc1_w(16'h8000, 5'b01111);
        mmc1_w(16'hA000, 5'd6);
        ppu_at(14'h0000); rd(16'h0000); check("8K CHR $0000 -> bank 6", s_chr_map[8:2], 6);
        ppu_at(14'h1000); rd(16'h0000); check("8K CHR $1000 -> bank 7", s_chr_map[8:2], 7);

        // PRG RAM at $6000: save SRAM selected (active high), PRG SRAM not
        rd(16'h6123);
        check("PRG RAM read: ram_ce", s_ram_ce, 1);
        check("PRG RAM read: prg_ce off", s_prg_ce, 1);
        cycle(16'h7456, 1, 8'h55);
        check("PRG RAM write: ram_we", s_ram_we, 0);
        check("PRG RAM write: ram_ce", s_ram_ce, 1);
        rd(16'h0000);
        rd(16'h8000);
        check("ROM read: ram_ce off", s_ram_ce, 0);
        check("ROM read: prg_we off", s_prg_we, 1);

        // SUROM: 512 KB PRG (mask 31), chr0 bit 4 selects the upper 256 KB
        // (needs menu mode again: the M2 watchdog would do this on reset;
        // here: a new configuration is simulated by forcing map_idx)
        force dut.osmap.map_idx = 8'hFF; rd(16'h0000); release dut.osmap.map_idx;
        reg_w(8'h84, 8'h1F);
        reg_w(8'h83, 8'h01);
        prg_bank(16'hC000, 5'd15, "512K power-on last bank of lower half");
        mmc1_w(16'hA000, 5'b10000);
        prg_bank(16'hC000, 5'd31, "512K chr0 bit 4 -> upper half");

        $display("%0d checks, %0d failed", checks, fails);
        if (fails == 0) $display("PASS");
        $finish;
    end
endmodule
