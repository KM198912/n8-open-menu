// n8-open: testbench for the Sunsoft FME-7 (map_fme7.v), Icarus:
//   iverilog -g2005 -o tb_fme7 tb_fme7.v ../nrom/*.v
// CPU bus cycles as in tb_simple; the PPU model of tb_fds/tb_vrc6 for the
// split line of an NTSC game on NTSC, on PAL without and with the fix.
`timescale 1ns/1ps

module tb_fme7;
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

    n8_top #(.MAPPER(69)) dut (
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
    task fme(input [3:0] c, input [7:0] v);  begin wr(16'h8000, { 4'd0, c }); wr(16'hA000, v); end endtask

    task check(input [255:0] what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                $display("FAIL %0s: got %0d want %0d", what, got, want);
            end
        end
    endtask
    task check_rng(input [255:0] what, input integer got, input integer lo, input integer hi);
        begin
            checks = checks + 1;
            if (got < lo || got > hi) begin
                fails = fails + 1;
                $display("FAIL %0s: got %0d want %0d..%0d", what, got, lo, hi);
            end
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
    task setup(input [7:0] cfg);
        begin
            force dut.osmap.map_idx = 8'hFF; rd(16'h0000); release dut.osmap.map_idx;
            reg_w(8'h84, 8'h1F);                 // 512 KB PRG (64 x 8 KB)
            reg_w(8'h85, 8'h1F);                 // 256 KB CHR ROM
            reg_w(8'h86, cfg);
            reg_w(8'h83, 8'd69);
        end
    endtask
    integer cnt;
    task until_irq(input integer n);
        begin cnt = 0; while (cpu_irq !== 1'b0 && cnt < n) begin rd(16'h0000); cnt = cnt + 1; end end
    endtask

    // ---------------------------------------------------------------- PPU model (as tb_fds)
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
    // a game's NMI: counter = c, counter + IRQ on, right after vblank starts
    task game_frame(input [15:0] c);
        begin
            wait_line(241);
            fme(4'hE, c[7:0]);
            fme(4'hF, c[15:8]);
            fme(4'hD, 8'h81);
            irq_line = -1;
            until_irq(60000);
            fme(4'hD, 8'h00);                    // acknowledge, stop
        end
    endtask
    integer ntsc_line, ntsc_deep;

    initial begin
        repeat (20) rd(16'h0000);
        reg_w(8'h88, 8'h00);
        setup(8'h00);

        // ---- PRG
        prg8(16'h8000, 6'd0,  "power-on: $8000 = bank 0");
        prg8(16'hE000, 6'd63, "$E000 = last 8 KB");
        prg8(16'h6000, 6'd0,  "power-on: $6000 = ROM bank 0");
        check("power-on: $6000 is ROM, not RAM", s_ram_ce, 0);
        fme(4'h9, 8'h05); fme(4'hA, 8'h26); fme(4'hB, 8'hFF);
        prg8(16'h9FFF, 6'd5,  "cmd 9: $8000 = 5");
        prg8(16'hA000, 6'd38, "cmd A: $A000 = 38 (6 bits)");
        prg8(16'hDFFF, 6'd63, "cmd B: $C000 = $FF -> 63");
        fme(4'h8, 8'h35);
        prg8(16'h7FFF, 6'd53, "cmd 8 = $35: ROM bank 53 at $6000 (6 bits)");
        fme(4'h8, 8'hC0);
        rd(16'h6000);
        check("cmd 8 = $C0: PRG RAM enabled", s_ram_ce, 1);
        check("cmd 8 = $C0: PRG ROM off", s_prg_ce, 1);
        cycle(16'h7123, 1, 8'h55); check("PRG RAM writable", s_ram_we, 0); rd(16'h0000);
        fme(4'h8, 8'h40);
        rd(16'h6000);
        check("cmd 8 = $40: RAM selected but off -> no RAM", s_ram_ce, 0);
        check("cmd 8 = $40: ... no ROM either (open bus)", s_prg_ce, 1);
        cycle(16'h6000, 1, 8'h55); check("RAM off: no write", s_ram_we, 1); rd(16'h0000);
        fme(4'h8, 8'h80);
        prg8(16'h6000, 6'd0, "cmd 8 = $80: RAM enable without select = ROM");
        wr(16'h9FFF, 8'h09); wr(16'hBFFF, 8'h11);
        prg8(16'h8000, 6'd17, "command/parameter: whole $8000-$9FFF / $A000-$BFFF windows");

        // ---- CHR
        fme(4'h0, 8'h12); fme(4'h7, 8'hFF); fme(4'h3, 8'h80);
        chr_at(14'h0000, 9'h012, "cmd 0: $0000 = $12");
        chr_at(14'h03FF, 9'h012, "1 KB bank");
        chr_at(14'h1C00, 9'h0FF, "cmd 7: $1C00 = $FF (8 bits)");
        chr_at(14'h0C00, 9'h080, "cmd 3: $0C00 = $80");
        chr_at(14'h0400, 9'h000, "cmd 1 untouched");

        // ---- mirroring
        fme(4'hC, 8'h00); a10_at(14'h2400, 1, "cmd C = 0: CIRAM A10 = PPU A10 ($2400 -> 1)");
        a10_at(14'h2800, 0, "cmd C = 0: $2800 -> 0");
        fme(4'hC, 8'h01); a10_at(14'h2400, 0, "cmd C = 1: CIRAM A10 = PPU A11 ($2400 -> 0)");
        a10_at(14'h2800, 1, "cmd C = 1: $2800 -> 1");
        fme(4'hC, 8'h02); a10_at(14'h2C00, 0, "cmd C = 2: A10 low");
        fme(4'hC, 8'h03); a10_at(14'h2000, 1, "cmd C = 3: A10 high");

        // ---- IRQ
        fme(4'hE, 8'h10); fme(4'hF, 8'h00);          // 16
        wr(16'h8000, 8'h0D);
        cycle(16'hA000, 1, 8'h81);                   // counter + IRQ on (counting from here)
        until_irq(100);
        check_rng("IRQ after counter + 1 cycles (16 -> 17)", cnt, 15, 17);
        repeat (5) rd(16'h0000);
        check("IRQ held until acknowledged", cpu_irq, 0);
        fme(4'hD, 8'h81);
        repeat (3) rd(16'h0000);
        check("any cmd D write acknowledges", cpu_irq, 1);
        until_irq(70000);
        check_rng("counter keeps running after the wrap: next IRQ after 65536", cnt, 65520, 65540);
        fme(4'hD, 8'h80);                            // counter on, IRQ off
        fme(4'hE, 8'h05); fme(4'hF, 8'h00);
        repeat (40) rd(16'h0000);
        check("IRQ enable 0: wrap without IRQ", cpu_irq, 1);
        fme(4'hD, 8'h00);                            // stop first (it is running)
        fme(4'hE, 8'h02); fme(4'hF, 8'h00);
        fme(4'hD, 8'h01);                            // IRQ on, counter off
        repeat (40) rd(16'h0000);
        check("counter enable 0: no counting, no IRQ", cpu_irq, 1);
        check("counter enable 0: counter still 2", dut.g_fme7.fme7.cnt, 2);
        fme(4'hD, 8'h00);

        // ---- NTSC game on PAL: split lines
        ppu_run = 1; pal = 0;
        wait_line(100);                              // a full frame first after a restart
        game_frame(16'd5823);
        ntsc_line = irq_line;
        game_frame(16'd17190);
        ntsc_deep = irq_line;
        check_rng("NTSC: 5824 cycles split in the picture", ntsc_line, 20, 40);
        check_rng("NTSC: 17191 cycles split deeper", ntsc_deep, 120, 150);
        ppu_run = 0; repeat (5) rd(16'h0000);
        ppu_run = 1; pal = 1;
        wait_line(100);
        game_frame(16'd5823);
        check_rng("PAL, no fix: IRQ in vblank (split before the picture)", irq_line, 241, 311);
        $display("  NTSC lines %0d / %0d, PAL without fix line %0d", ntsc_line, ntsc_deep, irq_line);
        ppu_run = 0; repeat (5) rd(16'h0000);
        setup(8'h40);
        ppu_run = 1; pal = 1;
        wait_line(100);
        game_frame(16'd5823);
        $display("  PAL with fix line %0d", irq_line);
        check_rng("PAL, fix on: same line as NTSC (+-1)", irq_line, ntsc_line - 1, ntsc_line + 1);
        game_frame(16'd17190);
        $display("  PAL with fix, deep split line %0d", irq_line);
        check_rng("PAL, fix on: deep split same line as NTSC (+-2, 16/15 while rendering)",
                  irq_line, ntsc_deep - 2, ntsc_deep + 2);
        ppu_run = 0; repeat (5) rd(16'h0000);

        // ---- back to the menu
        setup(8'h00);
        prg8(16'h8000, 6'd0, "menu: PRG registers cleared");
        chr_at(14'h1C00, 9'd0, "menu: CHR registers cleared");

        $display("tb_fme7: %0d checks, %0d failed", checks, fails);
        if (fails == 0) $display("PASS");
        $finish;
    end
endmodule
