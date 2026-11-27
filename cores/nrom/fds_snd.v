// n8-open: FDS sound (the RAM adapter's wavetable channel) for map_fds.v.
//
// Written from the public documentation (NESdev wiki: FDS audio; register
// bit meanings checked against Disch's FDS.txt where the wiki contradicts
// itself), not from any existing HDL. Reference model, cycle for cycle:
// tools/n8sim/fds_audio.py (tb_fds_snd compares the two).
//
// Registers ($4040-$4097, decoded here; $4023 bit 1 enables the sound):
//   $4040-$407F  wave RAM, 64 x 6 bits. Writable only while $4089 bit 7 is
//                set; read: bits 7:6 = 01, with bit 7 of $4089 clear the
//                sample at the current wave position (whatever the address)
//   $4080  bit 7 1 = envelope off, bits 5:0 = gain (set directly); 0 =
//          envelope on, bits 5:0 = speed; bit 6 direction (1 = up)
//   $4082/$4083  wave pitch (12 bits); $4083 bit 7 halts the wave unit
//          (position reset to 0), bit 6 halts both envelopes
//   $4084  as $4080, for the modulation gain
//   $4085  modulation counter (7-bit signed)
//   $4086/$4087  modulation pitch (12 bits); $4087 bit 7 halts the mod unit
//          (accumulator bits 12:0 reset; the table address stays), bit 6
//          forces a carry (a step every tick)
//   $4088  mod table entry (3 bits), only while $4087 bit 7 is set: written
//          at the current table address, which then advances
//   $4089  bit 7 wave RAM write enable (output held meanwhile), bits 1:0
//          master volume: 1, 2/3, 2/4, 2/5
//   $408A  envelope speed multiplier (0 = envelopes off)
//   $4090  R volume gain, $4091 R wave accumulator bits 19:12, $4092 R mod
//          gain, $4093 R mod accumulator bits 11:5, $4097 R mod counter
//          ($4094-$4096 read $40: not implemented)
//
// Timing (all per CPU cycle, on falling M2 like the rest of the core):
//   - wave and mod units tick every 16 CPU cycles;
//   - wave: 24-bit accumulator += 20-bit wave pitch per tick; bits 23:18
//     select the sample;
//   - wave pitch = pitch x m, m = the wiki's formula from mod counter x mod
//     gain (rounded up only when positive, centred on $40);
//   - mod: 18-bit accumulator += mod pitch per tick (not while halted or
//     with pitch 0); on a carry out of bit 11 the counter changes by the
//     table entry at address bits 17:13 (taken before the step - not
//     specified; with the "ghost" bit 12 each entry acts twice): 0, +1, +2,
//     +4, reset, -4, -2, -1;
//   - envelopes: a tick every 8 x ($408A + 1) cycles, each envelope steps
//     every (speed + 1) ticks: +1 up to 32, -1 down to 0;
//   - output gain = the volume gain latched while the wave position is 0
//     (or at once when it is set to 0), capped at 32;
//   - output = sample x gain x master volume (/32 scale, 0..2016), then a
//     1-pole low-pass (y += (x - y) / 8 per tick, ~2.4 kHz; the wiki: ~2 kHz).
// Not implemented: $4083 bit 7 "envelopes 4x faster" (only in the wiki's
// diagram, not in its text nor in FDS.txt), the DRAM refresh watchdog, the
// DAC's measured non-linearity.

module fds_snd (
    input             mclk,
    input             rst,           // 1 in menu mode
    input      [14:0] cpu_addr,
    input             cpu_ce,        // /ROMSEL
    input             cpu_rw,
    input      [7:0]  cpu_dat,
    output reg [7:0]  rd_dat,
    output            rd_oe,         // a read the sound unit answers
    output     [10:0] level          // filtered output, 0..2016
);
    wire lo     = cpu_ce;
    wire wave_a = lo & (cpu_addr[14:6] == 9'h101);             // $4040-$407F
    wire reg_a  = lo & (cpu_addr[14:5] == 10'h204);            // $4080-$409F
    wire en_a   = lo & (cpu_addr == 15'h4023);
    wire [4:0] r = cpu_addr[4:0];

    reg [5:0]  wram [0:63];
    reg [2:0]  mtab [0:31];
    reg        vol_dis = 1'b0, vol_dir = 1'b0;
    reg [5:0]  vol_spd = 6'd0, vol_gain = 6'd0, vol_cnt = 6'd0;
    reg        mod_dis = 1'b0, mod_dir = 1'b0;
    reg [5:0]  mod_spd = 6'd0, mod_gain = 6'd0, mod_cnt6 = 6'd0;
    reg [11:0] freq = 12'd0, mfreq = 12'd0;
    reg        wave_halt = 1'b0, env_halt = 1'b0, mod_halt = 1'b0, mod_force = 1'b0;
    reg        wave_wr = 1'b0;
    reg [1:0]  mvol = 2'd0;
    reg [7:0]  env_m = 8'd0;
    reg [10:0] ep = 11'd0;                  // envelope prescaler
    reg [23:0] wacc = 24'd0;
    reg [17:0] macc = 18'd0;
    reg [6:0]  mcnt = 7'd0;                 // signed
    reg [5:0]  out_gain = 6'd0;
    reg [3:0]  div = 4'd0;
    reg [10:0] lvl = 11'd0;                 // before the filter
    reg [15:0] y = 16'd0;                   // filter state, 5 fraction bits

    integer i;
    initial begin
        for (i = 0; i < 64; i = i + 1) wram[i] = 6'd0;
        for (i = 0; i < 32; i = i + 1) mtab[i] = 3'd0;
    end

    // ---- wave pitch from the modulation (wiki pseudocode, see the header)
    wire signed [12:0] prod  = $signed(mcnt) * $signed({ 1'b0, mod_gain });
    wire               rnd   = (prod[3:0] != 4'd0) && !prod[11];
    wire        [13:0] t     = { prod[12], prod } + (rnd ? 14'h20 : 14'h0) + 14'h400;
    wire        [7:0]  mval  = t[11:4];
    wire        [19:0] wpitch = freq * mval;

    // ---- one tick's results
    wire        tick    = (div == 4'd15);
    wire [5:0]  waddr   = wacc[23:18];
    wire [5:0]  sample  = wram[waddr];
    wire [5:0]  g32     = (out_gain > 6'd32) ? 6'd32 : out_gain;
    wire [11:0] raw     = sample * g32;                        // 0..2016
    wire [5:0]  mmul    = (mvol == 2'd0) ? 6'd32 : (mvol == 2'd1) ? 6'd21 :
                          (mvol == 2'd2) ? 6'd16 : 6'd13;      // 1, 2/3, 2/4, 2/5
    wire [17:0] mixed   = raw * mmul;
    wire [12:0] msum    = { 1'b0, macc[11:0] } + { 1'b0, mfreq };
    wire        mcarry  = msum[12] | mod_force;
    wire [2:0]  ment    = mtab[macc[17:13]];
    reg  [6:0]  mdelta;
    always @* begin
        case (ment)
            3'd1: mdelta = 7'd1;
            3'd2: mdelta = 7'd2;
            3'd3: mdelta = 7'd4;
            3'd5: mdelta = 7'h7C;           // -4
            3'd6: mdelta = 7'h7E;           // -2
            3'd7: mdelta = 7'h7F;           // -1
            default: mdelta = 7'd0;
        endcase
    end
    wire        env_tick = (env_m != 8'd0) && (ep == 11'd0);
    wire        vol_run  = !vol_dis && !env_halt;
    wire        mod_run  = !mod_dis && !env_halt;
    // filter step: y += (x - y) / 8, x with 5 fraction bits
    wire signed [16:0] fdiff = $signed({ 1'b0, lvl, 5'b00000 }) - $signed({ 1'b0, y });

    always @(negedge mclk) begin
        if (rst) begin
            vol_dis <= 1'b0;  vol_dir <= 1'b0;  vol_spd <= 6'd0;
            vol_gain <= 6'd0;  vol_cnt <= 6'd0;  mod_dis <= 1'b0;  mod_dir <= 1'b0;
            mod_spd <= 6'd0;  mod_gain <= 6'd0;  mod_cnt6 <= 6'd0;  freq <= 12'd0;
            mfreq <= 12'd0;  wave_halt <= 1'b0;  env_halt <= 1'b0;  mod_halt <= 1'b0;
            mod_force <= 1'b0;  wave_wr <= 1'b0;  mvol <= 2'd0;  env_m <= 8'd0;
            ep <= 11'd0;  wacc <= 24'd0;  macc <= 18'd0;  mcnt <= 7'd0;
            out_gain <= 6'd0;  div <= 4'd0;  lvl <= 11'd0;  y <= 16'd0;
        end else begin
            div <= div + 4'd1;

            // ---- envelopes (prescaler every CPU cycle)
            if (env_m == 8'd0)
                ep <= 11'd0;
            else if (ep == 11'd0)
                ep <= { env_m, 3'b111 };    // 8 x (m + 1) - 1
            else
                ep <= ep - 11'd1;
            if (env_tick && vol_run) begin
                if (vol_cnt == vol_spd) begin
                    vol_cnt <= 6'd0;
                    if (vol_dir && vol_gain < 6'd32)
                        vol_gain <= vol_gain + 6'd1;
                    else if (!vol_dir && vol_gain != 6'd0)
                        vol_gain <= vol_gain - 6'd1;
                end else
                    vol_cnt <= vol_cnt + 6'd1;
            end
            if (env_tick && mod_run) begin
                if (mod_cnt6 == mod_spd) begin
                    mod_cnt6 <= 6'd0;
                    if (mod_dir && mod_gain < 6'd32)
                        mod_gain <= mod_gain + 6'd1;
                    else if (!mod_dir && mod_gain != 6'd0)
                        mod_gain <= mod_gain - 6'd1;
                end else
                    mod_cnt6 <= mod_cnt6 + 6'd1;
            end

            // ---- wave, mod, output: every 16 cycles
            if (tick) begin
                if (wave_halt)
                    wacc <= 24'd0;
                else
                    wacc <= wacc + { 4'd0, wpitch };
                if (waddr == 6'd0)
                    out_gain <= vol_gain;
                if (!wave_wr)
                    lvl <= mixed[15:5];
                y <= y + { {2{fdiff[16]}}, fdiff[16:3] };   // (x - y) / 8, arithmetic
                if (!mod_halt && (mfreq != 12'd0 || mod_force)) begin
                    macc[11:0] <= msum[11:0];
                    if (mcarry) begin
                        macc[17:12] <= macc[17:12] + 6'd1;
                        mcnt <= (ment == 3'd4) ? 7'd0 : mcnt + mdelta;
                    end
                end
            end

            // ---- register writes (after the tick: a write wins)
            if (!cpu_rw) begin
                if (en_a) begin                  // $4023 bit 1 clear: sound reset
                    if (!cpu_dat[1]) begin
                        vol_gain <= 6'd0;  out_gain <= 6'd0;  wacc <= 24'd0;  mcnt <= 7'd0;
                    end
                end
                if (wave_a && wave_wr)
                    wram[cpu_addr[5:0]] <= cpu_dat[5:0];
                if (reg_a) case (r)
                    5'h00: begin
                               vol_dis <= cpu_dat[7];  vol_dir <= cpu_dat[6];
                               vol_spd <= cpu_dat[5:0];  vol_cnt <= 6'd0;
                               if (cpu_dat[7]) begin
                                   vol_gain <= cpu_dat[5:0];
                                   if (cpu_dat[5:0] == 6'd0)
                                       out_gain <= 6'd0;        // muting: at once
                               end
                           end
                    5'h02: freq[7:0] <= cpu_dat;
                    5'h03: begin
                               freq[11:8] <= cpu_dat[3:0];
                               env_halt <= cpu_dat[6];  wave_halt <= cpu_dat[7];
                               if (cpu_dat[7])
                                   wacc <= 24'd0;
                               if (cpu_dat[6]) begin
                                   vol_cnt <= 6'd0;  mod_cnt6 <= 6'd0;
                               end
                           end
                    5'h04: begin
                               mod_dis <= cpu_dat[7];  mod_dir <= cpu_dat[6];
                               mod_spd <= cpu_dat[5:0];  mod_cnt6 <= 6'd0;
                               if (cpu_dat[7])
                                   mod_gain <= cpu_dat[5:0];
                           end
                    5'h05: mcnt <= cpu_dat[6:0];
                    5'h06: mfreq[7:0] <= cpu_dat;
                    5'h07: begin
                               mfreq[11:8] <= cpu_dat[3:0];
                               mod_force <= cpu_dat[6];  mod_halt <= cpu_dat[7];
                               if (cpu_dat[7])
                                   macc[12:0] <= 13'd0;
                           end
                    5'h08: if (mod_halt) begin
                               mtab[macc[17:13]] <= cpu_dat[2:0];
                               macc[17:13] <= macc[17:13] + 5'd1;
                           end
                    5'h09: begin wave_wr <= cpu_dat[7];  mvol <= cpu_dat[1:0]; end
                    5'h0A: env_m <= cpu_dat;
                    default: ;
                endcase
            end
        end
    end

    // ---- reads
    always @* begin
        if (wave_a)
            rd_dat = { 2'b01, wave_wr ? wram[cpu_addr[5:0]] : sample };
        else case (r)
            5'h10: rd_dat = { 2'b01, vol_gain };
            5'h11: rd_dat = wacc[19:12];
            5'h12: rd_dat = { 2'b01, mod_gain };
            5'h13: rd_dat = { 1'b0, macc[11:5] };
            5'h17: rd_dat = { 1'b0, mcnt };
            default: rd_dat = 8'h40;
        endcase
    end
    assign rd_oe = cpu_rw & (wave_a | (reg_a & r[4:3] == 2'b10));   // $4090-$4097
    assign level = y[15:5];
endmodule
