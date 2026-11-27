// n8-open: mapper 5 (MMC5: ExROM boards) for the EverDrive N8 clone.
//
// Written from the public MMC5 documentation (NESdev wiki: MMC5), not from
// any existing HDL. Phase 1: PRG/CHR banking, PRG RAM, nametable mapping
// (CIRAM, ExRAM, fill mode), ExRAM CPU access, PPU register snooping,
// scanline detection, in-frame flag, scanline IRQ, multiplier.
// Phase 2: extended attributes (ExRAM mode 1, see below).
// Phase 3: vertical split (see below).
// Phase 4: audio - two pulses + PCM in mmc5_snd.v, out on cpu_exp through
// aud_dac.v (gain $89 like VRC6/FDS); $5010/$5015 reads, PCM IRQ.
// Not yet: MMC5A extras.
//
// Vertical split ($5200 = E S - T T T T T, $5201 scroll, $5202 4 KB CHR
// bank; ExRAM modes 0/1, rendering on, background fetches only). The wiki
// documents: left split = tiles 0..T-1, right split = tiles T and up; the
// split's nametable is ExRAM; $5202 selects a 4 KB page for its pattern
// reads ($5130 and the CHR mode do not apply); its own line counter starts
// at $5201 every frame; 240-255 show the attribute area as tiles for the
// first lines; in mode 1 the split region has no extended attributes.
// Fine Y: on Nintendo's (CL) boards - and on this one, whose CHR SRAM takes
// A0-A9 from the PPU - the PPU's own fine Y addresses the pattern row.
// Inferred (not in the wiki):
//  - tile n = screen column n: tiles 0 and 1 are the previous line's
//    prefetch, the line's own fetches are columns 2-33
//  - nametable byte = ExRAM[row * 32 + column] (row = counter / 8),
//    attribute byte = ExRAM[$3C0 + counter / 32 * 8 + column / 4]; the
//    MMC5 selects the column's 2-bit pair itself and answers it copied
//    into all four positions (the PPU picks the pair by its own scroll
//    position, unrelated to the split's)
//  - the counter counts +1 per line; after 239 it wraps to 0, 240-255
//    count on to 255 and then wrap to 0
//  - the prefetch, the two dummy reads and the next line's first tile read
//    (reads 160-170, before the line is detected) use the next line's value
// Not covered: the first two tiles of line 0 (fetched on the pre-render
// line, before "in frame") - as with the extended attributes.
//
// Extended attributes ($5104 = 1, rendering on, in frame, background
// fetches only): for each tile the ExRAM byte at the nametable address
// (& $3FF) is latched during the nametable read (the nametable byte itself
// still comes via $5105). Bits 5:0 + $5130 (live) select a 4 KB CHR page for
// the tile's two pattern reads ($5101 and $5120-$512B are ignored). Bits 7:6
// are the palette: the MMC5 answers the tile's attribute read itself with
// them copied into all four 2-bit positions. The wiki documents the CHR part
// but not which fetch carries the palette; answering the attribute read is
// inferred - the PPU picks one of four bit pairs from that byte by tile
// position, so only a byte with all four pairs equal gives every tile its
// own palette.
//
// Clock domains:
//   mclk (M2, falling edge)  CPU register writes, CPU-side events
//   clk  (board, 50 MHz)     PPU read tracking: scanline detection, fetch
//                            index, in-frame, IRQ pending; ExRAM (M4K)
// Events between them cross as toggles (two-flop synchronised); register
// values the other domain only samples are quasi-static.
//
// Fetch index: PPU reads are counted when they END (/RD rising), so the
// index - and the CHR bank it selects (sprite vs background) - is stable
// while a read is in progress. The read that completes a run of three
// identical nametable reads is read 0 of the line (the tile fetch at dot 1);
// background reads are 0-127, sprite reads 128-159, prefetch 160-167.
// (The wiki's prose and pseudocode differ by one read on when a scanline
// counts; this follows the pseudocode: on the third matching read.)
//
// Data bus outputs: cpu_oe/ppu_oe only say "this read is mine"; top.v gates
// them (M2 high and settled, game mode) and switches the SRAM outputs off.

module map_mmc5 (
    input         mclk,          // M2 on a clock pin
    input         m2,
    input         clk,           // board clock
    input         rst,           // 1 while the menu map is active
    input  [7:0]  cpu_dat,
    input  [14:0] cpu_addr,
    input         cpu_ce,        // /ROMSEL
    input         cpu_rw,
    input  [13:0] ppu_addr,
    input         ppu_rd,        // /RD
    input         ppu_wr,        // /WR
    input  [7:0]  ppu_dat,
    input         chr_is_ram,

    output reg [18:10] prg_a,
    output reg     prg_rom,
    output reg     prg_ram,
    output         prg_wr,
    output [18:10] chr_a,
    output         chr_sel,
    output         chr_wr,
    output         ciram_a10,
    output         ciram_sel,
    output         irq,
    output [7:0]   cpu_do,
    output         cpu_oe,
    output [7:0]   ppu_do,
    output         ppu_oe,
    input  [7:0]   aud_gain,     // $89: 128 = 1.0
    output         aud           // sigma-delta audio (cpu_exp)
);

    // ================================================================ CPU side (mclk)
    reg [1:0] prg_mode  = 2'd3;      // $5100
    reg [1:0] chr_mode  = 2'd0;      // $5101
    reg [1:0] prot1     = 2'd1;      // $5102
    reg [1:0] prot2     = 2'd2;      // $5103
    reg [1:0] ex_mode   = 2'd3;      // $5104
    reg [7:0] nt_map    = 8'd0;      // $5105
    reg [7:0] fill_tile = 8'd0;      // $5106
    reg [1:0] fill_attr = 2'd0;      // $5107
    reg [7:0] prg_r0    = 8'd0;      // $5113 (RAM only)
    reg [7:0] prg_r1    = 8'd0;      // $5114
    reg [7:0] prg_r2    = 8'd0;      // $5115
    reg [7:0] prg_r3    = 8'd0;      // $5116
    reg [7:0] prg_r4    = 8'hFF;     // $5117 (ROM only)
    reg [1:0] chr_hi    = 2'd0;      // $5130
    reg [7:0] sp_ctl    = 8'd0;      // $5200
    reg [7:0] sp_scr    = 8'd0;      // $5201
    reg [7:0] sp_bank   = 8'd0;      // $5202
    reg [7:0] irq_cmp   = 8'd0;      // $5203
    reg       irq_en    = 1'b0;      // $5204 bit 7
    reg [7:0] mul_a     = 8'd0;      // $5205
    reg [7:0] mul_b     = 8'd0;      // $5206
    reg       spr16     = 1'b0;      // $2000 bit 5 (snooped)
    reg       subst     = 1'b0;      // $2001 bits 4:3 != 0 (snooped)
    reg       last_b    = 1'b0;      // last CHR register written was set B

    // CHR bank registers $5120-$512B: 8 data bits + $5130 at write time
    reg [9:0] chr_r [0:11];
    integer i;
    initial for (i = 0; i < 12; i = i + 1) chr_r[i] = 10'd0;

    // events to the clk domain (toggles) and the ExRAM write data
    reg ack_t = 1'b0;                // $5204 read: acknowledge the IRQ
    reg clr_t = 1'b0;                // in-frame clear: $2001 off, NMI vector read
    reg exw_t = 1'b0;                // CPU write to ExRAM ...
    reg [9:0] exw_a = 10'd0;
    reg [7:0] exw_d = 8'd0;

    wire lo_area = cpu_ce;                                   // $0000-$7FFF
    wire reg5    = lo_area & (cpu_addr[14:12] == 3'b101);    // $5000-$5FFF
    wire exram_c = reg5 & (cpu_addr[11:10] == 2'b11);        // $5C00-$5FFF
    wire [11:0] r = cpu_addr[11:0];

    reg  in_frame = 1'b0;            // clk domain, below
    reg  [1:0] inf_m = 2'b00;        // in-frame synchronised to mclk

    always @(negedge mclk) begin
        inf_m <= { inf_m[0], in_frame };
        if (rst) begin
            prg_mode <= 2'd3;  chr_mode <= 2'd0;  prot1 <= 2'd1;     prot2 <= 2'd2;
            ex_mode <= 2'd3;   nt_map <= 8'd0;    fill_tile <= 8'd0; fill_attr <= 2'd0;
            prg_r0 <= 8'd0;    prg_r1 <= 8'd0;    prg_r2 <= 8'd0;    prg_r3 <= 8'd0;
            prg_r4 <= 8'hFF;   chr_hi <= 2'd0;    irq_cmp <= 8'd0;   irq_en <= 1'b0;
            sp_ctl <= 8'd0;    sp_scr <= 8'd0;    sp_bank <= 8'd0;
            mul_a <= 8'd0;     mul_b <= 8'd0;     spr16 <= 1'b0;     subst <= 1'b0;
            last_b <= 1'b0;
            for (i = 0; i < 12; i = i + 1) chr_r[i] <= 10'd0;
        end else if (!cpu_rw) begin
            // PPU register snooping: the exact addresses only
            if (lo_area && cpu_addr == 15'h2000)
                spr16 <= cpu_dat[5];
            if (lo_area && cpu_addr == 15'h2001) begin
                subst <= cpu_dat[4] | cpu_dat[3];
                if (!(cpu_dat[4] | cpu_dat[3]))
                    clr_t <= ~clr_t;
            end
            if (reg5) begin
                case (r)
                    12'h100: prg_mode  <= cpu_dat[1:0];
                    12'h101: chr_mode  <= cpu_dat[1:0];
                    12'h102: prot1     <= cpu_dat[1:0];
                    12'h103: prot2     <= cpu_dat[1:0];
                    12'h104: ex_mode   <= cpu_dat[1:0];
                    12'h105: nt_map    <= cpu_dat;
                    12'h106: fill_tile <= cpu_dat;
                    12'h107: fill_attr <= cpu_dat[1:0];
                    12'h113: prg_r0    <= cpu_dat;
                    12'h114: prg_r1    <= cpu_dat;
                    12'h115: prg_r2    <= cpu_dat;
                    12'h116: prg_r3    <= cpu_dat;
                    12'h117: prg_r4    <= cpu_dat;
                    12'h130: chr_hi    <= cpu_dat[1:0];
                    12'h200: sp_ctl    <= cpu_dat;
                    12'h201: sp_scr    <= cpu_dat;
                    12'h202: sp_bank   <= cpu_dat;
                    12'h203: irq_cmp   <= cpu_dat;
                    12'h204: irq_en    <= cpu_dat[7];
                    12'h205: mul_a     <= cpu_dat;
                    12'h206: mul_b     <= cpu_dat;
                    default: ;
                endcase
                if (r[11:4] == 8'h12 && r[3:0] <= 4'hB) begin   // $5120-$512B
                    chr_r[r[3:0]] <= { chr_hi, cpu_dat };
                    last_b <= r[3];
                end
                // ExRAM: modes 0/1 writable only while rendering, mode 2
                // always, mode 3 never
                if (exram_c && (ex_mode == 2'd2 || (!ex_mode[1] && inf_m[1]))) begin
                    exw_a <= cpu_addr[9:0];
                    exw_d <= cpu_dat;
                    exw_t <= ~exw_t;
                end
            end
        end else begin
            if (reg5 && r == 12'h204)
                ack_t <= ~ack_t;
            if (!cpu_ce && cpu_addr[14:1] == 14'h3FFD)      // $FFFA/$FFFB read
                clr_t <= ~clr_t;
        end
    end

    // ---------------------------------------------------------------- PRG
    // psel: which bank register an access uses (0 = $5113 ... 4 = $5117)
    wire rom_area = ~cpu_ce;
    wire ram_6000 = lo_area & (cpu_addr[14:13] == 2'b11);
    reg  [2:0] psel;
    reg  [6:0] pbank;                // 8 KB bank number (bit 6 = A19)
    reg  [7:0] preg;
    always @* begin
        case (prg_mode)
            2'd0:    psel = 3'd4;
            2'd1:    psel = cpu_addr[14] ? 3'd4 : 3'd2;
            2'd2:    psel = !cpu_addr[14] ? 3'd2 : (cpu_addr[13] ? 3'd4 : 3'd3);
            default: psel = { 1'b0, cpu_addr[14:13] } + 3'd1;
        endcase
        case (psel)
            3'd1:    preg = prg_r1;
            3'd2:    preg = prg_r2;
            3'd3:    preg = prg_r3;
            default: preg = prg_r4;
        endcase
        // 16/32 KB windows: the low bank bits come from the CPU address
        if (prg_mode == 2'd0)
            pbank = { preg[6:2], cpu_addr[14:13] };
        else if (prg_mode == 2'd1 || (prg_mode == 2'd2 && !cpu_addr[14]))
            pbank = { preg[6:1], cpu_addr[13] };
        else
            pbank = preg[6:0];

        if (ram_6000) begin                              // $6000: $5113, RAM
            prg_rom = 1'b0;
            prg_ram = m2;
            prg_a   = { 3'b000, prg_r0[2:0], cpu_addr[12:10] };
        end else if (rom_area && psel != 3'd4 && !preg[7]) begin
            prg_rom = 1'b0;                              // RAM at $8000-$DFFF
            prg_ram = m2;
            prg_a   = { 3'b000, pbank[2:0], cpu_addr[12:10] };
        end else begin
            prg_rom = rom_area;                          // ROM (A19 dropped:
            prg_ram = 1'b0;                              //  512 KB on board)
            prg_a   = { pbank[5:0], cpu_addr[12:10] };
        end
    end
    // PRG RAM pages: bank & 7 = save SRAM pages 0-7 (64 KB superset)

    assign prg_wr = prg_ram & ~cpu_rw & (prot1 == 2'b10) & (prot2 == 2'b01);

    // ================================================================ PPU side (clk)
    reg [2:0]  rd_s = 3'b111, wr_s = 3'b111, m2_s = 3'b000;
    reg [1:0]  ack_s = 2'b00, clr_s = 2'b00, exw_s = 2'b00;
    reg        ack_p = 1'b0, clr_p = 1'b0, exw_p = 1'b0;
    reg [13:0] rd_addr = 14'd0, last_addr = 14'd0;
    reg [1:0]  match = 2'd0;         // identical nametable reads in a row
    reg [7:0]  rd_idx = 8'd255;      // index of the current read in the line
    reg [7:0]  scan = 8'd0;          // scanline counter
    reg [1:0]  idle = 2'd0;          // M2 rising edges without a PPU read
    reg        pend = 1'b0;          // IRQ pending
    reg [7:0]  cmp_s = 8'd0;         // $5203, sampled in this domain
    reg [7:0]  spc_s = 8'd0, sps_s = 8'd0, spb_s = 8'd0;   // $5200-$5202, sampled
    reg [7:0]  sp_y = 8'd0;          // split line counter (current line)
    reg [9:0]  pw_a = 10'd0;         // PPU write to ExRAM
    reg [7:0]  pw_d = 8'd0;
    reg        pw_go = 1'b0;
    reg        pw_ok = 1'b0;
    reg [1:0]  wr_cnt = 2'd0;        // clocks since /WR went low
    reg [1:0]  rd_cnt = 2'd0;        // clocks since /RD went low
    reg [7:0]  ex_lat = 8'd0;        // ExRAM byte of the current tile (ext. attributes)

    wire rd_fall = rd_s[2] & ~rd_s[1];
    wire rd_rise = ~rd_s[2] & rd_s[1];
    wire wr_rise = ~wr_s[2] & wr_s[1];
    wire m2_rise = ~m2_s[2] & m2_s[1];
    wire nt_read = (rd_addr[13:12] == 2'b10);           // $2000-$2FFF
    // background tile reads of a line: 0-127 (32 tiles) and the prefetch
    // 160-167 (2 tiles), each as nametable, attribute, pattern lo, pattern hi
    wire bg_fetch = in_frame && (rd_idx <= 8'd127 || (rd_idx >= 8'd160 && rd_idx <= 8'd167));
    wire ext_on   = (ex_mode == 2'd1) && subst;
    wire spr_fetch = (rd_idx >= 8'd128) && (rd_idx <= 8'd159);
    wire third   = nt_read && rd_addr == last_addr && match == 2'd2;

    // vertical split: column and kind of the current background read
    reg  [5:0] sp_col;               // screen column 0-33
    reg  [1:0] sp_typ;               // 0 nametable, 1 attribute, 2/3 pattern
    reg        sp_bg, sp_nxt;        // a background read / uses the next line's value
    always @* begin
        sp_col = 6'd2;  sp_typ = 2'd0;  sp_bg = 1'b0;  sp_nxt = 1'b0;
        if (rd_idx <= 8'd127) begin                      // the line's tiles: columns 2-33
            sp_bg = 1'b1;  sp_col = { 1'b0, rd_idx[6:2] } + 6'd2;  sp_typ = rd_idx[1:0];
        end else if (rd_idx >= 8'd160 && rd_idx <= 8'd167) begin   // prefetch: 0, 1
            sp_bg = 1'b1;  sp_nxt = 1'b1;  sp_col = { 5'd0, rd_idx[2] };  sp_typ = rd_idx[1:0];
        end else if (rd_idx >= 8'd168 && rd_idx <= 8'd170) begin   // dummies + read 0
            sp_bg = 1'b1;  sp_nxt = 1'b1;
        end
    end
    wire [7:0] sp_yn = (sp_y == 8'd239) ? 8'd0 : sp_y + 8'd1;
    wire [7:0] sp_ys = sp_nxt ? sp_yn : sp_y;
    wire       sp_side = spc_s[6] ? (sp_col >= { 1'b0, spc_s[4:0] }) : (sp_col < { 1'b0, spc_s[4:0] });
    // off with ExRAM modes 2/3 and with $2001 rendering bits clear (wiki), as ext_on
    wire       sp_in = spc_s[7] && !ex_mode[1] && subst && in_frame && sp_bg && sp_side;
    wire       sp_nt = sp_in && sp_typ == 2'd0 && ppu_addr[13];
    wire       sp_at = sp_in && sp_typ == 2'd1 && ppu_addr[13];
    wire       sp_pt = sp_in && sp_typ[1];
    // ExRAM address of the split's nametable / attribute byte, else the PPU's
    wire [9:0] qb_a = (sp_in && sp_typ == 2'd0) ? { sp_ys[7:3], sp_col[4:0] } :
                      (sp_in && sp_typ == 2'd1) ? { 4'hF, sp_ys[7:5], sp_col[4:2] } :
                                                  ppu_addr[9:0];

    // nametable slot of the current PPU address ($5105: 2 bits per 1 KB)
    wire [1:0] nt_slot = nt_map >> { ppu_addr[11:10], 1'b0 };

    always @(posedge clk) begin
        rd_s  <= { rd_s[1:0], ppu_rd };
        wr_s  <= { wr_s[1:0], ppu_wr };
        m2_s  <= { m2_s[1:0], m2 };
        ack_s <= { ack_s[0], ack_t };
        clr_s <= { clr_s[0], clr_t };
        exw_s <= { exw_s[0], exw_t };
        ack_p <= ack_s[1];
        clr_p <= clr_s[1];
        exw_p <= exw_s[1];
        cmp_s <= irq_cmp;
        spc_s <= sp_ctl;
        sps_s <= sp_scr;
        spb_s <= sp_bank;
        pw_go <= 1'b0;

        if (rst) begin
            in_frame <= 1'b0;  pend <= 1'b0;  scan <= 8'd0;  match <= 2'd0;
            idle <= 2'd0;      rd_idx <= 8'd255;
        end else begin
            if (rd_fall)
                rd_addr <= ppu_addr;                     // stable while /RD is low
            // extended attributes: the tile's ExRAM byte, taken in the middle
            // of its nametable read (port B follows ppu_addr; at the end of
            // the read the PPU may already show the next address)
            if (!rd_s[1]) begin
                if (rd_cnt != 2'd3)
                    rd_cnt <= rd_cnt + 2'd1;
                // any nametable (not attribute) read in frame outside the
                // sprite fetches: also the line's first tile, whose read only
                // becomes "read 0" when it ends (it completes the scanline
                // signature), and the two dummy reads before it (same address)
                if (rd_cnt == 2'd2 && in_frame && !spr_fetch && ppu_addr[13] &&
                    ppu_addr[9:6] != 4'hF)
                    ex_lat <= qb;
            end else
                rd_cnt <= 2'd0;
            if (rd_rise) begin
                idle      <= 2'd0;
                last_addr <= rd_addr;
                if (rd_idx != 8'd255)
                    rd_idx <= rd_idx + 8'd1;
                if (third) begin                         // new scanline
                    match  <= 2'd0;
                    rd_idx <= 8'd1;                      // this read was read 0
                    if (!in_frame) begin
                        in_frame <= 1'b1;
                        scan     <= 8'd0;
                        pend     <= 1'b0;
                        sp_y     <= sps_s;               // split counter: $5201 at line 0
                    end else begin
                        sp_y <= sp_yn;
                        scan <= scan + 8'd1;
                        if (scan + 8'd1 == cmp_s)
                            pend <= 1'b1;
                    end
                end else if (nt_read && rd_addr == last_addr)
                    match <= (match == 2'd2) ? 2'd2 : match + 2'd1;
                else
                    match <= nt_read ? 2'd1 : 2'd0;
            end
            // no PPU read for 3 M2 rising edges: not rendering
            if (m2_rise && !rd_rise) begin
                if (idle == 2'd2) begin
                    in_frame <= 1'b0;
                    pend     <= 1'b0;
                    rd_idx   <= 8'd255;
                end else
                    idle <= idle + 2'd1;
            end
            if (ack_s[1] != ack_p)
                pend <= 1'b0;
            if (clr_s[1] != clr_p) begin
                in_frame <= 1'b0;
                pend     <= 1'b0;
                rd_idx   <= 8'd255;
            end
            if (!in_frame) begin
                scan <= 8'd0;
            end
            // PPU write ($2007, not rendering) to a nametable mapped to ExRAM:
            // address/data sampled once in the middle of the /WR pulse (the
            // second clock after the synchronised falling edge, ~60-80 ns
            // in), written when /WR rises. Sampling until the synchronised
            // rising edge would run past the real one, after the PPU has
            // released the bus.
            if (!wr_s[1]) begin
                if (wr_cnt != 2'd3)
                    wr_cnt <= wr_cnt + 2'd1;
                if (wr_cnt == 2'd1) begin
                    pw_a  <= ppu_addr[9:0];
                    pw_d  <= ppu_dat;
                    pw_ok <= ppu_addr[13] && nt_slot == 2'd2 && !ex_mode[1] && !in_frame;
                end
            end else
                wr_cnt <= 2'd0;
            if (wr_rise && pw_ok)
                pw_go <= 1'b1;
        end
    end

    // ---------------------------------------------------------------- sound
    wire [7:0]  snd_do;
    wire        snd_oe, snd_irq;
    wire [10:0] snd_level;
    mmc5_snd snd (
        .mclk(mclk), .rst(rst), .cpu_addr(cpu_addr), .cpu_ce(cpu_ce), .cpu_rw(cpu_rw),
        .cpu_dat(cpu_dat), .rd_dat(snd_do), .rd_oe(snd_oe), .irq(snd_irq), .level(snd_level)
    );
    aud_dac dac (.clk(clk), .level(snd_level), .gain(aud_gain), .aud(aud));

    assign irq = (pend & irq_en) | snd_irq;

    // ---------------------------------------------------------------- ExRAM
    // 1 KB, clk domain. Port A: CPU reads ($5C00, address from the bus) and
    // all writes (CPU via exw, PPU via pw). Port B: PPU nametable reads.
    reg [7:0] exram [0:1023];
    initial for (i = 0; i < 1024; i = i + 1) exram[i] = 8'd0;
    reg [7:0] qa = 8'd0, qb = 8'd0;
    wire       cw = (exw_s[1] != exw_p);
    wire       wa_en = cw | pw_go;
    wire [9:0] wa = cw ? exw_a : pw_a;
    wire [7:0] wd = cw ? exw_d : pw_d;
    wire [9:0] aa = wa_en ? wa : cpu_addr[9:0];
    always @(posedge clk) begin
        if (wa_en)
            exram[aa] <= wd;
        qa <= exram[aa];
    end
    always @(posedge clk)
        qb <= exram[qb_a];

    // ---------------------------------------------------------------- CHR
    // register for this fetch: set A ($5120-$5127) or set B ($5128-$512B)

    wire use_b     = spr16 && (in_frame ? (subst && !spr_fetch) : last_b);
    wire a12 = ppu_addr[12], a11 = ppu_addr[11], a10 = ppu_addr[10];
    reg  [2:0] ci;                   // index inside the set
    always @* begin
        case (chr_mode)
            2'd0:    ci = 3'd7;
            2'd1:    ci = { a12, 2'b11 };
            2'd2:    ci = { a12, a11, 1'b1 };
            default: ci = { a12, a11, a10 };
        endcase
    end
    wire [3:0] creg_i = use_b ? { 2'b10, ci[1:0] } : { 1'b0, ci };
    wire [9:0] creg   = chr_r[creg_i];
    // CHR A18:A10 (A19 is beyond the board's 512 KB)
    reg  [8:0] cbank;
    always @* begin
        case (chr_mode)
            2'd0:    cbank = { creg[5:0], a12, a11, a10 };       // 8 KB
            2'd1:    cbank = { creg[6:0], a11, a10 };            // 4 KB
            2'd2:    cbank = { creg[7:0], a10 };                 // 2 KB, A19 = $5130.0
            default: cbank = { creg[8:0] };                      // 1 KB, A19 = $5130.1
        endcase
    end
    // extended attributes: background pattern reads use the latched 4 KB page
    wire ex_pat = ext_on && bg_fetch && rd_idx[1] && !sp_in;
    // vertical split: the split region's pattern reads use the $5202 page
    assign chr_a   = sp_pt  ? { spb_s[6:0], a11, a10 } :
                     ex_pat ? { chr_hi[0], ex_lat[5:0], a11, a10 } : cbank;
    assign chr_sel = ~ppu_addr[13];
    assign chr_wr  = chr_is_ram & ~ppu_addr[13] & ~ppu_wr;

    // ---------------------------------------------------------------- nametables
    // slot 0/1: CIRAM page; 2: ExRAM (modes 0/1; else reads $00); 3: fill.
    // Extended attributes: the background attribute read is answered by the
    // MMC5 with the tile's palette (CIRAM off for that read).
    // Vertical split: its nametable and attribute reads come from ExRAM.
    wire   ex_at = ext_on && bg_fetch && rd_idx[1:0] == 2'd1 && ppu_addr[13] && !sp_in;
    assign ciram_sel = ppu_addr[13] & ~nt_slot[1] & ~ex_at & ~sp_nt & ~sp_at;
    assign ciram_a10 = nt_slot[0];
    wire   attr_area = (ppu_addr[9:6] == 4'hF);              // $23C0-$23FF etc.
    wire [7:0] sp_pair = qb >> { sp_ys[4], sp_col[1], 1'b0 };  // the column's 2 bits
    assign ppu_do = sp_at      ? {4{sp_pair[1:0]}} :
                    sp_nt      ? qb :
                    ex_at      ? {4{ex_lat[7:6]}} :
                    nt_slot[0] ? (attr_area ? {4{fill_attr}} : fill_tile)
                               : (ex_mode[1] ? 8'h00 : qb);
    assign ppu_oe = ~ppu_rd & ppu_addr[13] & (nt_slot[1] | ex_at | sp_nt | sp_at);

    // ---------------------------------------------------------------- CPU reads
    wire [15:0] product = mul_a * mul_b;
    wire rd_5204 = reg5 && r == 12'h204;
    wire rd_5205 = reg5 && r == 12'h205;
    wire rd_5206 = reg5 && r == 12'h206;
    wire rd_ex   = exram_c && ex_mode[1];                    // modes 2/3 only
    assign cpu_do = snd_oe  ? snd_do :
                    rd_5204 ? { pend, in_frame, 6'd0 } :
                    rd_5205 ? product[7:0] :
                    rd_5206 ? product[15:8] : qa;
    assign cpu_oe = cpu_rw & (rd_5204 | rd_5205 | rd_5206 | rd_ex | snd_oe);

endmodule
