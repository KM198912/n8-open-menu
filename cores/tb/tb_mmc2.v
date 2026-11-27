// n8-open: testbench for MMC2 / MMC4 (map_mmc2.v), Icarus:
//   iverilog -g2005 -Ptb_mmc2.M=9 -o tb_mmc2 tb_mmc2.v ../nrom/*.v   (MMC2)
//   iverilog -g2005 -Ptb_mmc2.M=10 -o tb_mmc2 tb_mmc2.v ../nrom/*.v  (MMC4)
// CPU bus cycles as in tb_simple; PPU reads with a real /RD pulse (the
// latches switch at its end).
`timescale 1ns/1ps

module tb_mmc2;
    parameter M = 9;

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
    reg [8:0] s_prg_map, s_chr;
    reg s_prg_ce, s_prg_we, s_ram_ce, s_ram_we, s_a10;

    task cycle(input [15:0] addr, input wr, input [7:0] d);
        begin
            m2 = 0; a = addr; rw = ~wr; dout = d; drive = wr;
            #280;
            m2 = 1;
            #240;
            s_prg_map = prg_map; s_prg_ce = prg_ce; s_prg_we = prg_we;
            s_ram_ce = ram_ce; s_ram_we = ram_we; s_a10 = ppu_ciram_a10;
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

    // PPU read with /RD: s_chr = the CHR address bits during the read
    task ppu_read(input [13:0] addr);
        begin
            pa = addr; #120;
            ppu_rd = 0; #100;
            s_chr = chr_map;
            #86 ppu_rd = 1; #60;
            rd(16'h0000);              // the CPU keeps running (M2 watchdog)
        end
    endtask
    // 4 KB CHR bank seen by a PPU read (chr_map[8:2] = A12-A18)
    task chr4(input [13:0] addr, input [6:0] want, input [255:0] what);
        begin ppu_read(addr); check(what, s_chr[8:2], want); end
    endtask
    task prg8(input [15:0] addr, input [5:0] want, input [255:0] what);
        begin rd(addr); check(what, s_prg_map[8:3], want); check({what, " /CE"}, s_prg_ce, 0); end
    endtask
    task prg16(input [15:0] addr, input [4:0] want, input [255:0] what);
        begin rd(addr); check(what, s_prg_map[8:4], want); check({what, " /CE"}, s_prg_ce, 0); end
    endtask
    task a10_at(input [13:0] addr, input want, input [255:0] what);
        begin pa = addr; #20; rd(16'h0000); check(what, s_a10, want); end
    endtask
    task setup(input [7:0] prg_mask, input [7:0] chr_cfg);
        begin
            force dut.osmap.map_idx = 8'hFF; rd(16'h0000); release dut.osmap.map_idx;
            reg_w(8'h84, prg_mask);
            reg_w(8'h85, chr_cfg);
            reg_w(8'h86, 8'h00);
            reg_w(8'h83, M);
        end
    endtask

    initial begin
        repeat (20) rd(16'h0000);
        reg_w(8'h88, 8'h00);

        if (M == 9) begin
            // ---- MMC2: 128 KB PRG (16 x 8 KB), 128 KB CHR ROM
            setup(8'h07, 8'h0F);
            prg8(16'h8000, 6'd0,  "MMC2 power-on: $8000 = bank 0");
            prg8(16'hA000, 6'd13, "MMC2 $A000 = third-last 8 KB bank");
            prg8(16'hC000, 6'd14, "MMC2 $C000 = second-last");
            prg8(16'hE000, 6'd15, "MMC2 $E000 = last");
            wr(16'hA000, 8'h05);
            prg8(16'h9FFF, 6'd5,  "MMC2 $A000 = 5 -> $8000-$9FFF bank 5");
            prg8(16'hA000, 6'd13, "MMC2 $A000 still fixed");
            wr(16'hAFFF, 8'h0B);
            prg8(16'h8000, 6'd11, "MMC2 write at $AFFF (whole window)");
            rd(16'h6000); check("MMC2: no PRG RAM at $6000", s_ram_ce, 0);
            cycle(16'h6000, 1, 8'h55); check("MMC2: no PRG RAM write", s_ram_we, 1); rd(16'h0000);
        end else begin
            // ---- MMC4: 256 KB PRG (16 x 16 KB), 128 KB CHR ROM
            setup(8'h0F, 8'h0F);
            prg16(16'h8000, 5'd0,  "MMC4 power-on: $8000 = bank 0");
            prg16(16'hC000, 5'd15, "MMC4 $C000 = last 16 KB");
            wr(16'hA000, 8'h09);
            prg16(16'hBFFF, 5'd9,  "MMC4 $A000 = 9 -> $8000-$BFFF bank 9");
            prg16(16'hFFFC, 5'd15, "MMC4 reset vector in the last bank");
            rd(16'h6000); check("MMC4: PRG RAM at $6000", s_ram_ce, 1);
            cycle(16'h7FFF, 1, 8'h55); check("MMC4: PRG RAM writable", s_ram_we, 0); rd(16'h0000);
        end

        // ---- CHR banks and latches (both)
        wr(16'hB000, 8'h11); wr(16'hC000, 8'h12); wr(16'hD000, 8'h13); wr(16'hE000, 8'h14);
        chr4(14'h0000, 7'h12, "power-on latch 0 = $FE: $0000 from $C000");
        chr4(14'h1000, 7'h14, "power-on latch 1 = $FE: $1000 from $E000");
        chr4(14'h0FD8, 7'h12, "read of $0FD8 itself: still the old bank");
        chr4(14'h0000, 7'h11, "after $0FD8: latch 0 = $FD -> $B000");
        chr4(14'h1000, 7'h14, "latch 1 unchanged by $0FD8");
        chr4(14'h0FE8, 7'h11, "read of $0FE8 itself: old bank");
        chr4(14'h0ABC, 7'h12, "after $0FE8: latch 0 = $FE -> $C000");
        chr4(14'h0FD9, 7'h12, "$0FD9: old bank either way");
        if (M == 9)
            chr4(14'h0000, 7'h12, "MMC2: $0FD9 does not switch latch 0 (exactly $0FD8)");
        else
            chr4(14'h0000, 7'h11, "MMC4: $0FD9 switches latch 0 (range $0FD8-$0FDF)");
        chr4(14'h0FE8, 7'h11 + (M == 9), "back to $FE");
        chr4(14'h0FEF, 7'h12, "$0FEF");
        chr4(14'h0000, 7'h12, "after $0FEF: $FE either way");
        chr4(14'h1FDC, 7'h14, "read of $1FDC: old bank");
        chr4(14'h1000, 7'h13, "after $1FDC: latch 1 = $FD (range) -> $D000");
        chr4(14'h0000, 7'h12, "latch 0 unchanged by $1FDC");
        chr4(14'h1FEF, 7'h13, "read of $1FEF: old bank");
        chr4(14'h1F00, 7'h14, "after $1FEF: latch 1 = $FE -> $E000");
        chr4(14'h1FD7, 7'h14, "$1FD7: no trigger");
        chr4(14'h1000, 7'h14, "after $1FD7: unchanged");
        chr4(14'h1FE0, 7'h14, "$1FE0: no trigger");
        chr4(14'h0FD0, 7'h12, "$0FD0: no trigger");
        ppu_read(14'h2FD8); ppu_read(14'h3FD8);
        chr4(14'h0000, 7'h12, "nametable reads at $2FD8/$3FD8 do not trigger");
        chr4(14'h1000, 7'h14, "... latch 1 neither");
        wr(16'hBFFF, 8'h1F);
        chr4(14'h0FD8, 7'h12, "set latch 0 = $FD");
        chr4(14'h0400, 7'h1F, "$B000 window: write at $BFFF, CHR A11-A10 from the PPU");
        check("CHR A11-A10 pass through ($0400 -> 01)", s_chr[1:0], 2'b01);

        // ---- mirroring
        wr(16'hF000, 8'h00);
        a10_at(14'h2400, 1, "$F000 = 0 vertical: $2400 -> A10 = 1");
        a10_at(14'h2800, 0, "vertical: $2800 -> A10 = 0");
        wr(16'hFFFF, 8'h01);
        a10_at(14'h2400, 0, "$F000 = 1 horizontal: $2400 -> A10 = 0");
        a10_at(14'h2800, 1, "horizontal: $2800 -> A10 = 1");

        // ---- back to the menu: registers and latches reset
        setup(8'h07, 8'h0F);
        chr4(14'h0000, 7'h00, "menu: CHR registers cleared");
        wr(16'hB000, 8'h01); wr(16'hC000, 8'h02);
        chr4(14'h0000, 7'h02, "menu: latch 0 back to $FE");
        a10_at(14'h2400, 1, "menu: mirroring back to vertical");

        $display("mapper %0d: %0d checks, %0d failed", M, checks, fails);
        if (fails == 0) $display("PASS");
        $finish;
    end
endmodule
