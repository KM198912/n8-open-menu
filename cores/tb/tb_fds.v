// n8-open: testbench for the FDS core (map_fds.v), Icarus Verilog:
//   iverilog -g2005 -o tb_fds tb_fds.v ../nrom/*.v
// Covers the memory map, the registers, the timer IRQ (incl. the PAL
// correction), the BIOS stub, the disk stream (lead-in, blocks, CRC, gaps,
// end of disk) through the read window, and a write session through the
// write window with the block table update. The lead-in is shortened to
// LEADIN byte times (the real 3537 is checked against the BIOS by
// tools/n8sim/fds_boot.py), so a run takes seconds.
`timescale 1ns/1ps

module tb_fds;
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

    localparam LEADIN = 200;
    defparam dut.g_fds.fds.LEADIN = LEADIN;
    localparam HOLD = 2000, EJECT = 3000;   // side swap, shortened
    defparam dut.g_fds.fds.SWAP_HOLD = HOLD;
    defparam dut.g_fds.fds.SWAP_EJECT = EJECT;
    n8_top #(.MAPPER(20)) dut (
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
    reg [7:0] s_dat;
    reg s_prg_ce, s_prg_we, s_prg_oe, s_ram_ce, s_ram_we, s_a10, s_chr_we;
    integer cyc = 0;

    task cycle(input [15:0] addr, input wr, input [7:0] d);
        begin
            m2 = 0; a = addr; rw = ~wr; dout = d; drive = wr;
            #280;
            m2 = 1;
            #240;
            s_prg_map = prg_map; s_prg_ce = prg_ce; s_prg_we = prg_we; s_prg_oe = prg_oe;
            s_ram_ce = ram_ce; s_a10 = ppu_ciram_a10; s_chr_map = chr_map; s_dat = cpu_dat;
            s_ram_we = ram_we;
            s_chr_we = chr_we;
            #40;
            m2 = 0;
            #10;
            drive = 0;
            cyc = cyc + 1;
        end
    endtask
    task rd(input [15:0] addr);  begin cycle(addr, 0, 8'h00); end endtask
    // a read cycle in which the testbench drives the data bus (a controller)
    task rdd(input [15:0] addr, input [7:0] d);
        begin
            m2 = 0; a = addr; rw = 1; dout = d; drive = 1;
            #280; m2 = 1; #280; m2 = 0; #10; drive = 0;
            cyc = cyc + 1;
        end
    endtask
    // one pad read as games do it: strobe, then 8 reads (A B Sel St U D L R)
    task pad_frame(input [7:0] btn);
        integer k;
        begin
            wr(16'h4016, 8'h01);
            rdd(16'h4016, 8'h41);          // while the strobe is high: ignored
            wr(16'h4016, 8'h00);
            for (k = 0; k < 8; k = k + 1)
                rdd(16'h4016, { 7'b0100000, btn[k] });
            rdd(16'h4016, 8'h41);          // 9th read: ignored
        end
    endtask
    task wr(input [15:0] addr, input [7:0] d);  begin cycle(addr, 1, d); rd(16'h0000); end endtask
    task reg_w(input [7:0] idx, input [7:0] v);  begin wr(16'h4400, idx); wr(16'h4401, v); end endtask
    task tbl_w(input [15:0] v);  begin reg_w(8'h93, v[7:0]); reg_w(8'h93, v[15:8]); end endtask

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

    integer cnt;
    task until_irq(input integer n);
        begin cnt = 0; while (cpu_irq !== 1'b0 && cnt < n) begin rd(16'h0000); cnt = cnt + 1; end end
    endtask
    // wait for the byte transfer flag ($4030 bit 7), at most n polls
    task until_xfer(input integer n);
        begin
            cnt = 0;
            rd(16'h4030);
            while (!s_dat[7] && cnt < n) begin rd(16'h4030); cnt = cnt + 1; end
        end
    endtask
    // the stub's operands: current read / write address
    reg [15:0] r_op, w_op;
    task get_rop;  begin rd(16'h5701); r_op[7:0] = s_dat; rd(16'h5702); r_op[15:8] = s_dat; end endtask
    task get_wop;  begin rd(16'h5705); w_op[7:0] = s_dat; rd(16'h5706); w_op[15:8] = s_dat; end endtask

    // ---------------------------------------------------------------- PPU model (as tb_vrc6)
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
    // Zelda II's NMI: timer $16C0 (5824 cycles), one-shot, right after vblank starts
    task game_frame;
        begin
            wait_line(241);
            wr(16'h4020, 8'hC0);
            wr(16'h4021, 8'h16);
            wr(16'h4022, 8'h02);
            irq_line = -1;
            until_irq(40000);
            rd(16'h4030);                      // acknowledge
        end
    endtask
    integer ntsc_line;
    task menu_again;   // back to menu mode, as after a reset (registers are menu-only)
        begin force dut.osmap.map_idx = 8'hFF; rd(16'h0000); release dut.osmap.map_idx; end
    endtask

    integer i, t0, t1, n_ok, prev_xfer;
    reg ok;

    initial begin
        repeat (20) rd(16'h0000);
        reg_w(8'h88, 8'h00);
        reg_w(8'h84, 8'h1F);                   // no PRG mask
        reg_w(8'h85, 8'h80);                   // CHR RAM
        reg_w(8'h86, 8'h00);
        // block table, side 0: block 1 (56), block 2 (2), block 3 (16), block 4 (17)
        reg_w(8'h91, 8'h00); reg_w(8'h92, 8'h00);
        tbl_w(16'd0); tbl_w(16'd56); tbl_w(16'd58); tbl_w(16'd74); tbl_w(16'd91); tbl_w(16'hFFFF);
        // side 1: one block
        reg_w(8'h91, 8'h00); reg_w(8'h92, 8'h01);
        tbl_w(16'd0); tbl_w(16'd56); tbl_w(16'hFFFF);
        check("table written: side 0 entry 3", dut.g_fds.fds.tbl[3], 74);
        check("table written: side 0 entry 5", dut.g_fds.fds.tbl[5], 16'hFFFF);
        check("table written: side 1 entry 1", dut.g_fds.fds.tbl[257], 56);
        reg_w(8'h94, 8'h80);                   // no disk yet
        reg_w(8'h83, 8'd20);

        // ---------------------------------------------------------------- memory map
        rd(16'h6000); check("$6000 = RAM page 0", s_prg_map, 0);
        check("$6000 PRG SRAM selected", s_prg_ce, 0);
        check("$6000 save SRAM not selected", s_ram_ce, 0);
        rd(16'h8000); check("$8000 = RAM page 8", s_prg_map, 8);
        rd(16'hDFFF); check("$DFFF = RAM page 31", s_prg_map, 31);
        rd(16'hE000); check("$E000 = BIOS page 32 ($08000)", s_prg_map, 32);
        rd(16'hFFFC); check("$FFFC = BIOS page 39", s_prg_map, 39);
        cycle(16'h6123, 1, 8'h55); check("RAM write $6123: PRG /WE", s_prg_we, 0);
        cycle(16'hD000, 1, 8'h55); check("RAM write $D000: PRG /WE", s_prg_we, 0);
        cycle(16'hE123, 1, 8'h55); check("BIOS write ignored", s_prg_we, 1);
        cycle(16'h5123, 1, 8'h55); check("write $5123: nothing", s_prg_we, 1);
        rd(16'h0000);
        pa = 14'h0010; ppu_wr = 0; #20; rd(16'h0000); check("CHR RAM write", s_chr_we, 0);
        ppu_wr = 1; #20;

        // ---------------------------------------------------------------- registers
        rd(16'h4033); check("$4033 = $80 (battery good)", s_dat, 8'h80);
        rd(16'h4032); check("$4032 no disk: $47", s_dat, 8'h47);
        rd(16'h5700); check("stub $5700 = LDX abs", s_dat, 8'hAE);
        rd(16'h5703); check("stub $5703 = RTS", s_dat, 8'h60);
        rd(16'h5704); check("stub $5704 = STA abs", s_dat, 8'h8D);
        rd(16'h5707); check("stub $5707 = RTS", s_dat, 8'h60);
        rd(16'h5702); check("stub read operand high = $58", s_dat, 8'h58);
        rd(16'h5706); check("stub write operand high = $5C", s_dat, 8'h5C);
        rd(16'h4030); check("$4030 read: core drives (PRG SRAM off)", s_prg_oe, 1);

        // ---------------------------------------------------------------- timer
        wr(16'h4020, 8'd100); wr(16'h4021, 8'd0);
        wr(16'h4022, 8'h02);                   // disk I/O still off: ignored
        until_irq(400); check("timer ignored while $4023 bit 0 = 0", cnt, 400);
        wr(16'h4023, 8'h83);
        wr(16'h4022, 8'h02);                   // one-shot, 100
        until_irq(400); check("timer: IRQ on the 101st cycle after the write (reload 100)", cnt, 100);
        rd(16'h4030); check("$4030 bit 0: timer IRQ", s_dat[0], 1);
        rd(16'h0000); check("$4030 read acknowledges", cpu_irq, 1);
        until_irq(400); check("one-shot: no second IRQ", cnt, 400);
        wr(16'h4020, 8'd50);
        wr(16'h4022, 8'h03);                   // repeat
        until_irq(200); rd(16'h4030);
        until_irq(200); check("repeat: next IRQ 51 cycles later (50 polls after the ack)", cnt, 50);
        wr(16'h4022, 8'h00);                   // stop + acknowledge
        check("$4022 = 0 acknowledges", cpu_irq, 1);
        until_irq(200); check("$4022 = 0 stops the timer", cnt, 200);

        // ---------------------------------------------------------------- mirroring
        wr(16'h4025, 8'h26);
        pa = 14'h2400; #20; rd(16'h0000); check("$4025 bit 3 = 0: vertical (A10)", s_a10, 1);
        pa = 14'h2800; #20; rd(16'h0000); check("vertical: $2800 -> A10 = 0", s_a10, 0);
        wr(16'h4025, 8'h2E);
        pa = 14'h2800; #20; rd(16'h0000); check("$4025 bit 3 = 1: horizontal (A11)", s_a10, 1);
        rd(16'h4030); check("$4030 bit 3 mirrors $4025 bit 3", s_dat[3], 1);
        wr(16'h4025, 8'h26);

        // ---------------------------------------------------------------- disk: start
        menu_again; reg_w(8'h94, 8'h00); reg_w(8'h83, 8'd20);   // insert side 0
        wr(16'h4023, 8'h83);
        rd(16'h4032); check("$4032 disk in, motor off: not ready ($42)", s_dat, 8'h42);
        wr(16'h4025, 8'h27);                   // transfer reset released, motor still off
        wr(16'h4025, 8'h25);                   // motor on, read mode
        repeat (400) rd(16'h0000);
        rd(16'h4032); check("motor on: ready ($40)", s_dat, 8'h40);
        wr(16'h4025, 8'h65);                   // wait for the first block
        t0 = cyc;
        until_xfer(700000);
        t1 = cyc;
        check_rng("first transfer after the lead-in (LEADIN byte times)", t1 - t0, (LEADIN - 1) * 149, (LEADIN + 2) * 150);
        // block 1: 56 bytes through the read window
        n_ok = 0; prev_xfer = t1;
        for (i = 0; i < 56; i = i + 1) begin
            if (i > 0) begin
                until_xfer(400);
                if (i > 1 && (cyc - prev_xfer < 147 || cyc - prev_xfer > 152))
                    $display("  transfer %0d: %0d cycles after the previous one", i, cyc - prev_xfer);
                prev_xfer = cyc;
            end
            get_rop;
            if (r_op == (16'h5800 | i)) n_ok = n_ok + 1;
            if (i != 54)
                rd(r_op);                      // the byte (acknowledges)
            else
                repeat (160) rd(16'h0000);     // 54 not taken until 55 arrives
            if (i == 3) begin
                check("read window: side 0 = save SRAM $00000 (page 0)", s_prg_map, 0);
                check("read window: save SRAM selected", s_ram_ce, 1);
                check("read window: PRG SRAM not selected", s_prg_ce, 1);
            end
        end
        check("block 1: 56 transfers at offsets 0-55", n_ok, 56);
        rd(16'h4030); check("window read acknowledged the transfer", s_dat[7], 0);
        until_xfer(400); rd(16'h4031);         // CRC 1 (BIOS skip path)
        until_xfer(400); check("CRC 2 arrives", cnt < 400, 1);
        rd(16'h4031);
        rd(16'h4030); check("byte 54 not taken: overrun -> CRC error bit", s_dat[4], 1);
        check("not at the end yet", s_dat[6], 0);
        // block 2 after the gap
        wr(16'h4025, 8'h25);                   // transfers off
        rd(16'h4031);                          // a gap transfer may be pending: acknowledge
        repeat (300) rd(16'h0000);
        wr(16'h4025, 8'h65);
        until_xfer(30000); get_rop;
        check("block 2 starts at offset 56", r_op, 16'h5800 | 56);
        rd(r_op);
        until_xfer(400); check("block 2 byte 2 in time", cnt < 400, 1);
        get_rop; check("block 2 byte 2 at offset 57", r_op, 16'h5800 | 57); rd(r_op);
        until_xfer(400); rd(16'h4031);
        until_xfer(400); rd(16'h4031);
        rd(16'h4030); check("block 2 taken in time: CRC error bit clear", s_dat[4], 0);
        until_xfer(400); check("transfers go on in the gap while bit 6 is set", cnt < 400, 1);
        rd(16'h4031);

        // ---------------------------------------------------------------- write session: rewrite block 3
        wr(16'h4025, 8'h25);
        wr(16'h4025, 8'h21);                   // write mode, transfers off
        wr(16'h4024, 8'h00);
        rd(16'h4031);
        wr(16'h4025, 8'h61);                   // session: block 3
        until_xfer(400); check("write mode: transfers", cnt < 400, 1);
        get_wop; check("write starts at block 3 (offset 58)", w_op, 16'h5C00 | 58);
        cycle(w_op, 1, 8'h80); check("end mark not stored", s_prg_we, 1);
        rd(16'h0000);
        n_ok = 0;
        for (i = 0; i < 10; i = i + 1) begin
            until_xfer(400);
            get_wop;
            cycle(w_op, 1, 8'h30 + i);
            if (w_op == (16'h5C00 | (58 + i)) && s_ram_we == 0 && s_ram_ce == 1 && s_prg_ce == 1 &&
                s_prg_map == 0) n_ok = n_ok + 1;
            rd(16'h0000);
        end
        check("10 bytes stored at offsets 58-67", n_ok, 10);
        cycle(16'h5C00 | 70, 1, 8'h00); check("window write without a transfer: still stored in order", s_ram_we, 0);
        rd(16'h0000);
        // the BIOS's end of block ($E729 -> stub $5708): flush byte, not stored
        rd(16'h5708); check("stub $5708 = STA abs", s_dat, 8'h8D);
        rd(16'h570B); check("stub $570B = JMP abs", s_dat, 8'h4C);
        rd(16'h570D); check("stub $570D = $E7 (JMP $E7A3)", s_dat, 8'hE7);
        wr(16'h570F, 8'h00);
        until_xfer(400);
        get_wop;
        cycle(w_op, 1, 8'hEE); check("flush byte not stored", s_prg_we, 1);
        rd(16'h0000);
        get_wop; check("flush byte not counted (next address still 69)", w_op, 16'h5C00 | 69);
        wr(16'h4025, 8'h71);                   // CRC transfer bit: session goes on
        repeat (400) rd(16'h0000);             // write mode: flags keep coming (not taken)
        rd(16'h4030); check("write mode, untaken: flag set", s_dat[7], 1);
        wr(16'h4025, 8'h25);                   // read mode: session ends
        rd(16'h4030); check("bit 6 cleared: flag reads 0", s_dat[7], 0);
        repeat (5) rd(16'h0000);
        check("block 3 shorter: new end 69", dut.g_fds.fds.tbl[3], 69);
        check("blocks after it dropped", dut.g_fds.fds.tbl[4], 16'hFFFF);
        cycle(16'h5C10, 1, 8'h00); check("read mode: window write not stored", s_prg_we, 1);
        rd(16'h0000);
        // the head goes on: CRC, gap, then the end of the disk (no block 4)
        wr(16'h4025, 8'h65);
        cnt = 0; rd(16'h4030);
        while (!s_dat[6] && cnt < 30000) begin rd(16'h4030); cnt = cnt + 1; end
        check_rng("end of disk after CRC + gap", cnt * 1, 100 * 149 / 1, 130 * 150);
        rd(16'h4032); check("end of disk: not ready", s_dat[1], 1);
        // the BIOS's short reset pulse ($xE, $xF, $xD a few cycles apart):
        // the head must go back to the start, not stay where it was
        wr(16'h4025, 8'h24);
        wr(16'h4025, 8'h25);
        repeat (300) rd(16'h0000);
        rd(16'h4030); check("short reset pulse: end of disk cleared", s_dat[6], 0);
        rd(16'h4032); check("short reset pulse: ready again (lead-in)", s_dat[1], 0);

        // ---------------------------------------------------------------- transfer IRQ
        wr(16'h4025, 8'hE1);                   // write mode, transfers, IRQ on
        until_irq(400); check("transfer IRQ", cnt < 400, 1);
        wr(16'h4024, 8'h00);
        check("$4024 write acknowledges the transfer IRQ", cpu_irq, 1);
        wr(16'h4025, 8'h26);

        // ---------------------------------------------------------------- side select
        menu_again; reg_w(8'h94, 8'h01); reg_w(8'h83, 8'd20);
        rd(16'h5800); check("side 1: PRG SRAM $20000", s_prg_map[8:6], 2);
        check("side 1: PRG SRAM selected", s_prg_ce, 0);
        check("side 1: save SRAM not selected", s_ram_ce, 0);
        menu_again; reg_w(8'h94, 8'h02); reg_w(8'h83, 8'd20);
        rd(16'h5800); check("side 2: PRG SRAM $30000", s_prg_map[8:6], 3);
        check("side 2: PRG SRAM selected", s_prg_ce, 0);
        menu_again; reg_w(8'h94, 8'h03); reg_w(8'h83, 8'd20);
        rd(16'h5800); check("side 3: PRG SRAM $40000", s_prg_map[8:6], 4);
        check("side 3: PRG SRAM selected", s_prg_ce, 0);
        check("side 3: save SRAM not selected", s_ram_ce, 0);
        menu_again; reg_w(8'h94, 8'h00); reg_w(8'h83, 8'd20);

        // ---------------------------------------------------------------- side swap (Select + Down)
        menu_again; reg_w(8'h95, 8'h02); reg_w(8'h94, 8'h00); reg_w(8'h83, 8'd20);
        wr(16'h4023, 8'h83);
        wr(16'h4025, 8'h25);
        for (i = 0; i < 12; i = i + 1) begin   // Select alone, > HOLD
            pad_frame(8'h04);
            repeat (300) rd(16'h0000);
        end
        rd(16'h4032); check("Select alone: no swap", s_dat[0], 0);
        pad_frame(8'h20);                      // Down alone, then nothing
        pad_frame(8'h00);
        t0 = cyc;  t1 = -1;
        for (i = 0; i < 40 && t1 < 0; i = i + 1) begin
            pad_frame(8'h24);                  // Select + Down held
            repeat (100) rd(16'h0000);
            rd(16'h4032);
            if (s_dat[0]) t1 = cyc;
        end
        check_rng("Select + Down: eject after the hold time", t1 - t0, HOLD, HOLD + 400);
        check("ejected: $4032 = $47 (no disk, not ready, protected)", s_dat, 8'h47);
        t0 = cyc;  t1 = -1;
        for (i = 0; i < 40 && t1 < 0; i = i + 1) begin
            pad_frame(8'h24);                  // still held
            repeat (100) rd(16'h0000);
            rd(16'h4032);
            if (!s_dat[0]) t1 = cyc;
        end
        check_rng("inserted again after the eject time", t1 - t0, EJECT - 400, EJECT + 400);
        check("next side: B", dut.g_fds.fds.side, 1);
        for (i = 0; i < 30; i = i + 1) begin   // keep holding: no second swap
            pad_frame(8'h24);
            repeat (100) rd(16'h0000);
        end
        rd(16'h4032); check("held on: no second eject", s_dat[0], 0);
        check("held on: still side B", dut.g_fds.fds.side, 1);
        pad_frame(8'h00);                      // release, press again
        for (i = 0; i < 80; i = i + 1) begin
            pad_frame(8'h24);
            repeat (100) rd(16'h0000);
        end
        check("second swap: back to side A (2 sides)", dut.g_fds.fds.side, 0);
        rd(16'h4032); check("second swap: disk in", s_dat[0], 0);
        pad_frame(8'h00);
        wr(16'h4025, 8'h26);

        // ---------------------------------------------------------------- NTSC game on PAL
        wr(16'h4023, 8'h83);
        ppu_run = 1; pal = 0;
        game_frame;
        ntsc_line = irq_line;
        check_rng("NTSC: Zelda II's timer splits in the picture", ntsc_line, 20, 40);
        ppu_run = 0; repeat (5) rd(16'h0000);
        ppu_run = 1; pal = 1;
        game_frame;
        check_rng("PAL, no fix: IRQ in vblank (split before the picture)", irq_line, 241, 311);
        $display("  NTSC line %0d, PAL without fix line %0d", ntsc_line, irq_line);
        menu_again; reg_w(8'h86, 8'h40); reg_w(8'h83, 8'd20);
        wr(16'h4023, 8'h83);
        game_frame;
        $display("  PAL with fix line %0d", irq_line);
        check_rng("PAL, fix on: same line as NTSC (+-1)", irq_line, ntsc_line - 1, ntsc_line + 1);
        game_frame;
        check_rng("PAL, fix on: second frame the same (+-1)", irq_line, ntsc_line - 1, ntsc_line + 1);
        ppu_run = 0; repeat (5) rd(16'h0000);
        wr(16'h4020, 8'hFF); wr(16'h4021, 8'h7F);
        wr(16'h4022, 8'h02);                   // 32767: crosses the hold window, rendering off
        until_irq(60000);
        check_rng("fix on, rendering off: plain count + capped hold", cnt, 32768 + 5400 - 150, 32768 + 5400 + 50);

        $display("tb_fds: %0d checks, %0d failed", checks, fails);
        $finish;
    end
endmodule
