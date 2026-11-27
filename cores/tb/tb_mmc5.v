// n8-open: testbench for the MMC5 core (n8_top, MAPPER 5), Icarus Verilog.
// CPU bus cycles as in tb_mmc1/3. PPU model with real reads: address out
// for one dot, /RD low for the next; per rendered line 34 tiles (NT, AT,
// pattern lo/hi), 8 sprites (2 identical dummy NT reads, pattern lo/hi),
// prefetch of 2 tiles, 2 dummy NT reads that equal the next line's first
// NT read (the MMC5's scanline signature). Lines 240-260: no reads.
// Monitors (all the time): CPU bus driven while M2 is low, PPU bus driven
// during a pattern table read.
`timescale 1ns/1ps

module tb_mmc5;
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
    reg  [7:0]  pdout = 8'h00;
    reg         pdrive = 0;
    wire [7:0]  ppu_dat = pdrive ? pdout : 8'hzz;

    wire [8:0] prg_map, chr_map;
    wire prg_ce, prg_oe, prg_we, chr_ce, chr_oe, chr_we, ram_ce, ram_oe, ram_we;
    wire ppu_ciram_ce, ppu_ciram_a10, ppu_dir, ppu_ex, cpu_irq, cpu_exp, max0, max1;
    pullup (cpu_irq);

    n8_top #(.MAPPER(5)) dut (
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
    integer bad_cpu_low = 0, bad_ppu_pt = 0, bad_ppu_idle = 0;

    task check(input [255:0] what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                $display("FAIL %0s: got %0h want %0h", what, got, want);
            end
        end
    endtask

    // ---------------------------------------------------------------- CPU
    reg [8:0] s_prg_map;
    reg s_prg_ce, s_ram_ce, s_ram_we, s_prg_oe, s_ram_oe;
    reg [7:0] s_dat, s_after;
    task cycle(input [15:0] addr, input wr, input [7:0] d);
        begin
            m2 = 0; a = addr; rw = ~wr; dout = d; drive = wr;
            #140;
            if (!drive && cpu_dat !== 8'hzz) bad_cpu_low = bad_cpu_low + 1;
            #140;
            m2 = 1;
            #240;
            s_prg_map = prg_map; s_prg_ce = prg_ce; s_ram_ce = ram_ce;
            s_ram_we = ram_we; s_prg_oe = prg_oe; s_ram_oe = ram_oe; s_dat = cpu_dat;
            #40;
            m2 = 0;
            #5 s_after = cpu_dat;
            #5;
            drive = 0;
        end
    endtask
    task rd(input [15:0] addr);  begin cycle(addr, 0, 8'h00); end endtask
    task wr(input [15:0] addr, input [7:0] d);  begin cycle(addr, 1, d); rd(16'h0000); end endtask
    task reg_w(input [7:0] idx, input [7:0] v);  begin wr(16'h4400, idx); wr(16'h4401, v); end endtask

    task prg8(input [15:0] addr, input [5:0] want, input [255:0] what);
        begin rd(addr); check(what, s_prg_map[8:3], want); check({what, " ROM"}, s_prg_ce, 0); end
    endtask
    task ram8(input [15:0] addr, input [2:0] want, input [255:0] what);
        begin
            rd(addr);
            check(what, s_prg_map[5:3], want);
            check({what, " RAM ce"}, s_ram_ce, 1);
            check({what, " no ROM"}, s_prg_ce, 1);
        end
    endtask

    // ---------------------------------------------------------------- PPU (static)
    reg [7:0] s_pdat; reg s_cice, s_chrce, s_ex, s_dir; reg [8:0] s_chr;
    task ppu_read(input [13:0] addr);
        begin
            pa = addr; #120;
            ppu_rd = 0; #100;
            s_pdat = ppu_dat; s_cice = ppu_ciram_ce; s_chrce = chr_ce; s_ex = ppu_ex;
            s_dir = ppu_dir; s_chr = chr_map;
            #86 ppu_rd = 1; #30;
            if (ppu_dat !== 8'hzz) bad_ppu_idle = bad_ppu_idle + 1;
            #10;
        end
    endtask
    task ppu_write(input [13:0] addr, input [7:0] d);
        begin
            pa = addr; pdout = d; #120;
            pdrive = 1; ppu_wr = 0; #186;
            ppu_wr = 1; #20 pdrive = 0; #40;
        end
    endtask
    task chr_at(input [13:0] addr, input [8:0] want, input [255:0] what);
        begin ppu_read(addr); check(what, s_chr, want); end
    endtask

    // ---------------------------------------------------------------- PPU (rendering)
    reg render = 0;
    reg bg_hi = 0, spr_hi = 1;
    integer line = 241, dot = 0, frames = 0;
    reg [8:0] bg_chr, spr_chr;           // chr_map seen at line 50, dot 5 / dot 261
    // every read on line 50, by the dot its fetch starts: what the PPU reads,
    // CHR address, CIRAM select
    reg [7:0] dat50 [0:340];
    reg [8:0] chr50 [0:340];
    reg       cice50 [0:340];
    integer   rec_line = 50;             // the line dat50/chr50/cice50 record

    function [13:0] nt_of(input integer l, input integer t);
        nt_of = 14'h2000 | ((((l < 0 ? 0 : l) >> 3) * 32 + t) & 10'h3FF);
    endfunction

    // address of the fetch that starts at `d` on line `l` (d odd), or -1
    function integer fetch(input integer l, input integer d);
        integer f, t, nl;
        begin
            nl = (l == 261) ? 0 : l + 1;
            if (d >= 1 && d <= 255) begin
                t = (d - 1) / 8 + 2; f = ((d - 1) % 8) / 2;
                fetch = (f == 0) ? nt_of(l == 261 ? -1 : l, t) :
                        (f == 1) ? 14'h23C0 | (t >> 2) :
                        ((bg_hi ? 14'h1000 : 14'h0000) | ((t & 31) << 4) | (f == 3 ? 8 : 0));
            end else if (d >= 257 && d <= 319) begin
                f = ((d - 257) % 8) / 2;
                fetch = (f < 2) ? 14'h2FFF :
                        ((spr_hi ? 14'h1000 : 14'h0000) | 14'h0040 | (f == 3 ? 8 : 0));
            end else if (d >= 321 && d <= 335) begin
                t = (d - 321) / 8; f = ((d - 321) % 8) / 2;
                fetch = (f == 0) ? nt_of(nl, t) : (f == 1) ? 14'h23C0 :
                        ((bg_hi ? 14'h1000 : 14'h0000) | (t << 4) | (f == 3 ? 8 : 0));
            end else if (d == 337 || d == 339)
                fetch = nt_of(nl, 2);                       // = next line's dot-1 read
            else
                fetch = -1;
        end
    endfunction

    integer fa;
    initial forever begin
        wait (render);
        line = 241; dot = 0;
        while (render) begin
            if (line == 241 && dot == 0) frames = frames + 1;
            if ((line < 240 || line == 261) && dot[0] == 1'b1) begin
                fa = fetch(line, dot);
                if (fa >= 0) begin
                    pa = fa[13:0];
                    #93;
                    if (ppu_dat !== 8'hzz) bad_ppu_idle = bad_ppu_idle + 1;
                    #93.667;
                    ppu_rd = 0;
                    #93;
                    if (!pa[13] && ppu_dat !== 8'hzz) bad_ppu_pt = bad_ppu_pt + 1;
                    if (line == rec_line) begin
                        dat50[dot] = ppu_dat; chr50[dot] = chr_map; cice50[dot] = ppu_ciram_ce;
                    end
                    if (line == 50 && dot == 5)   bg_chr  = chr_map;
                    if (line == 50 && dot == 261) spr_chr = chr_map;
                    #93.667;
                    ppu_rd = 1;
                end else
                    #373.333;
                dot = dot + 2;
            end else begin
                #186.667;
                dot = dot + 1;
            end
            if (dot >= 341) begin
                dot = dot - 341;
                line = (line == 261) ? 0 : line + 1;
            end
        end
    end

    integer irq_line = -1, irq_dot = -1;
    integer i;
    reg [8:0] sp_ref, bg_ref;
    always @(negedge cpu_irq) if (cpu_irq === 1'b0) begin irq_line = line; irq_dot = dot; end

    task run_frames(input integer n);
        integer f0;
        begin f0 = frames; while (frames < f0 + n) rd(16'h0000); end
    endtask
    task wait_irq;
        integer n;
        begin n = 0; while (cpu_irq !== 1'b0 && n < 70000) begin rd(16'h0000); n = n + 1; end end
    endtask
    task wait_line(input integer l);
        begin while (line != l) rd(16'h0000); end
    endtask

    initial begin
        repeat (20) rd(16'h0000);
        reg_w(8'h84, 8'h0F);                 // 256 KB PRG
        reg_w(8'h85, 8'h3F);                 // 512 KB CHR ROM (all of A18: $5130 test)
        reg_w(8'h83, 8'h05);                 // -> MMC5

        // ================================================================ PRG
        prg8(16'hE000, 6'd31, "power-on: mode 3, $5117 = $FF -> last bank");
        wr(16'h5114, 8'h82); wr(16'h5115, 8'h85); wr(16'h5116, 8'h87);
        prg8(16'h8000, 6'd2, "mode 3 $8000 = $5114");
        prg8(16'hA000, 6'd5, "mode 3 $A000 = $5115");
        prg8(16'hC000, 6'd7, "mode 3 $C000 = $5116");
        wr(16'h5114, 8'h03);
        ram8(16'h8000, 3'd3, "mode 3 $5114 bit 7 = 0 -> RAM page 3");
        wr(16'h5117, 8'h1F);
        prg8(16'hE000, 6'd31, "$5117 bit 7 = 0 still ROM");
        wr(16'h5100, 8'h02); wr(16'h5115, 8'h84); wr(16'h5116, 8'h89);
        prg8(16'h8000, 6'd4, "mode 2 $8000 = $5115 & ~1");
        prg8(16'hA000, 6'd5, "mode 2 $A000 = $5115 | 1");
        prg8(16'hC000, 6'd9, "mode 2 $C000 = $5116");
        prg8(16'hE000, 6'd31, "mode 2 $E000 = $5117");
        wr(16'h5100, 8'h01); wr(16'h5115, 8'h86); wr(16'h5117, 8'h1D);
        prg8(16'hA000, 6'd7, "mode 1 $A000");
        prg8(16'hC000, 6'd28, "mode 1 $C000 = $5117 & ~1");
        prg8(16'hE000, 6'd29, "mode 1 $E000 = $5117 | 1");
        wr(16'h5100, 8'h00); wr(16'h5117, 8'h1F);
        prg8(16'h8000, 6'd28, "mode 0 $8000");
        prg8(16'hE000, 6'd31, "mode 0 $E000");
        wr(16'h5100, 8'h03);
        wr(16'h5113, 8'h05);
        ram8(16'h6000, 3'd5, "$6000 = $5113 page 5");
        cycle(16'h6001, 1, 8'h11); check("RAM write protected after reset", s_ram_we, 1); rd(16'h0000);
        wr(16'h5102, 8'h02); wr(16'h5103, 8'h01);
        cycle(16'h6001, 1, 8'h11); check("RAM write with $5102=2/$5103=1", s_ram_we, 0); rd(16'h0000);

        // ================================================================ CHR (rendering off)
        wr(16'h5101, 8'h03);
        wr(16'h5120, 8'h10); wr(16'h5121, 8'h11); wr(16'h5127, 8'h17);
        chr_at(14'h0000, 9'h010, "1K $0000 = $5120");
        chr_at(14'h0400, 9'h011, "1K $0400 = $5121");
        chr_at(14'h1C00, 9'h017, "1K $1C00 = $5127");
        wr(16'h5130, 8'h01); wr(16'h5120, 8'h22); wr(16'h5130, 8'h00);
        chr_at(14'h0000, 9'h122, "1K $5130 bit 0 taken at write time");
        wr(16'h5101, 8'h00); wr(16'h5127, 8'h03);
        chr_at(14'h0000, 9'd24, "8K $0000 = $5127 * 8");
        chr_at(14'h1C00, 9'd31, "8K $1C00");
        wr(16'h5101, 8'h01); wr(16'h5123, 8'h05); wr(16'h5127, 8'h06);
        chr_at(14'h0400, 9'd21, "4K $0400 = $5123 * 4 + 1");
        chr_at(14'h1000, 9'd24, "4K $1000 = $5127 * 4");
        wr(16'h5101, 8'h02); wr(16'h5121, 8'h0A); wr(16'h5127, 8'h0D);
        chr_at(14'h0400, 9'h015, "2K $0400 = $5121 * 2 + 1");
        chr_at(14'h1800, 9'h01A, "2K $1800 = $5127 * 2");
        wr(16'h5101, 8'h03);
        wr(16'h2000, 8'h20);                                  // 8x16 sprites
        wr(16'h512B, 8'h33);
        chr_at(14'h0C00, 9'h033, "8x16, set B last written: $0C00 = $512B");
        chr_at(14'h1C00, 9'h033, "set B repeats at $1C00");
        wr(16'h5120, 8'h10);
        chr_at(14'h0000, 9'h010, "set A last written: $0000 = $5120");
        wr(16'h2000, 8'h00);

        // ================================================================ nametables
        wr(16'h5105, 8'b11_10_01_00);
        ppu_read(14'h2001); check("NT0 CIRAM page 0: ce", s_cice, 0); check("NT0 A10", dut.ppu_ciram_a10, 0);
        check("NT0 not driven", s_pdat, 8'hzz);
        ppu_read(14'h2402); check("NT1 CIRAM page 1: ce", s_cice, 0);
        wr(16'h5106, 8'hAB); wr(16'h5107, 8'h02);
        ppu_read(14'h2C05);
        check("fill tile driven", s_pdat, 8'hAB);
        check("fill: CIRAM off", s_cice, 1);
        check("fill: CHR SRAM off", s_chrce, 1);
        check("fill: buffer on", s_ex, 0);
        check("fill: buffer towards PPU", s_dir, 0);
        ppu_read(14'h2FC1); check("fill attribute = $AA", s_pdat, 8'hAA);
        wr(16'h5104, 8'h02); wr(16'h5C10, 8'h5E);
        rd(16'h5C10);
        check("ExRAM CPU read (mode 2)", s_dat, 8'h5E);
        check("ExRAM read: PRG SRAM /OE off", s_prg_oe, 1);
        check("ExRAM read: save SRAM /OE off", s_ram_oe, 1);
        check("ExRAM read: released after M2 falls", s_after, 8'hzz);
        ppu_read(14'h2810); check("ExRAM NT in mode 2 reads $00", s_pdat, 8'h00);
        wr(16'h5104, 8'h00);
        ppu_read(14'h2810); check("ExRAM as nametable (mode 0)", s_pdat, 8'h5E);
        rd(16'h5C10); check("ExRAM mode 0: no CPU read", s_dat, 8'hzz);
        wr(16'h5C12, 8'h99);                                  // mode 0, not rendering: ignored
        ppu_write(14'h2811, 8'h77);                           // PPU writes ExRAM ($2007)
        wr(16'h5104, 8'h03);
        rd(16'h5C11); check("PPU write to ExRAM (mode 3 read)", s_dat, 8'h77);
        rd(16'h5C12); check("CPU write in mode 0 while not rendering ignored", s_dat, 8'h00);
        wr(16'h5C13, 8'h44);
        rd(16'h5C13); check("mode 3: CPU writes ignored", s_dat, 8'h00);
        wr(16'h5105, 8'h44);                                  // %01 00 01 00: vertical
        rd(16'h8000); check("ROM read: bus not driven", s_dat, 8'hzz);

        // ================================================================ multiplier
        wr(16'h5205, 8'h12); wr(16'h5206, 8'h34);
        rd(16'h5205); check("multiplier low", s_dat, 8'hA8);
        rd(16'h5206); check("multiplier high", s_dat, 8'h03);

        // ================================================================ sound (details: tb_mmc5_snd)
        check("cpu_exp driven in game mode (MMC5 audio)", cpu_exp !== 1'bz, 1);
        rd(16'h5015); check("$5015: no length counters running", s_dat, 8'h00);
        check("$5015 read: PRG SRAM /OE off", s_prg_oe, 1);
        wr(16'h5015, 8'h03); wr(16'h5003, 8'h08);
        rd(16'h5015); check("$5015: pulse 1 length loaded", s_dat, 8'h01);
        wr(16'h5015, 8'h00);
        rd(16'h5015); check("$5015 = 0 clears it", s_dat, 8'h00);
        wr(16'h5010, 8'h80); wr(16'h5011, 8'h00);
        repeat (3) rd(16'h0000);
        check("PCM IRQ on a $00 write", cpu_irq, 0);
        rd(16'h5010); check("$5010: IRQ flag", s_dat, 8'h80);
        repeat (3) rd(16'h0000);
        check("PCM IRQ acknowledged by the $5010 read", cpu_irq, 1);
        wr(16'h5010, 8'h00);

        // ================================================================ scanline IRQ
        wr(16'h2000, 8'h00); wr(16'h2001, 8'h18);
        wr(16'h5203, 8'd20); wr(16'h5204, 8'h80);
        render = 1;
        wait_irq;
        check("IRQ asserted", cpu_irq, 0);
        check("IRQ on line 20", irq_line, 20);
        check("IRQ at the start of the line (dot <= 8)", (irq_dot >= 0 && irq_dot <= 8), 1);
        rd(16'h5204);
        check("$5204: pending + in frame", s_dat, 8'hC0);
        repeat (3) rd(16'h0000);
        check("IRQ released by the $5204 read", cpu_irq, 1);
        wait_irq;
        check("next frame: IRQ on line 20 again", irq_line, 20);
        rd(16'h5204);
        wait_line(245); repeat (5) rd(16'h0000);
        rd(16'h5204); check("vblank: not in frame", s_dat, 8'h00);
        wr(16'h5204, 8'h00);

        // ================================================================ 8x16 CHR sets
        wr(16'h5120, 8'h40); wr(16'h5124, 8'h44);
        wr(16'h5128, 8'h50);
        wr(16'h2000, 8'h20);
        run_frames(1);
        check("8x16: background fetch uses set B", bg_chr, 9'h050);
        check("8x16: sprite fetch uses set A", spr_chr, 9'h044);
        wr(16'h2000, 8'h00);
        run_frames(1);
        check("8x8: background fetch uses set A", bg_chr, 9'h040);
        bg_ref = bg_chr;

        // ================================================================ extended attributes
        // line 50 = nametable row 6: tile t at NT offset 192 + t. Fetched on
        // line 50: tile 2 at dot 1, tile 3 at dot 9; prefetch of line 51's
        // tile 0 (offset 192) at dot 321.
        wr(16'h5104, 8'h02);
        wr(16'h5CC2, 8'b10_101010);          // tile 2: palette 2, page $2A
        wr(16'h5CC3, 8'b01_000111);          // tile 3: palette 1, page $07
        wr(16'h5CC0, 8'b11_010101);          // tile 0 (prefetch): palette 3, page $15
        wr(16'h5130, 8'h01);
        wr(16'h2000, 8'h00);
        run_frames(1);
        sp_ref = spr_chr;                    // sprite bank without ext. attributes
        wr(16'h5104, 8'h01);                 // extended attributes on
        run_frames(1);
        check("ext: NT read still from CIRAM", cice50[1], 0);
        check("ext: NT read not driven by the MMC5", dat50[1], 8'hzz);
        check("ext: tile 2 attribute = palette 2 x4 ($AA)", dat50[3], 8'hAA);
        check("ext: attribute read: CIRAM off", cice50[3], 1);
        check("ext: tile 2 pattern lo: $5130.0 + page $2A", chr50[5], 9'b1_101010_00);
        check("ext: tile 2 pattern hi: same page", chr50[7], 9'b1_101010_00);
        check("ext: tile 3 attribute = palette 1 x4 ($55)", dat50[11], 8'h55);
        check("ext: tile 3 pattern: page $07", chr50[13], 9'b1_000111_00);
        check("ext: prefetch attribute = palette 3 x4 ($FF)", dat50[323], 8'hFF);
        check("ext: prefetch pattern: page $15", chr50[325], 9'b1_010101_00);
        check("ext: sprite fetch keeps the normal bank", spr_chr, sp_ref);
        check("ext: sprite garbage NT read not answered", dat50[257], 8'hzz);
        check("ext: dummy NT read at dot 339 not answered", dat50[339], 8'hzz);
        wr(16'h5130, 8'h00);                 // $5130 is used live here
        run_frames(1);
        check("ext: $5130 used live", chr50[5], 9'b0_101010_00);
        wr(16'h5104, 8'h00);                 // mode 0: back to phase-1 behaviour
        run_frames(1);
        check("mode 0: attribute read from CIRAM again", cice50[3], 0);
        check("mode 0: attribute read not driven", dat50[3], 8'hzz);
        check("mode 0: pattern uses the bank registers again", chr50[5], bg_ref);
        wr(16'h5104, 8'h01); wr(16'h2001, 8'h00);
        run_frames(1);
        check("ext + rendering off ($2001=0): no attribute answer", dat50[3], 8'hzz);
        wr(16'h2001, 8'h18); wr(16'h5104, 8'h00);

        // ================================================================ vertical split
        // ExRAM: tile byte at row r, column c = {r[2:0], c[4:0]}; the
        // attribute row 1 ($3C8-$3CF, counter 32-63) = $E4 (pairs: top-left
        // 0, top-right 1, bottom-left 2, bottom-right 3), the other rows $1B. Column c's nametable read on its
        // own line starts at dot (c - 2) * 8 + 1; columns 0/1 are the
        // previous line's prefetch at dots 321/329.
        wr(16'h5104, 8'h02);
        for (i = 0; i < 960; i = i + 1)
            wr(16'h5C00 + i, i[7:0]);       // = {row[2:0], column}
        for (i = 960; i < 1024; i = i + 1)  // attribute row 1 (counter 32-63): $E4,
            wr(16'h5C00 + i, (i >= 968 && i < 976) ? 8'hE4 : 8'h1B);   // others $1B
        wr(16'h5104, 8'h00);
        wr(16'h5202, 8'h25);                 // split pattern page $25 (4 KB)
        wr(16'h5201, 8'd0);
        wr(16'h5200, 8'h84);                 // left split, 4 tiles
        rec_line = 50;                       // counter 50: row 6, counter bit 4 = 1
        run_frames(1);
        check("split L4: col 2 NT from ExRAM row 6", dat50[1], 8'hC2);
        check("split L4: col 2 NT: CIRAM off", cice50[1], 1);
        check("split L4: col 2 attribute: bottom-right pair x4", dat50[3], 8'hFF);
        check("split L4: col 2 attribute: CIRAM off", cice50[3], 1);
        check("split L4: col 2 pattern lo: page $25", chr50[5], 9'b0100101_00);
        check("split L4: col 2 pattern hi: page $25", chr50[7], 9'b0100101_00);
        check("split L4: col 3 NT", dat50[9], 8'hC3);
        check("split L4: col 4 NT normal (CIRAM)", cice50[17], 0);
        check("split L4: col 4 NT not driven", dat50[17], 8'hzz);
        check("split L4: col 4 attribute not driven", dat50[19], 8'hzz);
        check("split L4: col 4 pattern: normal bank", chr50[21], bg_ref);
        check("split L4: prefetch col 0 NT (next line, row 6)", dat50[321], 8'hC0);
        check("split L4: prefetch col 0 attribute: bottom-left pair x4", dat50[323], 8'hAA);
        check("split L4: prefetch col 1 NT", dat50[329], 8'hC1);
        check("split L4: prefetch pattern: page $25", chr50[325], 9'b0100101_00);
        check("split: sprite pattern keeps its bank", spr_chr, sp_ref);
        check("split: sprite garbage NT read not answered", dat50[257], 8'hzz);
        wr(16'h5200, 8'hDE);                 // right split from tile 30
        run_frames(1);
        check("split R30: col 29 NT normal", cice50[217], 0);
        check("split R30: col 30 NT from ExRAM", dat50[225], 8'hDE);
        check("split R30: col 30 attribute: bottom-right pair x4", dat50[227], 8'hFF);
        check("split R30: col 32 attribute: bottom-left pair x4", dat50[243], 8'hAA);
        check("split R30: col 31 attribute: bottom-right pair x4", dat50[235], 8'hFF);
        check("split R30: col 33 NT (column 1 of the row)", dat50[249], 8'hC1);
        check("split R30: prefetch col 0 normal", cice50[321], 0);
        // counter: start value, wrap after 239, 240-255 count on to 255
        wr(16'h5200, 8'h84);
        wr(16'h5201, 8'd236);
        rec_line = 3;                        // 239: row 29
        run_frames(1);
        check("split counter: line 3 = 236 + 3 = 239 (row 29)", dat50[1], 8'hA2);
        check("split counter: prefetch on line 3 = next line's row 0", dat50[321], 8'h00);
        rec_line = 4;                        // wrapped: 0
        run_frames(1);
        check("split counter: line 4 wraps to 0 (row 0)", dat50[1], 8'h02);
        wr(16'h5201, 8'd248);
        rec_line = 7;                        // 255: row 31 = attribute area
        run_frames(1);
        check("split counter: 248 + 7 = 255 shows the attribute area", dat50[1], 8'h1B);
        rec_line = 8;
        run_frames(1);
        check("split counter: 255 -> 0", dat50[1], 8'h02);
        wr(16'h5201, 8'd0);
        rec_line = 50;
        // extended attributes next to the split (mode 1)
        wr(16'h5104, 8'h01);
        run_frames(1);
        check("split + ext: col 2 attribute from the split", dat50[3], 8'hFF);
        check("split + ext: col 2 pattern: split page", chr50[5], 9'b0100101_00);
        check("split + ext: col 5 attribute: ext palette of ExRAM $C5 x4", dat50[27], 8'hFF);
        check("split + ext: col 5 pattern: ext page $05", chr50[29], 9'b0_000101_00);
        wr(16'h5104, 8'h02);                 // mode 2: no split
        run_frames(1);
        check("split off in mode 2: col 2 NT from CIRAM", cice50[1], 0);
        check("split off in mode 2: not driven", dat50[1], 8'hzz);
        wr(16'h5104, 8'h00); wr(16'h2001, 8'h00);
        run_frames(1);
        check("split + rendering off ($2001=0): not driven", dat50[1], 8'hzz);
        wr(16'h2001, 8'h18);
        wr(16'h5200, 8'h04);                 // threshold set, split disabled
        run_frames(1);
        check("split disabled ($5200 bit 7 = 0): col 2 normal", cice50[1], 0);

        // ================================================================ in-frame clears
        wait_line(100);
        wr(16'h2001, 8'h00); rd(16'h5204);
        check("$2001 = 0 clears in frame", s_dat[6], 0);
        wr(16'h2001, 8'h18);
        wait_line(120); repeat (40) rd(16'h0000);
        rd(16'h5204); check("rendering: in frame again", s_dat[6], 1);
        rd(16'hFFFA); rd(16'h5204);
        check("NMI vector read clears in frame", s_dat[6], 0);
        render = 0;
        repeat (10) rd(16'h0000);
        rd(16'h5204); check("PPU reads stop: in frame times out", s_dat[6], 0);

        check("monitor: CPU bus never driven while M2 low", bad_cpu_low, 0);
        check("monitor: PPU bus never driven on pattern reads", bad_ppu_pt, 0);
        check("monitor: PPU bus never driven while /RD is high", bad_ppu_idle, 0);
        $display("%0d checks, %0d failed", checks, fails);
        if (fails == 0) $display("PASS");
        $finish;
    end
endmodule
