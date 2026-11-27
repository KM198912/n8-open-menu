// n8-open: Famicom Disk System RAM adapter for the EverDrive N8 clone.
//
// Written from the public documentation (NESdev wiki: Family Computer Disk
// System, FDS disk format, FDS file format), not from any existing HDL.
//
// Memory (all addresses are SRAM offsets):
//   PRG SRAM  $00000-$07FFF  32 KB RAM at CPU $6000-$DFFF
//             $08000-$09FFF  BIOS at $E000-$FFFF (the user's own dump,
//                            loaded and patched by the menu), read-only
//             $20000, $30000, $40000   disk sides 1, 2, 3
//   save SRAM $00000-$0FFFF  disk side 0 - battery backed: what the game
//                            writes there survives power-off, the menu
//                            writes it back to the .fds file at its next
//                            start. One side only: the save SRAM's A17 is
//                            not driven by the FPGA on this board (128 KB
//                            reachable), and the menu uses the rest.
// Disk sides in .fds form: blocks back to back, no gaps, no CRCs (65500
// bytes used of 64 KB).
// CHR: 8 KB RAM. Mirroring: $4025 bit 3 (0 vertical, 1 horizontal).
//
// The board limit that shapes this core: the SRAMs take A0-A9 straight from
// the console's address bus, so the FPGA cannot fetch a disk byte by itself.
// The disk data reaches the CPU through two 1 KB windows, with the low 10
// address bits supplied by the CPU:
//   $5800-$5BFF  read window: the page holding the current disk byte
//   $5C00-$5FFF  write window: the page of the next byte to be written
// and the CPU learns the address from an 8-byte stub the core serves:
//   $5700  AE lo hi   LDX $58xx   (the current disk byte)
//   $5703  60         RTS
//   $5704  8D lo hi   STA $5Cxx   (the next byte to write)
//   $5707  60         RTS
//   $5708  8D 0F 57   STA $570F   ("the next write is the flush byte")
//   $570B  4C A3 E7   JMP $E7A3   (the BIOS's wait for a transfer)
// The menu patches the BIOS's IRQ handler to call them: $E1CE LDX $4031 ->
// JSR $5700, $E1D1 STA $4024 -> JSR $5704. A window read counts as a $4031
// read, a window write as a $4024 write (both acknowledge the byte transfer).
// And the end of every block write, $E729 JSR $E7A3 -> JSR $5708: there the
// BIOS waits for one more transfer and the IRQ handler writes whatever is in
// A; on a real drive that byte never reaches the disk (the BIOS then sets
// the CRC bit and the drive sends the CRC in its place). The core must not
// store it either - it would lengthen the block (dropping the blocks after
// it: Zelda II's save failed with ERR.24) and overwrite the next block.
// The fourth patch serves the automatic side swap: the BIOS's disk check
// ($E445: compares 10 bytes of block 1 with the ID the game passes in
// ($00),Y; $FF = any) is entered through $E445 JSR $E6E3 -> JSR $5720, a
// second stub that hands the wanted ID to the core before the drive starts:
//   $5720  A0 09      LDY #9
//   $5722  B1 00      LDA ($00),Y
//   $5724  99 10 57   STA $5710,Y     (the core takes byte Y)
//   $5727  88         DEY
//   $5728  10 F8      BPL $5722
//   $572A  4C E3 E6   JMP $E6E3      (the BIOS's own start)
// Everything else - block headers, file selection, the license check, all
// register accesses - is the BIOS's own code. Programs that read $4031
// themselves instead of through the BIOS get $00 (not supported).
//
// Registers (game mode):
//   $4020/$4021  timer reload low/high
//   $4022        bit 0 repeat, bit 1 enable (copies the reload into the
//                counter); any write acknowledges the timer IRQ
//   $4023        bit 0 disk I/O enable (0: timer and transfer stop, IRQs off)
//   $4024        write data (acknowledges the transfer; the byte itself only
//                arrives through the write window)
//   $4025        bit 0 transfer reset (0 = head back to the start), bit 1
//                motor (0 = on), bit 2 mode (1 read, 0 write), bit 3
//                mirroring, bit 4 CRC transfer, bit 6 transfer enable
//                (read: wait for the next block start), bit 7 transfer IRQ
//   $4030  R     bit 0 timer IRQ, bit 3 mirroring, bit 4 CRC error, bit 6
//                end of disk, bit 7 byte transferred; reading acknowledges
//                the timer IRQ. The image itself is never damaged, so bit 4
//                reports an overrun instead: a block byte arrived while the
//                previous one was not yet taken (the BIOS then shows ERR.27
//                rather than loading a file with a byte missing).
//   $4031  R     $00, acknowledges the transfer (BIOS skip path)
//   $4032  R     bit 0 no disk, bit 1 not ready, bit 2 write protected
//                (= no disk); bits 7:3 = $40
//   $4033  R     $80 (battery good)
// Sound ($4040-$4097): fds_snd.v, out on cpu_exp through aud_dac.v (gain
// $89 like VRC6). Not implemented: the DRAM refresh watchdog.
//
// Disk timing: one byte every 149 1/3 CPU cycles (1792 master clocks). The
// head runs from the start of the side while the motor is on and transfer
// reset is released: lead-in gap (LEADIN byte times), then per block the
// block bytes, 2 CRC byte times and a gap (GAP byte times); after the last
// block the end-of-disk bit is set and the drive reports "not ready".
// Read mode: transfers start at the end of the first gap after bit 6 is set
// (the real drive waits for the gap's end mark) and continue while it stays
// set. Write mode: a transfer every byte time while bit 6 is set; one
// write session (bit 6 set in write mode until read mode or bit 6 clear)
// writes one block: the first byte (the end mark $80) is dropped, the rest is
// stored from the block's start. If the block's length changed, the blocks
// after it are dropped (the BIOS then rewrites the file count).
//
// Block table: per side the start offsets of its blocks, then the end of the
// last block, then $FFFF; written by the menu in menu mode through the CPLD
// register port ($4400 index / $4401 data):
//   $91  table address bits 7:0, $92 bits 9:8 (= side), resets the byte order
//   $93  data: low byte, then high byte (then the address advances)
//   $94  bits 1:0 the inserted side, bit 7 = no disk inserted
//   $95  number of sides loaded (1-4), for the side swap
//   $96  ID address: bits 5:4 side, bits 3:0 byte (0-9; 10-15 are skipped)
//   $97  ID data (then the address advances): block 1 bytes $0F-$18 of
//        each side, what the BIOS compares with the game's wanted ID
//
// Side swap (manual): the core reads pad 1 along with the game - after a
// $4016 strobe, the first 8 $4016 reads carry A, B, Select, Start, Up,
// Down, Left, Right in D0 (1 = pressed) over the cartridge bus. Select +
// Down held for SWAP_HOLD cycles (~0.9 s): the disk is ejected for
// SWAP_EJECT cycles (~1 s: $4032 says no disk, the head goes back), then
// the next side is inserted (after the last: side A). Once per press: both
// buttons have to be released before the next swap. Works only while the
// game reads the pad (games do every frame, also on "change side" screens).
//
// Side swap (automatic), two parts:
// 1. Eject: a "change side" screen is the game's own loop waiting for the
//    disk to go (Zelda II: LDA $4032 / LSR / BCS once per frame, no BIOS
//    call). The core counts $4032 reads made by game code - the cycle
//    before the data read is the instruction's last operand fetch, outside
//    $E000-$FFFF for game code, inside for the BIOS. AUTO_POLLS such reads,
//    each within POLL_GAP cycles of the previous one: eject as in the manual
//    swap, then the next side. Armed only by a BIOS disk check ($E445) since
//    the last automatic eject: a game that only checks every frame that the
//    disk is still there gets at most one eject, not one per second.
// 2. Side by ID: at every BIOS disk check the core compares the wanted ID
//    with each loaded side's; if the inserted side does not match and
//    another one does, that one goes in at once (before the BIOS reads
//    block 1). Covers what "next side" gets wrong (4 sides, 2 disks).
//
// NTSC game on a PAL console (map_cfg[6], set by the menu - every FDS game
// is NTSC): the timer counts CPU cycles from the game's NMI. As in the VRC6
// core, in vblank it counts only the cycles NTSC has between NMI and the
// pre-render line, then holds until the PPU reads again (at most
// PAL_HOLD_MAX cycles); while the PPU renders it counts 16 per 15 cycles (a
// PAL line has 106 9/16 CPU cycles, NTSC 113 2/3: exactly 15/16).

module map_fds (
    input         mclk,          // M2 on a clock pin
    input         m2,
    input         clk,           // board clock (PPU activity, PAL correction)
    input         ppu_rd,        // /RD
    input  [6:0]  map_cfg,       // bit 6: NTSC game on a PAL console
    input         rst,           // 1 while the menu map is active
    input  [7:0]  cpu_dat,
    input  [14:0] cpu_addr,
    input         cpu_ce,        // /ROMSEL
    input         cpu_rw,
    input  [13:0] ppu_addr,
    input         ppu_wr,        // /WR

    output [18:10] prg_a,
    output         prg_rom,
    output         prg_ram,
    output         prg_wr,
    output [18:10] chr_a,
    output         chr_sel,
    output         chr_wr,
    output         ciram_a10,
    output         ciram_sel,
    output         irq,
    output reg [7:0] cpu_do,
    output         cpu_oe,
    input  [7:0]   aud_gain,     // $89: 128 = 1.0
    output         aud           // sigma-delta audio (cpu_exp)
);

    // byte times; parameters only so that the testbench can shorten them
    parameter  LEADIN = 16'd3537;    // 28300 bits, typical
    parameter  GAP    = 16'd122;     // 976 bits, typical
    localparam SIDE_END = 16'd65500;
    parameter  SWAP_HOLD  = 21'd1600000;   // CPU cycles
    parameter  SWAP_EJECT = 21'd1790000;
    parameter  AUTO_POLLS = 7'd60;         // game $4032 reads before the eject
    parameter  POLL_GAP   = 17'd100000;    // max cycles between two of them

    // ---------------------------------------------------------------- decoding
    wire [15:0] a16 = { ~cpu_ce, cpu_addr };
    wire lo       = cpu_ce;                                       // $0000-$7FFF
    wire ram_rng  = (a16 >= 16'h6000) & (a16 < 16'hE000);
    wire bios     = ~cpu_ce & (cpu_addr[14:13] == 2'b11);         // $E000-$FFFF
    wire reg_w    = lo & (cpu_addr[14:4] == 11'h402);             // $4020-$402F
    wire reg_r    = lo & (cpu_addr[14:2] == 13'h100C);            // $4030-$4033
    wire stub     = lo & (cpu_addr[14:4] == 11'h570);             // $5700-$570F
    wire idw      = lo & (cpu_addr[14:4] == 11'h571);             // $5710-$571F
    wire stub2    = lo & (cpu_addr[14:4] == 11'h572);             // $5720-$572F
    wire rwin     = lo & (cpu_addr[14:10] == 5'b10110);           // $5800-$5BFF
    wire wwin     = lo & (cpu_addr[14:10] == 5'b10111);           // $5C00-$5FFF
    wire port     = lo & (cpu_addr[14:9] == 6'b100010);           // $4400-$45FF
    wire [3:0] rn = cpu_addr[3:0];

    // ---------------------------------------------------------------- state
    reg [7:0]  ctl     = 8'h26;      // $4025
    reg        io_en   = 1'b0;       // $4023 bit 0
    reg [15:0] t_rel   = 16'd0;
    reg [15:0] t_cnt   = 16'd0;
    reg        t_rep   = 1'b0, t_en = 1'b0, t_irq = 1'b0;
    reg [3:0]  t_p15   = 4'd0;       // PAL: every 15th counted cycle counts 2
    reg        xfer    = 1'b0;       // byte transfer flag

    reg [1:0]  side    = 2'd0;       // $94
    reg        nodisk  = 1'b1;
    reg [2:0]  nsides  = 3'd1;       // $95
    // pad 1 (read along with the game) and the side swap
    reg        pad_stb = 1'b0;
    reg [3:0]  pad_n   = 4'd8;
    reg [7:0]  pad_sh  = 8'd0;
    reg [7:0]  pad_btn = 8'd0;       // bit 0 A ... bit 7 Right
    reg [20:0] sw_cnt  = 21'd0;
    reg        sw_arm  = 1'b1;       // released since the last swap
    reg        eject   = 1'b0;
    reg [20:0] ej_cnt  = 21'd0;
    // automatic swap: side IDs ($96/$97), game polls of $4032
    reg [7:0]  id0 [0:9];
    reg [7:0]  id1 [0:9];
    reg [7:0]  id2 [0:9];
    reg [7:0]  id3 [0:9];
    reg [5:0]  id_p    = 6'd0;
    reg [3:0]  id_m    = 4'd0;       // sides matching the wanted ID so far
    reg        prev_bios = 1'b0;     // last cycle's address in $E000-$FFFF
    reg [6:0]  ap_cnt  = 7'd0;
    reg [16:0] ap_gap  = 17'd0;
    reg        ap_arm  = 1'b0;       // a BIOS disk check since the last auto eject

    // head
    localparam ST_STOP = 3'd0, ST_LEAD = 3'd1, ST_BLK = 3'd2, ST_CRC = 3'd3,
               ST_GAP = 3'd4, ST_END = 3'd5, ST_WR = 3'd6;
    reg [2:0]  ph      = ST_STOP;
    reg [15:0] hcnt    = 16'd0;
    reg [7:0]  blk     = 8'd0;       // current / next block
    reg [15:0] bstart  = 16'd0;      // its start
    reg [15:0] ptr     = 16'd0;      // next byte in the block
    reg        sync    = 1'b0;
    reg        ovr     = 1'b0;       // overrun in this block -> $4030 bit 4
    reg [15:0] rd_off  = 16'd0;      // byte of the current transfer
    reg [8:0]  bacc    = 9'd0;       // byte clock: +3 per cycle, 448 = 1 byte

    // write session
    reg        sess    = 1'b0;
    reg        wfirst  = 1'b0;       // end mark not yet seen
    reg        wskip   = 1'b0;       // next window write = the BIOS's flush byte
    reg [15:0] wstart  = 16'd0;
    reg [15:0] wcnt    = 16'd0;

    // block table (M4K): {side, index} -> 16-bit offset
    reg [15:0] tbl [0:1023];
    reg [9:0]  tbl_ra  = 10'd0;
    reg [15:0] tbl_q   = 16'hFFFF;   // = tbl[{side, blk + 1}] (2 cycles late)
    reg        t_we    = 1'b0;
    reg [9:0]  t_wa    = 10'd0;
    reg [15:0] t_wd    = 16'd0;
    reg [1:0]  tw_st   = 2'd0;       // game-mode table update: 2 entries
    reg [15:0] tw_end  = 16'd0;

    // menu port
    reg [7:0]  index   = 8'd0;
    reg [9:0]  m_addr  = 10'd0;
    reg        m_hi    = 1'b0;
    reg [7:0]  m_lo    = 8'd0;

    always @(negedge mclk) begin
        if (t_we)
            tbl[t_wa] <= t_wd;
        tbl_q <= tbl[tbl_ra];
    end

    // ---------------------------------------------------------------- PAL correction
    localparam HOLD_IDLE_CLK = 64;       // 1.28 us without a PPU read: not rendering
    localparam PAL_HOLD_CYC  = 2380;     // 1 PAL line to the NMI (107) + 20 NTSC lines
    localparam PAL_HOLD_MAX  = 5400;     // PAL - NTSC vblank: 50 lines = 5328 cycles
    wire pal_fix = map_cfg[6];

    reg [2:0] rd_s = 3'b111;
    reg [6:0] idle_clk = 7'd0;
    reg       rendering = 1'b0;
    always @(posedge clk) begin
        rd_s <= { rd_s[1:0], ppu_rd };
        if (rd_s[2] & ~rd_s[1]) begin
            idle_clk  <= 7'd0;
            rendering <= 1'b1;
        end else if (idle_clk != HOLD_IDLE_CLK) begin
            idle_clk <= idle_clk + 7'd1;
        end else
            rendering <= 1'b0;
    end

    reg [1:0]  ren_m = 2'b00;
    reg [12:0] vbl = 13'd0;
    wire       ren  = ren_m[1];
    wire       hold = pal_fix & ~ren & (vbl >= PAL_HOLD_CYC) & (vbl < PAL_HOLD_CYC + PAL_HOLD_MAX);
    // 16 per 15 cycles only while the picture is drawn (lines); in vblank the
    // count is plain time, the hold takes out the extra PAL lines
    wire [1:0] t_step = (pal_fix && ren && t_p15 == 4'd14) ? 2'd2 : 2'd1;

    // ---------------------------------------------------------------- helpers
    wire       no_disk = nodisk | eject;
    wire       running = ~ctl[1] & ctl[0] & ~no_disk;
    wire       pad_reg = lo & (cpu_addr == 15'h4016);
    wire       combo   = pad_btn[2] & pad_btn[5];      // Select + Down
    wire [1:0] side_nx = ({ 1'b0, side } + 3'd1 >= nsides) ? 2'd0 : side + 2'd1;
    wire       rmode   = ctl[2];
    wire [8:0] bacc3   = bacc + 9'd3;
    wire       btick   = bacc3 >= 9'd448;
    wire [15:0] wr_off = wstart + wcnt;
    wire       wr_ok   = sess & ~wfirst & ~wskip & (wr_off < SIDE_END);
    wire       rd      = cpu_rw;
    // is this cycle a transfer acknowledge? ($4031 / read window, $4024 / write window)
    wire       ack_r   = rd  & ((reg_r & cpu_addr[1:0] == 2'd1) | rwin);
    wire       ack_w   = ~rd & ((reg_w & rn == 4'h4) | wwin);
    // ID check: which loaded sides match the byte written to $5710+Y
    wire [3:0] id_y    = cpu_addr[3:0];
    wire       id_ok   = idw & ~rd & (id_y <= 4'd9);
    wire       id_any  = (cpu_dat == 8'hFF);
    wire [3:0] id_set  = { nsides > 3'd3, nsides > 3'd2, nsides > 3'd1, 1'b1 };
    wire [3:0] id_now  = id_set & { id_any | (cpu_dat == id3[id_y]), id_any | (cpu_dat == id2[id_y]),
                                    id_any | (cpu_dat == id1[id_y]), id_any | (cpu_dat == id0[id_y]) };
    wire [3:0] id_fin  = id_m & id_now;                         // with byte 0, the last
    wire [1:0] id_pick = id_fin[0] ? 2'd0 : id_fin[1] ? 2'd1 : id_fin[2] ? 2'd2 : 2'd3;
    wire       g_poll  = reg_r & rd & (cpu_addr[1:0] == 2'd2) & ~prev_bios;   // game reads $4032

    // ---------------------------------------------------------------- CPU side, falling M2
    always @(negedge mclk) begin
        // menu register port (index is tracked in both modes)
        if (port & ~rd & cpu_addr[1:0] == 2'd0)
            index <= cpu_dat;

        t_we <= 1'b0;

        if (rst) begin
            ctl <= 8'h26;  io_en <= 1'b0;
            t_en <= 1'b0;  t_rep <= 1'b0;  t_irq <= 1'b0;  t_p15 <= 4'd0;
            xfer <= 1'b0;  ph <= ST_STOP;  sync <= 1'b0;  sess <= 1'b0;  ovr <= 1'b0;
            tw_st <= 2'd0; ren_m <= 2'b00; vbl <= 13'd0;  bacc <= 9'd0;
            blk <= 8'd0;   bstart <= 16'd0;
            pad_stb <= 1'b0;  pad_n <= 4'd8;  pad_btn <= 8'd0;
            sw_cnt <= 21'd0;  sw_arm <= 1'b1;  eject <= 1'b0;  ej_cnt <= 21'd0;
            id_m <= 4'd0;  ap_cnt <= 7'd0;  ap_gap <= 17'd0;  ap_arm <= 1'b0;  prev_bios <= 1'b0;
            if (port & ~rd & cpu_addr[1:0] == 2'd1) begin
                case (index)
                    8'h91: begin m_addr[7:0] <= cpu_dat;      m_hi <= 1'b0; end
                    8'h92: begin m_addr[9:8] <= cpu_dat[1:0]; m_hi <= 1'b0; end
                    8'h93: if (!m_hi) begin
                               m_lo <= cpu_dat;  m_hi <= 1'b1;
                           end else begin
                               t_we <= 1'b1;  t_wa <= m_addr;  t_wd <= { cpu_dat, m_lo };
                               m_addr <= m_addr + 10'd1;  m_hi <= 1'b0;
                           end
                    8'h94: begin side <= cpu_dat[1:0];  nodisk <= cpu_dat[7]; end
                    8'h95: nsides <= cpu_dat[2:0];
                    8'h96: id_p <= cpu_dat[5:0];
                    8'h97: begin
                               if (id_p[3:0] <= 4'd9) case (id_p[5:4])
                                   2'd0: id0[id_p[3:0]] <= cpu_dat;
                                   2'd1: id1[id_p[3:0]] <= cpu_dat;
                                   2'd2: id2[id_p[3:0]] <= cpu_dat;
                                   default: id3[id_p[3:0]] <= cpu_dat;
                               endcase
                               id_p <= id_p + 6'd1;
                           end
                    default: ;
                endcase
            end
        end else begin
            // ---- pad 1, read along with the game
            if (pad_reg && !rd) begin
                if (pad_stb && !cpu_dat[0])
                    pad_n <= 4'd0;               // strobe released: A comes first
                pad_stb <= cpu_dat[0];
            end
            if (pad_reg && rd && !pad_stb && pad_n != 4'd8) begin
                pad_sh <= { cpu_dat[0], pad_sh[7:1] };
                if (pad_n == 4'd7)
                    pad_btn <= { cpu_dat[0], pad_sh[7:1] };
                pad_n <= pad_n + 4'd1;
            end

            // ---- side swap: Select + Down held, then eject, then the next side
            if (!combo) begin
                sw_cnt <= 21'd0;
                sw_arm <= 1'b1;
            end else if (sw_arm && !eject) begin
                if (sw_cnt == SWAP_HOLD) begin
                    sw_arm <= 1'b0;
                    eject  <= 1'b1;
                    ej_cnt <= 21'd0;
                end else
                    sw_cnt <= sw_cnt + 21'd1;
            end
            if (eject) begin
                if (ej_cnt == SWAP_EJECT) begin
                    eject <= 1'b0;
                    side  <= side_nx;
                end else
                    ej_cnt <= ej_cnt + 21'd1;
            end

            // ---- automatic swap 1: the game waits for an eject
            prev_bios <= bios;
            if (g_poll && ap_arm && !no_disk) begin
                ap_gap <= 17'd0;
                if (ap_cnt == AUTO_POLLS) begin
                    ap_arm <= 1'b0;
                    ap_cnt <= 7'd0;
                    eject  <= 1'b1;
                    ej_cnt <= 21'd0;
                end else
                    ap_cnt <= ap_cnt + 7'd1;
            end else if (ap_gap == POLL_GAP)
                ap_cnt <= 7'd0;                  // not a waiting loop
            else
                ap_gap <= ap_gap + 17'd1;

            // ---- automatic swap 2: the BIOS's disk check names the side
            if (id_ok) begin
                if (id_y == 4'd9)
                    id_m <= id_now;              // the stub writes byte 9 first
                else
                    id_m <= id_m & id_now;
                // ... and byte 0 last; with no disk in, the BIOS stops
                // before reading (and a check cannot happen then anyway)
                if (id_y == 4'd0 && !no_disk) begin
                    ap_arm <= 1'b1;
                    ap_cnt <= 7'd0;
                    if (!id_fin[side] && id_fin != 4'd0)
                        side <= id_pick;
                end
            end

            // ---- frame position (PAL correction)
            ren_m <= { ren_m[0], rendering };
            if (ren)
                vbl <= 13'd0;
            else if (vbl != 13'h1FFF)
                vbl <= vbl + 13'd1;

            // ---- timer
            if (io_en && t_en && !hold) begin
                if (pal_fix && ren)
                    t_p15 <= (t_p15 == 4'd14) ? 4'd0 : t_p15 + 4'd1;
                if (t_cnt < { 14'd0, t_step }) begin
                    t_irq <= 1'b1;
                    t_cnt <= t_rel;
                    if (!t_rep)
                        t_en <= 1'b0;
                end else
                    t_cnt <= t_cnt - { 14'd0, t_step };
            end

            // ---- disk head, one step per byte time
            bacc <= btick ? bacc3 - 9'd448 : bacc3;
            // checked every cycle, not per byte: the BIOS drops transfer
            // reset / the motor for only ~27 cycles between two starts, and
            // that must send the head back to the start
            if (!io_en || !running) begin
                if (ph != ST_WR) begin
                    ph <= ST_STOP;  sync <= 1'b0;
                end
            end else if (btick) begin
                case (ph)
                    ST_STOP: begin
                        ph <= ST_LEAD;  hcnt <= LEADIN;  blk <= 8'd0;  bstart <= 16'd0;
                    end
                    ST_LEAD, ST_GAP: begin
                        if (sync)
                            xfer <= 1'b1;            // gap bytes ($00)
                        if (hcnt == 16'd1) begin
                            if (tbl_q == 16'hFFFF)
                                ph <= ST_END;
                            else begin
                                ph  <= ST_BLK;
                                ptr <= bstart;
                                ovr <= 1'b0;
                                if (ctl[6] && rmode)
                                    sync <= 1'b1;
                            end
                        end
                        hcnt <= hcnt - 16'd1;
                    end
                    ST_BLK: begin
                        if (sync) begin
                            if (xfer)
                                ovr <= 1'b1;         // previous byte not taken
                            xfer   <= 1'b1;
                            rd_off <= ptr;
                        end
                        if (ptr + 16'd1 >= tbl_q) begin
                            ph <= ST_CRC;  hcnt <= 16'd2;
                        end
                        ptr <= ptr + 16'd1;
                    end
                    ST_CRC: begin
                        if (sync)
                            xfer <= 1'b1;
                        if (hcnt == 16'd1) begin
                            ph <= ST_GAP;  hcnt <= GAP;
                            blk <= blk + 8'd1;  bstart <= tbl_q;
                        end else
                            hcnt <= hcnt - 16'd1;
                    end
                    ST_END: begin
                        if (sync)
                            xfer <= 1'b1;
                    end
                    default: ;                   // ST_WR: the head writes
                endcase
            end
            // write mode: a transfer every byte time while bit 6 is set
            if (io_en && !rmode && ctl[6] && btick)
                xfer <= 1'b1;

            // ---- block table: read e(blk + 1) continuously; game-mode updates
            tbl_ra <= { side, blk + 8'd1 };
            case (tw_st)
                2'd1: begin t_we <= 1'b1; t_wa <= { side, blk + 8'd1 }; t_wd <= tw_end;  tw_st <= 2'd2; end
                2'd2: begin t_we <= 1'b1; t_wa <= { side, blk + 8'd2 }; t_wd <= 16'hFFFF; tw_st <= 2'd0; end
                default: ;
            endcase

            // ---- register reads
            if (reg_r && rd && cpu_addr[1:0] == 2'd0)
                t_irq <= 1'b0;                   // $4030 acknowledges the timer
            if (ack_r)
                xfer <= 1'b0;

            // ---- writes
            if (~rd) begin
                if (ack_w && (io_en || wwin))
                    xfer <= 1'b0;
                if (stub && cpu_addr[3:0] == 4'hF)
                    wskip <= sess;               // $570F: flush byte follows
                if (wwin && sess) begin
                    if (wfirst)
                        wfirst <= 1'b0;          // the end mark
                    else if (wskip)
                        wskip <= 1'b0;           // the flush byte: not on the disk
                    else if (wr_off < SIDE_END)
                        wcnt <= wcnt + 16'd1;
                end
                if (reg_w) case (rn)
                    4'h0: t_rel[7:0]  <= cpu_dat;
                    4'h1: t_rel[15:8] <= cpu_dat;
                    4'h2: if (io_en) begin
                              t_rep <= cpu_dat[0];
                              t_en  <= cpu_dat[1];
                              t_irq <= 1'b0;
                              t_p15 <= 4'd0;
                              if (cpu_dat[1])
                                  t_cnt <= t_rel;
                          end
                    4'h3: begin
                              io_en <= cpu_dat[0];
                              if (!cpu_dat[0]) begin
                                  t_en <= 1'b0;  t_irq <= 1'b0;  xfer <= 1'b0;
                              end
                          end
                    4'h5: if (io_en) begin
                              ctl <= cpu_dat;
                              // bit 6 clear: no transfers, and the flag reads 0
                              // (it only exists while its condition holds) - a
                              // flag left from write mode would fire the next
                              // read's IRQ at once (Zelda II's save: ERR.24)
                              if (!cpu_dat[6]) begin
                                  sync <= 1'b0;
                                  xfer <= 1'b0;
                              end
                              // write session start: write mode with bit 6
                              if (!sess && !cpu_dat[2] && cpu_dat[6]) begin
                                  sess   <= 1'b1;
                                  wfirst <= 1'b1;
                                  wskip  <= 1'b0;
                                  wcnt   <= 16'd0;
                                  if (ph == ST_CRC) begin   // in a block's tail: the next one
                                      wstart <= tbl_q;
                                      blk    <= blk + 8'd1;
                                      bstart <= tbl_q;
                                  end else
                                      wstart <= bstart;
                                  ph <= ST_WR;
                              end
                              // write session end: read mode or bit 6 clear
                              if (sess && (cpu_dat[2] || !cpu_dat[6])) begin
                                  sess <= 1'b0;
                                  if (wfirst || wcnt == 16'd0) begin
                                      ph <= ST_GAP;  hcnt <= GAP;   // nothing written
                                  end else begin
                                      ph <= ST_CRC;  hcnt <= 16'd2;
                                      if (wr_off != tbl_q) begin    // length changed
                                          tw_end <= wr_off;
                                          tw_st  <= 2'd1;
                                      end
                                  end
                              end
                          end
                    default: ;
                endcase
            end
        end
    end

    // ---------------------------------------------------------------- sound
    wire [7:0]  snd_do;
    wire        snd_oe;
    wire [10:0] snd_level;
    fds_snd snd (
        .mclk(mclk), .rst(rst), .cpu_addr(cpu_addr), .cpu_ce(cpu_ce), .cpu_rw(cpu_rw),
        .cpu_dat(cpu_dat), .rd_dat(snd_do), .rd_oe(snd_oe), .level(snd_level)
    );
    aud_dac dac (.clk(clk), .level(snd_level), .gain(aud_gain), .aud(aud));

    // ---------------------------------------------------------------- reads the core answers
    wire [15:0] w_now = wr_off;
    always @* begin
        if (snd_oe)
            cpu_do = snd_do;
        else if (stub2)
        case (cpu_addr[3:0])
            4'h0: cpu_do = 8'hA0;                                    // LDY #9
            4'h1: cpu_do = 8'h09;
            4'h2: cpu_do = 8'hB1;                                    // LDA ($00),Y
            4'h3: cpu_do = 8'h00;
            4'h4: cpu_do = 8'h99;                                    // STA $5710,Y
            4'h5: cpu_do = 8'h10;
            4'h6: cpu_do = 8'h57;
            4'h7: cpu_do = 8'h88;                                    // DEY
            4'h8: cpu_do = 8'h10;                                    // BPL $5722
            4'h9: cpu_do = 8'hF8;
            4'hA: cpu_do = 8'h4C;                                    // JMP $E6E3
            4'hB: cpu_do = 8'hE3;
            4'hC: cpu_do = 8'hE6;
            default: cpu_do = 8'hEA;
        endcase
        else
        case ({ stub, cpu_addr[3:0] })
            5'h10: cpu_do = 8'hAE;                                   // LDX abs
            5'h11: cpu_do = rd_off[7:0];
            5'h12: cpu_do = { 6'b010110, rd_off[9:8] };              // $58xx-$5Bxx
            5'h13: cpu_do = 8'h60;                                   // RTS
            5'h14: cpu_do = 8'h8D;                                   // STA abs
            5'h15: cpu_do = w_now[7:0];
            5'h16: cpu_do = { 6'b010111, w_now[9:8] };               // $5Cxx-$5Fxx
            5'h17: cpu_do = 8'h60;
            5'h18: cpu_do = 8'h8D;                                   // STA $570F
            5'h19: cpu_do = 8'h0F;
            5'h1A: cpu_do = 8'h57;
            5'h1B: cpu_do = 8'h4C;                                   // JMP $E7A3
            5'h1C: cpu_do = 8'hA3;
            5'h1D: cpu_do = 8'hE7;
            5'h1E, 5'h1F: cpu_do = 8'hEA;
            default: case (cpu_addr[1:0])
                2'd0: cpu_do = { xfer, ph == ST_END, 1'b0, ovr, ctl[3], 2'b00, t_irq };
                2'd1: cpu_do = 8'h00;
                2'd2: cpu_do = { 5'b01000, no_disk,
                                 ~(io_en & running & ph != ST_STOP & ph != ST_END), no_disk };
                default: cpu_do = 8'h80;
            endcase
        endcase
    end
    assign cpu_oe = ~rst & m2 & cpu_rw & (reg_r | stub | stub2 | snd_oe);

    // ---------------------------------------------------------------- memory map
    wire [5:0] ram_pg = a16[15:10] - 6'h18;                  // $6000 -> 0
    // SRAM A18-A16 of the side; side 0 in the save SRAM, sides 1-3 in PRG
    wire [2:0] sbase  = (side == 2'd0) ? 3'b000 :            // save $00000
                        (side == 2'd1) ? 3'b010 :            // PRG  $20000
                        (side == 2'd2) ? 3'b011 :            // PRG  $30000
                                         3'b100;             // PRG  $40000
    wire       sv_side = (side == 2'd0);
    assign prg_a = ram_rng ? { 4'b0000, ram_pg[4:0] } :
                   bios    ? { 6'b000100, cpu_addr[12:10] } :      // $08000
                   rwin    ? { sbase, rd_off[15:10] } :
                             { sbase, w_now[15:10] };
    assign prg_rom = ram_rng | bios | ((rwin | wwin) & ~sv_side);
    assign prg_ram = m2 & (rwin | wwin) & sv_side;
    assign prg_wr  = m2 & ~cpu_rw & (ram_rng | (wwin & wr_ok));

    assign chr_a   = { 6'b000000, ppu_addr[12:10] };
    assign chr_sel = ~ppu_addr[13];
    assign chr_wr  = ~ppu_addr[13] & ~ppu_wr;
    assign ciram_a10 = ctl[3] ? ppu_addr[11] : ppu_addr[10];
    assign ciram_sel = ppu_addr[13];

    assign irq = t_irq | (ctl[7] & xfer);

endmodule
