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
    reg s_prg_ce, s_prg_we, s_ram_ce, s_ram_we, s_a10;

    task cycle(input [15:0] addr, input wr, input [7:0] d);
        begin
            m2 = 0; a = addr; rw = ~wr; dout = d; drive = wr;
            #280;
            m2 = 1;
            #240;
            s_prg_map = prg_map; s_prg_ce = prg_ce; s_prg_we = prg_we;
            s_ram_ce = ram_ce; s_ram_we = ram_we; s_a10 = ppu_ciram_a10; s_chr_map = chr_map;
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
    // 8 KB CHR bank seen by a PPU read (chr_map[8:3] = A13-A18)
    task chr8(input [13:0] addr, input [5:0] want, input [255:0] what);
        begin pa = addr; #20; rd(16'h0000); check(what, s_chr_map[8:3], want); end
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

        if (M == 3) begin
            // ---- CNROM: 32 KB PRG (2 x 16 KB), 32 KB CHR ROM (4 x 8 KB), vertical
            setup(8'h01, 8'h03, 8'h01);
            prg16(16'h8000, 5'd0, "CNROM $8000 = PRG 16K bank 0");
            prg16(16'hC000, 5'd1, "CNROM $C000 = PRG 16K bank 1");
            chr8(14'h0000, 6'd0, "CNROM power-on CHR bank 0");
            wr(16'h8000, 8'h02);
            chr8(14'h0000, 6'd2, "CNROM CHR bank 2 at $0000");
            chr8(14'h1C00, 6'd2, "CNROM CHR bank 2 at $1C00 (8 KB)");
            prg16(16'hC000, 5'd1, "CNROM PRG unchanged by the write");
            wr(16'hE000, 8'h07);                      // beyond 32 KB CHR: masked
            chr8(14'h0400, 6'd3, "CNROM CHR bank 7 & 3 = 3");
            a10_at(14'h2400, 1, "CNROM vertical: $2400 -> A10 = 1");
            pa = 14'h0400; ppu_wr = 0; #50;
            check("CNROM: CHR ROM not writable", chr_we, 1);
            ppu_wr = 1; #50;
            // ---- 16 KB PRG (NROM-128 layout), 64 KB CHR, horizontal
            setup(8'h00, 8'h07, 8'h00);
            prg16(16'hC000, 5'd0, "CNROM 16 KB PRG mirrored at $C000");
            wr(16'h8000, 8'h05);
            chr8(14'h0000, 6'd5, "CNROM 64 KB CHR: bank 5");
            a10_at(14'h2800, 1, "CNROM horizontal: $2800 -> A10 = 1");
            setup(8'h00, 8'h07, 8'h00);
            chr8(14'h0000, 6'd0, "CNROM: CHR bank cleared by the menu");
        end

        if (M == 7) begin
            // ---- AxROM: 256 KB PRG (8 x 32 KB), CHR RAM
            setup(8'h0F, 8'h80, 8'h00);
            prg16(16'h8000, 5'd0, "AxROM power-on $8000 = 16K bank 0");
            prg16(16'hC000, 5'd1, "AxROM power-on $C000 = 16K bank 1 (32 KB bank 0)");
            a10_at(14'h2400, 0, "AxROM one-screen lower: $2400 -> A10 = 0");
            a10_at(14'h2C00, 0, "AxROM one-screen lower: $2C00 -> A10 = 0");
            wr(16'h8000, 8'h03);
            prg16(16'h8000, 5'd6, "AxROM 32 KB bank 3: $8000 = 16K bank 6");
            prg16(16'hFFFC, 5'd7, "AxROM 32 KB bank 3: $C000 = 16K bank 7");
            wr(16'hA000, 8'h13);                      // bit 4: upper nametable
            a10_at(14'h2000, 1, "AxROM one-screen upper: $2000 -> A10 = 1");
            a10_at(14'h2800, 1, "AxROM one-screen upper: $2800 -> A10 = 1");
            prg16(16'h8000, 5'd6, "AxROM bit 4 does not change the PRG bank");
            wr(16'h8000, 8'h0F);                      // 32 KB bank 15: masked to 7
            prg16(16'h8000, 5'd14, "AxROM bank 15 & 7 = 7 (256 KB)");
            pa = 14'h1C00; #20; rd(16'h0000);
            check("AxROM CHR RAM: 8 KB, no banking", s_chr_map, 9'd7);
            pa = 14'h0400; ppu_wr = 0; #50;
            check("AxROM CHR RAM writable", chr_we, 0);
            ppu_wr = 1; #50;
            setup(8'h0F, 8'h80, 8'h00);
            prg16(16'h8000, 5'd0, "AxROM: bank cleared by the menu");
        end

        if (M == 66) begin
            // ---- GxROM: 128 KB PRG (4 x 32 KB), 32 KB CHR (4 x 8 KB), vertical
            setup(8'h07, 8'h03, 8'h01);
            prg16(16'h8000, 5'd0, "GxROM power-on PRG bank 0");
            chr8(14'h0000, 6'd0, "GxROM power-on CHR bank 0");
            wr(16'h8000, 8'h21);                      // PRG 2, CHR 1
            prg16(16'h8000, 5'd4, "GxROM PRG 32 KB bank 2: $8000 = 16K 4");
            prg16(16'hC000, 5'd5, "GxROM PRG 32 KB bank 2: $C000 = 16K 5");
            chr8(14'h1000, 6'd1, "GxROM CHR bank 1 from the same write");
            wr(16'hF000, 8'h33);                      // PRG 3, CHR 3
            prg16(16'hC000, 5'd7, "GxROM PRG bank 3: $C000 = 16K 7");
            chr8(14'h0000, 6'd3, "GxROM CHR bank 3");
            a10_at(14'h2400, 1, "GxROM vertical: $2400 -> A10 = 1");
            // SMB / Duck Hunt layout: 64 KB PRG, 16 KB CHR
            setup(8'h03, 8'h01, 8'h01);
            wr(16'h8000, 8'h11);
            prg16(16'h8000, 5'd2, "GxROM 64 KB: PRG bank 1 = 16K 2");
            chr8(14'h0000, 6'd1, "GxROM 16 KB CHR: bank 1");
            wr(16'h8000, 8'h33);                      // masked: PRG 1, CHR 1
            prg16(16'hC000, 5'd3, "GxROM 64 KB: PRG 3 & 1 = 1");
            chr8(14'h0000, 6'd1, "GxROM 16 KB CHR: 3 & 1 = 1");
            setup(8'h03, 8'h01, 8'h01);
            chr8(14'h0000, 6'd0, "GxROM: banks cleared by the menu");
        end

        if (M == 71) begin
            // ---- Camerica / Codemasters: 256 KB PRG (16 x 16 KB), 8 KB CHR RAM, vertical
            setup(8'h0F, 8'h80, 8'h01);
            prg16(16'h8000, 5'd0, "M71 power-on $8000 = bank 0");
            prg16(16'hC000, 5'd15, "M71 $C000 = last bank");
            wr(16'hC000, 8'h05);
            prg16(16'h8000, 5'd5, "M71 write at $C000 selects bank 5");
            prg16(16'hFFFC, 5'd15, "M71 reset vector stays in the last bank");
            wr(16'hFFFF, 8'h0B);
            prg16(16'hBFFF, 5'd11, "M71 write at $FFFF (whole $C000-$FFFF)");
            wr(16'h8000, 8'h00);                     // Micro Machines at start
            prg16(16'h8000, 5'd11, "M71 $8000 write does not change the bank");
            a10_at(14'h2400, 1, "M71 after $8000 = 0: still header vertical ($2400 -> 1)");
            a10_at(14'h2800, 0, "M71 vertical: $2800 -> 0");
            wr(16'hA000, 8'h03);
            prg16(16'h8000, 5'd11, "M71 $A000 write does not change the bank");
            pa = 14'h1C00; #20; rd(16'h0000);
            check("M71 CHR RAM: 8 KB, no banking", s_chr_map, 9'd7);
            wr(16'h9000, 8'h10);                     // Fire Hawk: one screen, upper
            a10_at(14'h2000, 1, "M71 $9000 bit 4 = 1: one screen upper ($2000)");
            a10_at(14'h2C00, 1, "M71 one screen upper ($2C00)");
            wr(16'h9FFF, 8'h00);
            a10_at(14'h2400, 0, "M71 $9FFF bit 4 = 0: one screen lower ($2400)");
            a10_at(14'h2800, 0, "M71 one screen lower ($2800)");
            prg16(16'h8000, 5'd11, "M71 $9000 writes do not change the bank");
            wr(16'h8000, 8'h10);
            a10_at(14'h2000, 0, "M71 $8000-$8FFF write ignored for mirroring");
            // ---- horizontal header, back to the menu
            setup(8'h0F, 8'h80, 8'h00);
            prg16(16'h8000, 5'd0, "M71: bank cleared by the menu");
            a10_at(14'h2400, 0, "M71 menu: one-screen mode cleared, header horizontal ($2400 -> 0)");
            a10_at(14'h2800, 1, "M71 horizontal: $2800 -> 1");
            setup(8'h1F, 8'h80, 8'h00);             // 512 KB mask: only the register limits
            wr(16'hC000, 8'h1F);
            prg16(16'h8000, 5'd15, "M71 bank register 4 bits: $1F -> 15 (512 KB mask)");
        end

        if (M == 11) begin
            // ---- Color Dreams: 128 KB PRG (8 x 16 KB), 128 KB CHR ROM (16 x 8 KB), vertical
            setup(8'h07, 8'h0F, 8'h01);
            prg16(16'h8000, 5'd0, "M11 power-on: PRG 32K bank 0");
            chr8(14'h0000, 6'd0, "M11 power-on: CHR bank 0");
            wr(16'h8000, 8'hA3);                     // CHR 10, lockout bits 0, PRG 3
            prg16(16'h8000, 5'd6, "M11 PRG bits 1:0 = 3 -> 16K 6");
            prg16(16'hC000, 5'd7, "M11 PRG 32K: 16K 7 at $C000");
            chr8(14'h0000, 6'd10, "M11 CHR bits 7:4 = 10");
            chr8(14'h1C00, 6'd10, "M11 CHR 8 KB bank covers $1C00");
            wr(16'hFFF0, 8'h5D);                     // bits 3:2 (lockout) set: ignored
            prg16(16'h8000, 5'd2, "M11 PRG 1 (lockout bits ignored)");
            chr8(14'h0400, 6'd5, "M11 CHR 5");
            a10_at(14'h2400, 1, "M11 header vertical: $2400 -> 1");
            setup(8'h03, 8'h07, 8'h00);              // 64 KB PRG, 64 KB CHR, horizontal
            wr(16'h8000, 8'hF3);
            prg16(16'h8000, 5'd2, "M11 64 KB: PRG 3 & 1 = 1 -> 16K 2");
            chr8(14'h0000, 6'd7, "M11 64 KB CHR: 15 & 7 = 7");
            a10_at(14'h2800, 1, "M11 header horizontal: $2800 -> 1");
            setup(8'h07, 8'h0F, 8'h01);
            chr8(14'h0000, 6'd0, "M11: bank cleared by the menu");
        end

        if (M == 34) begin
            // ---- BNROM path: 128 KB PRG, 8 KB CHR RAM, vertical
            setup(8'h07, 8'h80, 8'h01);
            prg16(16'h8000, 5'd0, "M34 power-on: PRG 32K bank 0");
            pa = 14'h0400; #20; rd(16'h0000);
            check("M34 BNROM start: $0400 in 8 KB bank 0 (4K 0)", s_chr_map, 9'd1);
            pa = 14'h1C00; #20; rd(16'h0000);
            check("M34 BNROM start: $1C00 in 8 KB bank 0 (4K 1)", s_chr_map, 9'd7);
            wr(16'h8000, 8'h03);
            prg16(16'h8000, 5'd6, "M34 BNROM $8000 bits 1:0 = 3 -> 16K 6");
            prg16(16'hFFFC, 5'd7, "M34 BNROM 32 KB window");
            wr(16'hC000, 8'h01);
            prg16(16'h8000, 5'd2, "M34 BNROM write anywhere in $8000-$FFFF");
            pa = 14'h1C00; #20; rd(16'h0000);
            check("M34 BNROM: PRG writes leave CHR unbanked", s_chr_map, 9'd7);
            a10_at(14'h2400, 1, "M34 header vertical");
            // ---- NINA-001 path: 128 KB PRG mask (more than NINA's 64 KB, so that
            // only the register limits the bank), 64 KB CHR ROM (16 x 4 KB), horizontal
            setup(8'h07, 8'h07, 8'h00);
            cycle(16'h7FFD, 1, 8'h01);
            check("M34 NINA $7FFD write also goes to PRG RAM", s_ram_we, 0); rd(16'h0000);
            prg16(16'h8000, 5'd2, "M34 NINA $7FFD bit 0 = 1 -> 16K 2");
            prg16(16'hC000, 5'd3, "M34 NINA 32 KB window");
            wr(16'h7FFE, 8'h09);
            wr(16'h7FFF, 8'h0E);
            pa = 14'h0800; #20; rd(16'h0000);
            check("M34 NINA $7FFE = 9: $0800 -> 4K 9", s_chr_map[8:2], 7'd9);
            check("M34 NINA CHR A11-A10 from the PPU", s_chr_map[1:0], 2'b10);
            pa = 14'h1000; #20; rd(16'h0000);
            check("M34 NINA $7FFF = 14: $1000 -> 4K 14", s_chr_map[8:2], 7'd14);
            wr(16'h7FFD, 8'hFE);
            prg16(16'h8000, 5'd0, "M34 NINA $7FFD bit 0 only");
            wr(16'h7FFC, 8'h01);
            prg16(16'h8000, 5'd0, "M34 $7FFC is no register");
            wr(16'h6000, 8'h0F);
            pa = 14'h0000; #20; rd(16'h0000);
            check("M34 $6000 is RAM only (CHR unchanged)", s_chr_map[8:2], 7'd9);
            rd(16'h6123); check("M34 PRG RAM at $6000", s_ram_ce, 1);
            a10_at(14'h2800, 1, "M34 header horizontal");
            setup(8'h03, 8'h07, 8'h00);
            pa = 14'h1000; #20; rd(16'h0000);
            check("M34 menu: CHR $1000 back to 4K 1", s_chr_map[8:2], 7'd1);
        end

        $display("mapper %0d: %0d checks, %0d failed", M, checks, fails);
        if (fails == 0) $display("PASS");
        $finish;
    end
endmodule
