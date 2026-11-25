// n8-open: testbench for the simple discrete mappers (map_simple.v), Icarus:
//   iverilog -g2005 -Ptb_simple.M=2 -o tb_simple tb_simple.v ../nrom/*.v
// M is a parameter of this (root) module, so -P reaches it; the DUT gets it
// as MAPPER. Checks per mapper below (UxROM now; CNROM/AxROM/GxROM later).
`timescale 1ns/1ps

module tb_simple;
    parameter M = 2;

    reg clk = 0;
    always #10 clk = ~clk;

    reg  [15:0] a = 16'h0000;
    reg         rw = 1;
    reg         m2 = 0;
    reg  [7:0]  dout = 8'h00;
    reg         drive = 0;
    wire [7:0]  cpu_dat = drive ? dout : 8'hzz;
    reg  [13:0] pa = 14'h0000;
    reg         ppu_rd = 1, ppu_wr = 1;
    wire [7:0]  ppu_dat;

    wire [8:0] prg_map, chr_map;
    wire prg_ce, prg_oe, prg_we, chr_ce, chr_oe, chr_we, ram_ce, ram_oe, ram_we;
    wire ppu_ciram_ce, ppu_ciram_a10, ppu_dir, ppu_ex, cpu_irq, cpu_exp, max0, max1;

    n8_top #(.MAPPER(M)) dut (
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
    reg [8:0] s_prg_map, s_chr_map;
    reg s_prg_ce, s_prg_we, s_ram_ce, s_a10;

    task cycle(input [15:0] addr, input wr, input [7:0] d);
        begin
            m2 = 0; a = addr; rw = ~wr; dout = d; drive = wr;
            #280;
            m2 = 1;
            #240;
            s_prg_map = prg_map; s_prg_ce = prg_ce; s_prg_we = prg_we;
            s_ram_ce = ram_ce; s_a10 = ppu_ciram_a10; s_chr_map = chr_map;
            #40;
            m2 = 0;
            #10;
            drive = 0;
        end
    endtask
    task rd(input [15:0] addr);  begin cycle(addr, 0, 8'h00); end endtask
    task wr(input [15:0] addr, input [7:0] d);  begin cycle(addr, 1, d); rd(16'h0000); end endtask
    task reg_w(input [7:0] idx, input [7:0] v);  begin wr(16'h4400, idx); wr(16'h4401, v); end endtask

    task check(input [255:0] what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                $display("FAIL %0s: got %0h want %0h", what, got, want);
            end
        end
    endtask

    // 16 KB PRG bank seen by a CPU read (prg_map[8:4] = A14-A18)
    task prg16(input [15:0] addr, input [4:0] want, input [255:0] what);
        begin rd(addr); check(what, s_prg_map[8:4], want); check({what, " /CE"}, s_prg_ce, 0); end
    endtask
    task a10_at(input [13:0] addr, input want, input [255:0] what);
        begin pa = addr; #20; rd(16'h0000); check(what, s_a10, want); end
    endtask

    // menu mode again (the M2 watchdog does this on hardware), new setup
    task setup(input [7:0] prg_mask, input [7:0] chr_cfg, input [7:0] cfg);
        begin
            force dut.osmap.map_idx = 8'hFF; rd(16'h0000); release dut.osmap.map_idx;
            reg_w(8'h84, prg_mask);
            reg_w(8'h85, chr_cfg);
            reg_w(8'h86, cfg);
            reg_w(8'h83, M);
        end
    endtask

    initial begin
        repeat (20) rd(16'h0000);
        reg_w(8'h88, 8'h00);

        if (M == 2) begin
            // ---- UxROM: 128 KB PRG (8 x 16 KB), 8 KB CHR RAM, vertical
            setup(8'h07, 8'h80, 8'h01);
            prg16(16'h8000, 5'd0, "UxROM power-on $8000 = bank 0");
            prg16(16'hC000, 5'd7, "UxROM $C000 = last bank");
            wr(16'h8000, 8'h05);
            prg16(16'h8000, 5'd5, "UxROM bank 5");
            prg16(16'hFFFC, 5'd7, "UxROM reset vector stays in the last bank");
            wr(16'hC123, 8'h03);                     // any address in $8000-$FFFF
            prg16(16'hBFFF, 5'd3, "UxROM write at $C123 selects bank 3");
            wr(16'h8000, 8'h09);                     // beyond 128 KB: masked
            prg16(16'h8000, 5'd1, "UxROM bank 9 & 7 = 1 (128 KB)");
            cycle(16'h8000, 1, 8'h02);
            check("UxROM: games never write PRG RAM", s_prg_we, 1); rd(16'h0000);
            a10_at(14'h2400, 1, "UxROM vertical: $2400 -> A10 = 1");
            a10_at(14'h2800, 0, "UxROM vertical: $2800 -> A10 = 0");
            pa = 14'h1C00; #20; rd(16'h0000);
            check("UxROM CHR RAM: 8 KB, no banking", s_chr_map, 9'd7);
            pa = 14'h0400; ppu_wr = 0; #50;
            check("UxROM CHR RAM writable", chr_we, 0);
            ppu_wr = 1; #50;
            rd(16'h6000); check("UxROM: PRG RAM at $6000", s_ram_ce, 1);
            // ---- 256 KB (UOROM), horizontal
            setup(8'h0F, 8'h80, 8'h00);
            prg16(16'hC000, 5'd15, "UxROM 256 KB: last bank 15");
            wr(16'h8000, 8'h0E);
            prg16(16'h8000, 5'd14, "UxROM 256 KB: bank 14");
            a10_at(14'h2400, 0, "UxROM horizontal: $2400 -> A10 = 0");
            a10_at(14'h2800, 1, "UxROM horizontal: $2800 -> A10 = 1");
            // ---- 512 KB (homebrew: 5 bank bits)
            setup(8'h1F, 8'h80, 8'h00);
            prg16(16'hC000, 5'd31, "UxROM 512 KB: last bank 31");
            wr(16'h8000, 8'h1E);
            prg16(16'h8000, 5'd30, "UxROM 512 KB: bank 30 (5th bit)");
            // ---- back to the menu: register cleared
            setup(8'h0F, 8'h80, 8'h00);
            prg16(16'h8000, 5'd0, "UxROM: bank cleared by the menu");
        end

        $display("mapper %0d: %0d checks, %0d failed", M, checks, fails);
        if (fails == 0) $display("PASS");
        $finish;
    end
endmodule
