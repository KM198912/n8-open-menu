// n8-open: testbench for the VRC6 core (map_vrc6.v), Icarus Verilog:
//   iverilog -g2005 -Ptb_vrc6.M=24 -o tb_vrc6 tb_vrc6.v ../nrom/*.v
// M = 24 (VRC6a) or 26 (VRC6b). Registers are written through vw(page, sub),
// which applies the board's A0/A1 swap for mapper 26 - so the swap itself is
// part of what is tested.
`timescale 1ns/1ps

module tb_vrc6;
    parameter M = 24;

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
    reg [8:0] s_prg_map, s_chr_map;
    reg s_prg_ce, s_ram_ce, s_ram_we, s_a10;

    task cycle(input [15:0] addr, input wr, input [7:0] d);
        begin
            m2 = 0; a = addr; rw = ~wr; dout = d; drive = wr;
            #280;
            m2 = 1;
            #240;
            s_prg_map = prg_map; s_prg_ce = prg_ce; s_ram_ce = ram_ce;
            s_ram_we = ram_we; s_a10 = ppu_ciram_a10; s_chr_map = chr_map;
            #40;
            m2 = 0;
            #10;
            drive = 0;
        end
    endtask
    task rd(input [15:0] addr);  begin cycle(addr, 0, 8'h00); end endtask
    task wr(input [15:0] addr, input [7:0] d);  begin cycle(addr, 1, d); rd(16'h0000); end endtask
    task reg_w(input [7:0] idx, input [7:0] v);  begin wr(16'h4400, idx); wr(16'h4401, v); end endtask
    // VRC6 register: page $8-$F, logical sub 0-3 (A0/A1 swapped for mapper 26)
    task vw(input [3:0] page, input [1:0] sub, input [7:0] d);
        reg [1:0] p;
        begin
            p = (M == 26) ? { sub[0], sub[1] } : sub;
            wr({ page, 10'd0, p }, d);
        end
    endtask

    task check(input [255:0] what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                $display("FAIL %0s: got %0d want %0d", what, got, want);
            end
        end
    endtask
    task prg8(input [15:0] addr, input [5:0] want, input [255:0] what);
        begin rd(addr); check(what, s_prg_map[8:3], want); check({what, " /CE"}, s_prg_ce, 0); end
    endtask
    task chr1(input [13:0] addr, input [8:0] want, input [255:0] what);
        begin pa = addr; #20; rd(16'h0000); check(what, s_chr_map, want); end
    endtask
    task a10_at(input [13:0] addr, input want, input [255:0] what);
        begin pa = addr; #20; rd(16'h0000); check(what, s_a10, want); end
    endtask
    // ---------------------------------------------------------------- PPU model
    // NTSC: 262 lines, pre-render 261, 3 dots per CPU cycle (560 ns).
    // PAL:  312 lines, pre-render 311, 3.2 dots per CPU cycle.
    // Rendering lines (0-239, pre-render) read at every second dot; vblank
    // and the post-render line 240 read nothing - all the core looks at.
    reg ppu_run = 0, pal = 0;
    integer line = 241, dot = 0;
    initial forever begin
        wait (ppu_run);
        line = 241; dot = 0;
        while (ppu_run) begin
            if ((line < 240 || line == (pal ? 311 : 261)) && dot[0] && dot < 340) begin
                pa = 14'h0000;
                #(pal ? 175.0 : 186.667);
                ppu_rd = 0;
                #(pal ? 175.0 : 186.667);
                ppu_rd = 1;
                dot = dot + 2;
            end else begin
                #(pal ? 175.0 : 186.667);
                dot = dot + 1;
            end
            if (dot >= 341) begin
                dot = dot - 341;
                line = (line == (pal ? 311 : 261)) ? 0 : line + 1;
            end
        end
    end
    integer irq_line = -1;
    always @(negedge cpu_irq) if (cpu_irq === 1'b0) irq_line = line;
    task wait_line(input integer l);
        begin
            while (line == l) rd(16'h0000);
            while (line != l) rd(16'h0000);
        end
    endtask
    // a game's NMI: set the IRQ for "n clocks" right after vblank starts,
    // then measure on which line it fires
    task game_frame(input [7:0] latch, input [7:0] ctrl);
        begin
            wait_line(241);
            vw(4'hF, 2'd0, latch);
            vw(4'hF, 2'd1, ctrl);
            irq_line = -1;
            until_irq(40000);
            vw(4'hF, 2'd1, 8'h00);             // acknowledge, off
        end
    endtask
    integer ntsc_line;

    // CPU read cycles until /IRQ is low (max n); returns the count in cnt
    integer cnt;
    task until_irq(input integer n);
        begin cnt = 0; while (cpu_irq !== 1'b0 && cnt < n) begin rd(16'h0000); cnt = cnt + 1; end end
    endtask

    initial begin
        repeat (20) rd(16'h0000);
        reg_w(8'h88, 8'h00);
        reg_w(8'h84, 8'h0F);                  // 256 KB PRG
        reg_w(8'h85, 8'h0F);                  // 128 KB CHR ROM
        reg_w(8'h86, 8'h00);
        reg_w(8'h83, M);

        // ---------------------------------------------------------------- PRG
        prg8(16'hE000, 6'd31, "fixed last 8 KB at $E000");
        prg8(16'hFFFC, 6'd31, "reset vector in the last bank");
        vw(4'h8, 2'd0, 8'h05);
        prg8(16'h8000, 6'd10, "$8000 16 KB bank 5: 8K bank 10");
        prg8(16'hA000, 6'd11, "$A000 = 8K bank 11 (second half)");
        vw(4'hC, 2'd0, 8'h13);
        prg8(16'hC000, 6'd19, "$C000 8 KB bank 19");
        prg8(16'hE000, 6'd31, "$E000 still fixed");
        wr(16'h8FF2, 8'h07);                   // A2-A11 ignored: still $8000
        prg8(16'h8000, 6'd14, "mirror $8FF2 = 16 KB register");
        wr(16'hCFFC, 8'h09);                   // A2 = 1 (and A3-A11): still $C000
        prg8(16'hC000, 6'd9, "mirror $CFFC (A2-A11 set) = 8 KB register");

        // ---------------------------------------------------------------- PRG RAM
        vw(4'hB, 2'd3, 8'h20);
        rd(16'h6000); check("PRG RAM off ($B003 bit 7 = 0)", s_ram_ce, 0);
        vw(4'hB, 2'd3, 8'hA0);
        rd(16'h6000); check("PRG RAM on ($B003 = $A0)", s_ram_ce, 1);
        cycle(16'h6123, 1, 8'h55); check("PRG RAM writable", s_ram_we, 0); rd(16'h0000);

        // ---------------------------------------------------------------- CHR
        vw(4'hD, 2'd0, 8'h10); vw(4'hD, 2'd1, 8'h11); vw(4'hD, 2'd2, 8'h12); vw(4'hD, 2'd3, 8'h13);
        vw(4'hE, 2'd0, 8'h14); vw(4'hE, 2'd1, 8'h15); vw(4'hE, 2'd2, 8'h16); vw(4'hE, 2'd3, 8'h7F);
        chr1(14'h0000, 9'h010, "CHR $0000 = R0");
        chr1(14'h0400, 9'h011, "CHR $0400 = R1");
        chr1(14'h0800, 9'h012, "CHR $0800 = R2");
        chr1(14'h0C00, 9'h013, "CHR $0C00 = R3");
        chr1(14'h1000, 9'h014, "CHR $1000 = R4");
        chr1(14'h1400, 9'h015, "CHR $1400 = R5");
        chr1(14'h1800, 9'h016, "CHR $1800 = R6");
        chr1(14'h1C00, 9'h07F, "CHR $1C00 = R7 (bank $7F, top of 128 KB)");
        wr(16'hDE6A, 8'h22);                   // = $D002 (VRC6a) / $D001 (VRC6b)
        chr1((M == 26) ? 14'h0400 : 14'h0800, 9'h022, "mirror $DE6A");

        // ---------------------------------------------------------------- mirroring
        vw(4'hB, 2'd3, 8'h20);
        a10_at(14'h2400, 1, "$B003 $20 vertical: $2400 -> A10 = 1");
        a10_at(14'h2800, 0, "vertical: $2800 -> A10 = 0");
        vw(4'hB, 2'd3, 8'h24);
        a10_at(14'h2400, 0, "$B003 $24 horizontal: $2400 -> A10 = 0");
        a10_at(14'h2800, 1, "horizontal: $2800 -> A10 = 1");
        vw(4'hB, 2'd3, 8'h28);
        a10_at(14'h2C00, 0, "$B003 $28 one-screen lower");
        vw(4'hB, 2'd3, 8'h2C);
        a10_at(14'h2000, 1, "$B003 $2C one-screen upper");

        // ---------------------------------------------------------------- IRQ, cycle mode
        // latch $F0: counter $F0..$FF, IRQ on the 16th clock after the reload
        vw(4'hF, 2'd0, 8'hF0);
        vw(4'hF, 2'd1, 8'h06);                 // E + M (cycle mode), A = 0
        until_irq(100);
        check("cycle mode: IRQ after 16 cycles (latch $F0)", cnt, 15);
        repeat (3) rd(16'h0000);
        check("IRQ stays pending until acknowledged", cpu_irq, 0);
        vw(4'hF, 2'd2, 8'h00);                 // acknowledge: E = A = 0
        check("$F002 acknowledges", cpu_irq, 1);
        repeat (40) rd(16'h0000);
        check("$F002 with A = 0 disables (E = A)", cpu_irq, 1);
        vw(4'hF, 2'd1, 8'h07);                 // E + M + A
        until_irq(100);
        vw(4'hF, 2'd2, 8'h00);                 // acknowledge, E = A = 1: keeps running
        until_irq(100);
        // the counter (reloaded to $F0 at the IRQ) also ticks during the two
        // cycles of the acknowledge (write + read): 2 + 14 = 16 clocks
        check("$F002 with A = 1 keeps counting (reloaded $F0)", cnt, 14);
        vw(4'hF, 2'd1, 8'h00);                 // off, acknowledged
        check("$F001 acknowledges", cpu_irq, 1);

        // ---------------------------------------------------------------- IRQ, scanline mode
        // latch $FE: two prescaler clocks to the IRQ = 114 + 114 CPU cycles.
        // Counted reads exclude the read inside vw(), during which the
        // prescaler already runs: expected = cycles - 1 after a $F001 write,
        // cycles - 2 after an acknowledge (its write and read both count).
        vw(4'hF, 2'd0, 8'hFE);
        vw(4'hF, 2'd1, 8'h02);                 // E, scanline mode
        until_irq(600);
        check("scanline mode: 2 lines = 114 + 114 cycles", cnt, 227);
        vw(4'hF, 2'd0, 8'hFF);                 // next: 1 line each
        vw(4'hF, 2'd2, 8'h00);                 // A = 0 -> E = 0: stops
        vw(4'hF, 2'd1, 8'h02);                 // restart, prescaler 341
        until_irq(600);
        check("scanline mode: 1 line = 114 cycles", cnt, 113);
        vw(4'hF, 2'd1, 8'h03);                 // restart with A = 1
        until_irq(600);
        vw(4'hF, 2'd2, 8'h00); until_irq(600);
        check("scanline mode: 2nd line = 114 cycles", cnt, 112);
        vw(4'hF, 2'd2, 8'h00); until_irq(600);
        check("scanline mode: 3rd line = 113 cycles", cnt, 111);
        vw(4'hF, 2'd1, 8'h00);

        // ---------------------------------------------------------------- NTSC game on PAL
        // latch 205: 51 counter clocks = 20 vblank lines + ~31 visible lines
        ppu_run = 1; pal = 0;
        game_frame(8'd205, 8'h02);
        ntsc_line = irq_line;
        check("NTSC console: IRQ in the picture (line < 60)", (ntsc_line >= 0 && ntsc_line < 60), 1);
        ppu_run = 0; repeat (5) rd(16'h0000);
        ppu_run = 1; pal = 1;                  // PAL console, no correction
        game_frame(8'd205, 8'h02);
        check("PAL, no fix: IRQ still in vblank (the Akumajou picture)", (irq_line >= 241 && irq_line <= 310), 1);
        $display("  NTSC line %0d, PAL without fix line %0d", ntsc_line, irq_line);
        // menu: NTSC game on PAL -> fix on ($86 is only writable in menu mode,
        // as the loader does it before the game starts)
        force dut.osmap.map_idx = 8'hFF; rd(16'h0000); release dut.osmap.map_idx;
        reg_w(8'h86, 8'h40);
        reg_w(8'h83, M);
        game_frame(8'd205, 8'h02);
        $display("  PAL with fix line %0d", irq_line);
        check("PAL, fix on: same line as NTSC (+-1)", (irq_line >= ntsc_line - 1 && irq_line <= ntsc_line + 1), 1);
        game_frame(8'd205, 8'h02);
        check("PAL, fix on: second frame the same (+-1)", (irq_line >= ntsc_line - 1 && irq_line <= ntsc_line + 1), 1);
        // fix on, rendering off: 256 lines cross the whole hold window; the
        // hold is capped, so the IRQ still comes (256 x 106.6 + 5400 cycles)
        ppu_run = 0; repeat (5) rd(16'h0000);
        vw(4'hF, 2'd0, 8'h00);                 // 256 clocks
        vw(4'hF, 2'd1, 8'h02);                 // scanline mode
        until_irq(40000);
        check("fix on, rendering off: IRQ still comes (hold capped)", (cnt < 40000), 1);
        check("fix on, rendering off: hold included (> 256 PAL lines)", (cnt > 27300), 1);
        vw(4'hF, 2'd1, 8'h00);
        force dut.osmap.map_idx = 8'hFF; rd(16'h0000); release dut.osmap.map_idx;
        reg_w(8'h86, 8'h00);
        reg_w(8'h83, M);

        // ---------------------------------------------------------------- menu clears
        force dut.osmap.map_idx = 8'hFF; rd(16'h0000); release dut.osmap.map_idx;
        reg_w(8'h83, M);
        prg8(16'h8000, 6'd0, "menu clears the PRG bank");
        check("menu clears the IRQ", cpu_irq, 1);

        $display("mapper %0d: %0d checks, %0d failed", M, checks, fails);
        if (fails == 0) $display("PASS");
        $finish;
    end
endmodule
