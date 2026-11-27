// n8-open: testbench for VRC2 / VRC4 (map_vrc4.v), Icarus:
//   iverilog -g2005 -Ptb_vrc4.M=25 -o tb_vrc4 tb_vrc4.v ../nrom/*.v
// M = 21, 22, 23 or 25. Registers are written through the mapper's first
// address-line pair (and, for 21/23/25, checked through the second as well).
// The IRQ's details are covered by tb_vrc6 (same vrc_irq.v); here only its
// VRC4 wiring: nibble latch, control, acknowledge.
`timescale 1ns/1ps

module tb_vrc4;
    parameter M = 25;
    localparam VRC4 = (M != 22);
    // register line 0 / 1: CPU address bit of the first and the second pair
    localparam P0 = (M == 21) ? 1 : (M == 22) ? 1 : (M == 23) ? 0 : 1;
    localparam P1 = (M == 21) ? 2 : (M == 22) ? 0 : (M == 23) ? 1 : 0;
    localparam Q0 = (M == 21) ? 6 : (M == 23) ? 2 : 3;          // second pair (not 22)
    localparam Q1 = (M == 21) ? 7 : (M == 23) ? 3 : 2;

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
    pullup (cpu_irq);

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
    reg s_prg_ce, s_ram_ce, s_ram_we, s_a10;

    task cycle(input [15:0] addr, input wr, input [7:0] d);
        begin
            m2 = 0; a = addr; rw = ~wr; dout = d; drive = wr;
            #280;
            m2 = 1;
            #240;
            s_prg_map = prg_map; s_prg_ce = prg_ce; s_ram_ce = ram_ce; s_ram_we = ram_we;
            s_a10 = ppu_ciram_a10; s_chr = chr_map;
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

    // register address: page base + logical lines, through pair 0 or 1
    function [15:0] ra(input [15:0] base, input l0, input l1, input pair);
        begin
            if (!pair) ra = base | (l0 ? (16'd1 << P0) : 16'd0) | (l1 ? (16'd1 << P1) : 16'd0);
            else       ra = base | (l0 ? (16'd1 << Q0) : 16'd0) | (l1 ? (16'd1 << Q1) : 16'd0);
        end
    endfunction
    task rw4(input [15:0] base, input l0, input l1, input pair, input [7:0] d);
        begin wr(ra(base, l0, l1, pair), d); end
    endtask
    // CHR register n (0-7) = value v, through pair p
    task chr_w(input integer n, input [8:0] v, input pair);
        reg [15:0] base;
        begin
            base = 16'hB000 + (n / 2) * 16'h1000;
            rw4(base, 0, n % 2, pair, { 4'd0, v[3:0] });
            rw4(base, 1, n % 2, pair, { 3'd0, v[8:4] });
        end
    endtask

    task prg8(input [15:0] addr, input [5:0] want, input [255:0] what);
        begin rd(addr); check(what, s_prg_map[8:3], want); check({what, " /CE"}, s_prg_ce, 0); end
    endtask
    task chr_at(input [13:0] addr, input [8:0] want, input [255:0] what);
        begin pa = addr; #20; rd(16'h0000); check(what, s_chr, want); end
    endtask
    task a10_at(input [13:0] addr, input want, input [255:0] what);
        begin pa = addr; #20; rd(16'h0000); check(what, s_a10, want); end
    endtask
    task setup;
        begin
            force dut.osmap.map_idx = 8'hFF; rd(16'h0000); release dut.osmap.map_idx;
            reg_w(8'h84, 8'h0F);                 // 256 KB PRG (32 x 8 KB)
            reg_w(8'h85, 8'h3F);                 // 512 KB CHR ROM
            reg_w(8'h86, 8'h00);
            reg_w(8'h83, M);
        end
    endtask

    integer n;
    initial begin
        repeat (20) rd(16'h0000);
        reg_w(8'h88, 8'h00);
        setup;

        // ---- PRG
        prg8(16'h8000, 6'd0,  "power-on: $8000 = bank 0");
        prg8(16'hA000, 6'd0,  "power-on: $A000 = bank 0");
        prg8(16'hC000, 6'd30, "$C000 = second-last 8 KB");
        prg8(16'hE000, 6'd31, "$E000 = last 8 KB");
        rw4(16'h8000, 0, 0, 0, 8'h05);
        rw4(16'hA000, 0, 0, 0, 8'h17);
        prg8(16'h9FFF, 6'd5,  "$8000 = 5");
        prg8(16'hBFFF, 6'd23, "$A000 = 23");
        rw4(16'h8000, 1, 1, 0, 8'hFF);
        prg8(16'h8000, 6'd31, "$8000 register: 5 bits ($FF -> 31), all four sub addresses");
        rw4(16'h8000, 0, 0, 0, 8'h05);
        rw4(16'h9000, 0, 1, 0, 8'h02);                     // $9002: swap mode
        if (VRC4) begin
            prg8(16'h8000, 6'd30, "VRC4 swap: $8000 = second-last");
            prg8(16'hC000, 6'd5,  "VRC4 swap: $C000 = $8000 register");
            prg8(16'hA000, 6'd23, "VRC4 swap: $A000 unchanged");
            rw4(16'h9000, 0, 1, 1, 8'h00);                 // via the second pair
            prg8(16'h8000, 6'd5,  "VRC4 swap off through the second address pair");
        end else begin
            prg8(16'h8000, 6'd5,  "VRC2: no swap mode");
            prg8(16'hC000, 6'd30, "VRC2: $C000 fixed");
        end
        rd(16'h6000); check("PRG RAM at $6000 (always on)", s_ram_ce, 1);
        cycle(16'h7FFF, 1, 8'h01); check("PRG RAM writable (VRC2 latch read-back)", s_ram_we, 0); rd(16'h0000);

        // ---- CHR
        chr_w(0, 9'h13A, 0);
        chr_w(7, 9'h0C5, 0);
        chr_w(3, 9'h1FF, 0);
        if (M == 22) begin
            chr_at(14'h0000, 9'h01D, "VRC2a: $B000 = ($3A, high 4 bits) >> 1");
            chr_at(14'h1C00, 9'h062, "VRC2a: $E002 = $C5 >> 1");
            chr_at(14'h0C00, 9'h07F, "VRC2a: $C002 = $FF >> 1");
        end else begin
            chr_at(14'h0000, 9'h13A, "VRC4: $B000 = $13A (9 bits)");
            chr_at(14'h03FF, 9'h13A, "VRC4: 1 KB bank covers $0000-$03FF");
            chr_at(14'h1C00, 9'h0C5, "VRC4: $E002 = $C5");
            chr_at(14'h0C00, 9'h1FF, "VRC4: $C002 = $1FF");
            chr_w(5, 9'h0A6, 1);                           // second pair
            chr_at(14'h1400, 9'h0A6, "VRC4: $D002 through the second address pair");
        end
        chr_at(14'h0400, 9'h000, "$B002 untouched");
        for (n = 0; n < 8; n = n + 1) chr_w(n, n + 1, 0);
        chr_at(14'h0400, (M == 22) ? 9'd1 : 9'd2, "eight registers: $0400");
        chr_at(14'h1800, (M == 22) ? 9'd3 : 9'd7, "eight registers: $1800");

        // ---- mirroring
        rw4(16'h9000, 0, 0, 0, 8'h00);
        a10_at(14'h2400, 1, "$9000 = 0 vertical: $2400 -> 1");
        rw4(16'h9000, 0, 0, 0, 8'h01);
        a10_at(14'h2400, 0, "$9000 = 1 horizontal: $2400 -> 0");
        a10_at(14'h2800, 1, "horizontal: $2800 -> 1");
        rw4(16'h9000, 0, 0, 0, 8'h02);
        if (VRC4) begin
            a10_at(14'h2C00, 0, "VRC4 $9000 = 2: one screen lower");
            rw4(16'h9000, 0, 0, 0, 8'h03);
            a10_at(14'h2000, 1, "VRC4 $9000 = 3: one screen upper");
            rw4(16'h9000, 1, 1, 0, 8'h00);                 // $9003: not mirroring
            a10_at(14'h2000, 1, "VRC4: $9003 does not touch the mirroring");
        end else begin
            a10_at(14'h2400, 1, "VRC2 $9000 = 2: bit 1 ignored -> vertical");
            rw4(16'h9000, 1, 1, 0, 8'h01);
            a10_at(14'h2400, 0, "VRC2: $9003 = 1 also sets horizontal");
        end

        // ---- IRQ (VRC4 wiring)
        rw4(16'hF000, 0, 0, 0, 8'h0E);                     // latch low nibble
        rw4(16'hF000, 1, 0, 0, 8'h0F);                     // latch high nibble -> $FE
        rw4(16'hF000, 0, 1, 0, 8'h06);                     // control: E, cycle mode
        n = 0;
        while (cpu_irq !== 1'b0 && n < 20) begin rd(16'h0000); n = n + 1; end
        if (VRC4) begin
            check("VRC4 IRQ: latch $FE (nibbles), cycle mode -> IRQ within 3 cycles", n <= 3, 1);
            rw4(16'hF000, 1, 1, 0, 8'h00);                 // acknowledge (A = 0 -> E = 0)
            repeat (3) rd(16'h0000);
            check("VRC4 IRQ: released by $F003", cpu_irq, 1);
            repeat (300) rd(16'h0000);
            check("VRC4 IRQ: E = A = 0 after the acknowledge, no new IRQ", cpu_irq, 1);
            rw4(16'hF000, 0, 0, 1, 8'h00);                 // latch $00 through the second pair
            rw4(16'hF000, 1, 0, 1, 8'h00);
            rw4(16'hF000, 0, 1, 1, 8'h06);
            n = 0;
            while (cpu_irq !== 1'b0 && n < 400) begin rd(16'h0000); n = n + 1; end
            check("VRC4 IRQ: latch $00 -> 256 cycles (second pair)", (n >= 252 && n <= 258), 1);
            rw4(16'hF000, 0, 1, 0, 8'h00);                 // control, E = 0: acknowledges
            repeat (3) rd(16'h0000);
            check("VRC4 IRQ: control write acknowledges", cpu_irq, 1);
        end else
            check("VRC2: no IRQ", cpu_irq, 1);

        // ---- back to the menu
        setup;
        prg8(16'h8000, 6'd0, "menu: PRG registers cleared");
        chr_at(14'h1800, 9'd0, "menu: CHR registers cleared");
        a10_at(14'h2400, 1, "menu: mirroring vertical");

        $display("mapper %0d: %0d checks, %0d failed", M, checks, fails);
        if (fails == 0) $display("PASS");
        $finish;
    end
endmodule
