// n8-open: testbench for the MMC3 core (n8_top, MAPPER 4), run with Icarus Verilog:
//   iverilog -g2005 -o tb_mmc3 tb_mmc3.v ../nrom/top.v ../nrom/osmap.v ../nrom/map_nrom.v ../nrom/map_mmc1.v ../nrom/map_mmc3.v
//   vvp tb_mmc3
// CPU bus cycles as in tb_mmc1.v. A PPU model runs in parallel: 341 dots per
// line, 3 dots per CPU cycle, 262 lines, with the real fetch pattern on the
// address bus (background: NT, AT, pattern lo/hi; sprites: 2 dummy NT
// fetches + pattern lo/hi, 8 times; prefetch; 2 NT fetches at the line end).
`timescale 1ns/1ps

module tb_mmc3;
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
    pullup (cpu_irq);                        // open drain on the console side

    n8_top #(.MAPPER(4)) dut (
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
    task bank(input [2:0] r, input [7:0] v);  begin wr(16'h8000, {ctl_hi, 6'b000000} | r); wr(16'h8001, v); end endtask

    task check(input [255:0] what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                $display("FAIL %0s: got %0d want %0d", what, got, want);
            end
        end
    endtask

    // 8 KB PRG bank for a CPU read (prg_map[8:3] = A13-A18)
    task prg8(input [15:0] addr, input [5:0] want, input [255:0] what);
        begin rd(addr); check(what, s_prg_map[8:3], want); check({what, " /CE"}, s_prg_ce, 0); end
    endtask
    // 1 KB CHR bank for a PPU address (chr_map = A10-A18)
    task chr1k(input [13:0] addr, input [8:0] want, input [255:0] what);
        begin pa = addr; #20; rd(16'h0000); check(what, s_chr_map, want); end
    endtask
    task a10_at(input [13:0] addr, input want, input [255:0] what);
        begin pa = addr; #20; rd(16'h0000); check(what, s_a10, want); end
    endtask

    reg [1:0] ctl_hi = 2'b00;               // bits 7:6 of the bank select writes

    // ---------------------------------------------------------------- PPU model
    reg render = 0;
    reg bg_hi = 0, spr_hi = 1;              // pattern tables: 0 = $0000, 1 = $1000
    integer line = 241, dot = 0;
    integer frames = 0;                     // count of passes through line 241, dot 0

    function [13:0] fetch(input integer l, input integer d);
        integer p;
        begin
            if (!(l < 240 || l == 261))
                fetch = 14'h2000;                                   // vblank: A12 low
            else if ((d >= 1 && d <= 256) || (d >= 321 && d <= 336)) begin
                p = (d - 1) % 8;
                fetch = (p < 2) ? 14'h2000 : (p < 4) ? 14'h23C0 :
                        ((bg_hi ? 14'h1000 : 14'h0000) | ((p >= 6) ? 14'h0008 : 14'h0000));
            end else if (d >= 257 && d <= 320) begin
                p = (d - 257) % 8;
                fetch = (p < 4) ? 14'h2000 : (spr_hi ? 14'h1000 : 14'h0000);
            end else
                fetch = 14'h2000;                                   // dot 0, 337-340
        end
    endfunction

    initial forever begin
        wait (render);
        line = 241; dot = 0;
        while (render) begin
            if (line == 241 && dot == 0) frames = frames + 1;
            pa = fetch(line, dot);
            #186.667;
            dot = dot + 1;
            if (dot == 341) begin
                dot = 0;
                line = (line == 261) ? 0 : line + 1;
            end
        end
    end

    // scanline clocks and IRQ edges, as seen by the mapper
    integer clocks = 0, irq_falls = 0, irq_line = -1, irq_dot = -1;
    always @(negedge m2) if (dut.g_mmc3.mmc3.irq_clk) clocks = clocks + 1;
    // (=== 0: the x -> 1 settling of the open-drain line at t=0 is not an IRQ)
    always @(negedge cpu_irq) if (cpu_irq === 1'b0) begin irq_falls = irq_falls + 1; irq_line = line; irq_dot = dot; end

    // run CPU read cycles until the PPU starts a new frame (n times)
    task run_frames(input integer n);
        integer f0;
        begin f0 = frames; while (frames < f0 + n) rd(16'h0000); end
    endtask
    // run CPU read cycles until the IRQ line goes low (timeout: 2 frames)
    task wait_irq;
        integer n;
        begin n = 0; while (cpu_irq !== 1'b0 && n < 60000) begin rd(16'h0000); n = n + 1; end end
    endtask
    task stop_ppu;  begin render = 0; repeat (2) rd(16'h0000); pa = 14'h0000; end endtask

    integer c0, f0;

    initial begin
        repeat (20) rd(16'h0000);

        // ---- loader setup: 256 KB PRG (mask 15), 256 KB CHR ROM (mask 31), mapper 4
        reg_w(8'h84, 8'h0F);
        reg_w(8'h85, 8'h1F);
        reg_w(8'h86, 8'h00);
        reg_w(8'h88, 8'h00);
        reg_w(8'h83, 8'h04);

        // ---- PRG
        prg8(16'h8000, 6'd0,  "power-on $8000 = R6 (0)");
        prg8(16'hC000, 6'd30, "power-on $C000 = second-last (30)");
        prg8(16'hE000, 6'd31, "256K last bank = 31");
        bank(3'd6, 8'd5);
        bank(3'd7, 8'd9);
        prg8(16'h8000, 6'd5,  "mode 0 $8000 = R6");
        prg8(16'hA000, 6'd9,  "mode 0 $A000 = R7");
        prg8(16'hC000, 6'd30, "mode 0 $C000 fixed -2");
        ctl_hi = 2'b01; wr(16'h8000, 8'h46);            // PRG mode 1
        prg8(16'h8000, 6'd30, "mode 1 $8000 fixed -2");
        prg8(16'hA000, 6'd9,  "mode 1 $A000 = R7");
        prg8(16'hC000, 6'd5,  "mode 1 $C000 = R6");
        prg8(16'hE000, 6'd31, "mode 1 $E000 fixed -1");
        bank(3'd6, 8'd63);                              // beyond 256 KB: masked
        prg8(16'hC000, 6'd31, "R6 = 63 masked to 31");
        ctl_hi = 2'b00; wr(16'h8000, 8'h00);

        // ---- CHR (256 KB: 1 KB banks 0-255)
        bank(3'd0, 8'h11);                              // 2 KB: low bit ignored
        bank(3'd1, 8'h20);
        bank(3'd2, 8'h40);
        bank(3'd3, 8'h41);
        bank(3'd4, 8'h42);
        bank(3'd5, 8'hFF);
        chr1k(14'h0000, 9'h010, "R0 $0000 (low bit ignored)");
        chr1k(14'h0400, 9'h011, "R0 $0400");
        chr1k(14'h0800, 9'h020, "R1 $0800");
        chr1k(14'h0C00, 9'h021, "R1 $0C00");
        chr1k(14'h1000, 9'h040, "R2 $1000");
        chr1k(14'h1400, 9'h041, "R3 $1400");
        chr1k(14'h1800, 9'h042, "R4 $1800");
        chr1k(14'h1C00, 9'h0FF, "R5 $1C00 = bank 255 (top of 256 KB)");
        ctl_hi = 2'b10; wr(16'h8000, 8'h80);            // CHR A12 inversion
        chr1k(14'h0000, 9'h040, "inverted $0000 = R2");
        chr1k(14'h0C00, 9'h0FF, "inverted $0C00 = R5");
        chr1k(14'h1000, 9'h010, "inverted $1000 = R0");
        chr1k(14'h1C00, 9'h021, "inverted $1C00 = R1");
        ctl_hi = 2'b00; wr(16'h8000, 8'h00);

        // ---- mirroring
        wr(16'hA000, 8'h00);
        a10_at(14'h2400, 1, "vertical $2400 -> A10=1");
        a10_at(14'h2800, 0, "vertical $2800 -> A10=0");
        wr(16'hA000, 8'h01);
        a10_at(14'h2400, 0, "horizontal $2400 -> A10=0");
        a10_at(14'h2800, 1, "horizontal $2800 -> A10=1");
        pa = 14'h0000;

        // ---- PRG RAM: power-on enabled + writable, then protect, then disable
        rd(16'h6000);         check("RAM read (power-on): ram_ce", s_ram_ce, 1);
        cycle(16'h6001, 1, 8'h55); check("RAM write (power-on): ram_we", s_ram_we, 0);
        rd(16'h0000);
        wr(16'hA001, 8'hC0);                            // enabled, write protected
        rd(16'h6000);         check("RAM read (protected): ram_ce", s_ram_ce, 1);
        cycle(16'h6001, 1, 8'h55); check("RAM write (protected): no ram_we", s_ram_we, 1);
        rd(16'h0000);
        wr(16'hA001, 8'h00);                            // disabled
        rd(16'h6000);         check("RAM read (disabled): no ram_ce", s_ram_ce, 0);
        wr(16'hA001, 8'h80);

        // ---- one clock per scanline: BG $0000, sprites $1000, IRQ off
        bg_hi = 0; spr_hi = 1; render = 1;
        run_frames(1);                                  // start at line 241
        c0 = clocks; run_frames(1);
        check("clocks/frame BG $0000 SPR $1000 = 241", clocks - c0, 241);
        stop_ppu;
        // ---- BG $1000, sprites $0000: the 8-9-dot A12 dip at each line end
        // (dots 337-4) must not count. 242 = 241 lines at dot ~325 plus the
        // rise at the first background fetch of the pre-render line after the
        // A12-low vblank (dot ~5), which any A12 counter sees.
        bg_hi = 1; spr_hi = 0; render = 1;
        run_frames(1);
        c0 = clocks; run_frames(1);
        check("clocks/frame BG $1000 SPR $0000 = 242", clocks - c0, 242);
        stop_ppu;
        check("no IRQ while disabled", irq_falls, 0);
        check("IRQ line high while disabled", cpu_irq, 1);

        // ---- rendering off: no clocks
        c0 = clocks; repeat (2000) rd(16'h0000);
        check("no clocks with rendering off", clocks - c0, 0);

        // ---- IRQ at scanline: latch 20 -> first IRQ on line 19, then every 21 lines
        bg_hi = 0; spr_hi = 1;
        wr(16'hC000, 8'd20);
        wr(16'hC001, 8'h00);
        wr(16'hE001, 8'h00);
        render = 1;
        wait_irq;
        check("IRQ 1 asserted", cpu_irq, 0);
        check("IRQ 1 on line 19", irq_line, 19);
        check("IRQ 1 near dot 261 (sprite fetch)", (irq_dot >= 261 && irq_dot <= 266), 1);
        repeat (5) rd(16'h0000);
        check("IRQ stays asserted until acknowledged", cpu_irq, 0);
        wr(16'hE000, 8'h00); wr(16'hE001, 8'h00);       // acknowledge, re-enable
        check("IRQ released by $E000", cpu_irq, 1);
        wait_irq;
        check("IRQ 2 on line 40", irq_line, 40);
        wr(16'hE000, 8'h00);
        stop_ppu;

        // ---- latch 0 (MMC3B/C): IRQ on the first clock (pre-render line 261)
        wr(16'hC000, 8'd0);
        wr(16'hC001, 8'h00);
        wr(16'hE001, 8'h00);
        render = 1;
        wait_irq;
        check("latch 0: IRQ on line 261", irq_line, 261);
        wr(16'hE000, 8'h00);
        stop_ppu;

        $display("%0d checks, %0d failed", checks, fails);
        if (fails == 0) $display("PASS");
        $finish;
    end
endmodule
