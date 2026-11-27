// n8-open: MMC5 sound (two pulse channels + 8-bit PCM) for map_mmc5.v.
//
// Written from the public documentation (NESdev wiki: MMC5 audio, APU
// Pulse), not from any existing HDL. Reference model, cycle for cycle:
// tools/n8sim/mmc5_audio.py (tb_mmc5_snd compares the two).
//
// Documented (MMC5 audio):
//   - the pulses behave like the APU's, but: no sweep ($5001/$5005 do
//     nothing), periods below 8 are not muted, envelope and length counter
//     are both clocked at a fixed ~240 Hz (die estimate: M2 / 7424), not
//     by $4017 - the length counter runs twice as fast as the APU's
//   - the length table is the NTSC APU's; envelope and phase reset as in
//     the APU
//   - $5010 write: bit 7 PCM IRQ enable, bit 0 mode (0 write, 1 read);
//     read: bit 7 IRQ flag (cleared by the read), bit 0 = 0 (MMC5, not A)
//   - $5011: 8-bit DAC value (write mode); in read mode every CPU read of
//     $8000-$BFFF sets it; the value $00 changes nothing and sets the IRQ
//     flag instead (the wiki's pseudocode)
//   - volume: a pulse as loud as an APU pulse, PCM as loud as the APU's DMC
//     with the same input (twice with the 8th bit)
// Inferred (the wiki only says "almost identical to the APU"):
//   - $5000/$5004 and $5003/$5007 have the APU's $4000/$4003 layouts:
//     DDLC VVVV (duty, length halt = envelope loop, constant volume,
//     volume / envelope period), LLLL LHHH (length index, period bits 10:8)
//   - the pulse timer is clocked every other CPU cycle (APU cycles), the
//     sequencer steps when it reloads, a $5003/$5007 write resets it
//   - $5015 write: bit n = 0 disables channel n and clears its length
//     counter, bit n = 1 lets $5003/$5007 load it; read: bits 1:0 = length
//     counter > 0 (as $4015)
// Not implemented: the reversed output polarity against the APU (inaudible
// for separate sounds, only tones that cancel the 2A03's would differ).
//
// Output level (linear, 11 bits, to aud_dac.v): pulses x 32 each (volume
// 15 = 480, as a VRC6 pulse at 15), PCM x 4. PCM is about 3.5 x quieter
// than the wiki's ratio so that both fit: part of the open level
// calibration (only Shin 4 Nin Uchi Mahjong uses the PCM channel).

module mmc5_snd (
    input             mclk,
    input             rst,           // 1 in menu mode
    input      [14:0] cpu_addr,
    input             cpu_ce,        // /ROMSEL
    input             cpu_rw,
    input      [7:0]  cpu_dat,
    output reg [7:0]  rd_dat,
    output            rd_oe,         // a read the sound unit answers ($5010, $5015)
    output            irq,           // PCM IRQ
    output     [10:0] level
);
    localparam FRAME = 13'd7423;     // 240 Hz: M2 / 7424

    wire lo    = cpu_ce;
    wire snd_a = lo & (cpu_addr[14:5] == 10'h280);           // $5000-$501F
    wire [4:0] r = cpu_addr[4:0];
    wire pcm_rd_a = ~cpu_ce & ~cpu_addr[14];                 // $8000-$BFFF

    // per pulse: index 0 = $5000-$5003, 1 = $5004-$5007
    reg [1:0]  duty   [0:1];
    reg        halt   [0:1];         // length halt / envelope loop
    reg        cvol   [0:1];
    reg [3:0]  vol    [0:1];
    reg [10:0] period [0:1];
    reg [10:0] tmr    [0:1];
    reg [2:0]  seq    [0:1];
    reg [7:0]  len    [0:1];
    reg        estart [0:1];
    reg [3:0]  ediv   [0:1];
    reg [3:0]  decay  [0:1];
    reg [1:0]  en = 2'b00;           // $5015
    reg        apu = 1'b0;           // APU cycle phase (timer every other cycle)
    reg [12:0] fdiv = 13'd0;
    reg        pcm_mode = 1'b0, pcm_ien = 1'b0, pcm_flag = 1'b0;
    reg [7:0]  dac = 8'd0;
    integer k;
    initial for (k = 0; k < 2; k = k + 1) begin
        duty[k] = 2'd0; halt[k] = 1'b0; cvol[k] = 1'b0; vol[k] = 4'd0; period[k] = 11'd0;
        tmr[k] = 11'd0; seq[k] = 3'd0; len[k] = 8'd0; estart[k] = 1'b0; ediv[k] = 4'd0;
        decay[k] = 4'd0;
    end

    // NTSC APU length table
    function [7:0] len_of(input [4:0] i);
        case (i)
            5'h00: len_of = 8'd10;   5'h01: len_of = 8'd254;  5'h02: len_of = 8'd20;   5'h03: len_of = 8'd2;
            5'h04: len_of = 8'd40;   5'h05: len_of = 8'd4;    5'h06: len_of = 8'd80;   5'h07: len_of = 8'd6;
            5'h08: len_of = 8'd160;  5'h09: len_of = 8'd8;    5'h0A: len_of = 8'd60;   5'h0B: len_of = 8'd10;
            5'h0C: len_of = 8'd14;   5'h0D: len_of = 8'd12;   5'h0E: len_of = 8'd26;   5'h0F: len_of = 8'd14;
            5'h10: len_of = 8'd12;   5'h11: len_of = 8'd16;   5'h12: len_of = 8'd24;   5'h13: len_of = 8'd18;
            5'h14: len_of = 8'd48;   5'h15: len_of = 8'd20;   5'h16: len_of = 8'd96;   5'h17: len_of = 8'd22;
            5'h18: len_of = 8'd192;  5'h19: len_of = 8'd24;   5'h1A: len_of = 8'd72;   5'h1B: len_of = 8'd26;
            5'h1C: len_of = 8'd16;   5'h1D: len_of = 8'd28;   5'h1E: len_of = 8'd32;   5'h1F: len_of = 8'd30;
        endcase
    endfunction

    // APU duty sequences, indexed by the sequencer step
    function duty_bit(input [1:0] d, input [2:0] s);
        case (d)
            2'd0:    duty_bit = (s == 3'd1);                        // 0 1 0 0 0 0 0 0
            2'd1:    duty_bit = (s == 3'd1) | (s == 3'd2);          // 0 1 1 0 0 0 0 0
            2'd2:    duty_bit = (s >= 3'd1) & (s <= 3'd4);          // 0 1 1 1 1 0 0 0
            default: duty_bit = ~((s == 3'd1) | (s == 3'd2));       // 1 0 0 1 1 1 1 1
        endcase
    endfunction

    wire frame = (fdiv == FRAME);
    wire [3:0] out0 = (len[0] != 8'd0 && duty_bit(duty[0], seq[0])) ? (cvol[0] ? vol[0] : decay[0]) : 4'd0;
    wire [3:0] out1 = (len[1] != 8'd0 && duty_bit(duty[1], seq[1])) ? (cvol[1] ? vol[1] : decay[1]) : 4'd0;
    assign level = { 2'b00, out0, 5'd0 } + { 2'b00, out1, 5'd0 } + { 1'b0, dac, 2'b00 };
    assign irq = pcm_flag & pcm_ien;

    // reads
    assign rd_oe = cpu_rw & snd_a & (r == 5'h10 || r == 5'h15);
    always @* begin
        if (r == 5'h10)
            rd_dat = { pcm_flag, 7'd0 };
        else
            rd_dat = { 6'd0, len[1] != 8'd0, len[0] != 8'd0 };
    end

    wire [1:0] wch = { 1'b0, r[2] };   // pulse a $5000-$5007 write goes to

    always @(negedge mclk) begin
        if (rst) begin
            en <= 2'b00;  apu <= 1'b0;  fdiv <= 13'd0;
            pcm_mode <= 1'b0;  pcm_ien <= 1'b0;  pcm_flag <= 1'b0;  dac <= 8'd0;
            for (k = 0; k < 2; k = k + 1) begin
                duty[k] <= 2'd0; halt[k] <= 1'b0; cvol[k] <= 1'b0; vol[k] <= 4'd0;
                period[k] <= 11'd0; tmr[k] <= 11'd0; seq[k] <= 3'd0; len[k] <= 8'd0;
                estart[k] <= 1'b0; ediv[k] <= 4'd0; decay[k] <= 4'd0;
            end
        end else begin
            apu  <= ~apu;
            fdiv <= frame ? 13'd0 : fdiv + 13'd1;
            for (k = 0; k < 2; k = k + 1) begin
                // timer: every other CPU cycle; the sequencer steps on reload
                if (apu) begin
                    if (tmr[k] == 11'd0) begin
                        tmr[k] <= period[k];
                        seq[k] <= seq[k] - 3'd1;
                    end else
                        tmr[k] <= tmr[k] - 11'd1;
                end
                // 240 Hz: envelope and length counter
                if (frame) begin
                    if (estart[k]) begin
                        estart[k] <= 1'b0;
                        decay[k]  <= 4'd15;
                        ediv[k]   <= vol[k];
                    end else if (ediv[k] == 4'd0) begin
                        ediv[k] <= vol[k];
                        if (decay[k] != 4'd0)
                            decay[k] <= decay[k] - 4'd1;
                        else if (halt[k])
                            decay[k] <= 4'd15;
                    end else
                        ediv[k] <= ediv[k] - 4'd1;
                    if (!halt[k] && len[k] != 8'd0)
                        len[k] <= len[k] - 8'd1;
                end
            end

            // PCM read mode: reads of $8000-$BFFF go to the DAC
            if (cpu_rw && pcm_rd_a && pcm_mode) begin
                if (cpu_dat == 8'd0)
                    pcm_flag <= 1'b1;
                else
                    dac <= cpu_dat;
            end
            if (cpu_rw && snd_a && r == 5'h10)
                pcm_flag <= 1'b0;                // read acknowledges

            // register writes (override what the cycle computed)
            if (!cpu_rw && snd_a) begin
                if (r[4:3] == 2'b00) case (r[1:0])
                    2'd0: begin
                              duty[wch] <= cpu_dat[7:6];  halt[wch] <= cpu_dat[5];
                              cvol[wch] <= cpu_dat[4];    vol[wch]  <= cpu_dat[3:0];
                          end
                    2'd2: period[wch][7:0] <= cpu_dat;
                    2'd3: begin
                              period[wch][10:8] <= cpu_dat[2:0];
                              if (en[wch])
                                  len[wch] <= len_of(cpu_dat[7:3]);
                              seq[wch]    <= 3'd0;
                              estart[wch] <= 1'b1;
                          end
                    default: ;                   // $5001/$5005: no sweep
                endcase
                if (r == 5'h10) begin
                    pcm_ien  <= cpu_dat[7];
                    pcm_mode <= cpu_dat[0];
                end
                if (r == 5'h11 && !pcm_mode) begin
                    if (cpu_dat == 8'd0)
                        pcm_flag <= 1'b1;
                    else
                        dac <= cpu_dat;
                end
                if (r == 5'h15) begin
                    en <= cpu_dat[1:0];
                    if (!cpu_dat[0]) len[0] <= 8'd0;
                    if (!cpu_dat[1]) len[1] <= 8'd0;
                end
            end
        end
    end
endmodule
