// n8-open: expansion audio DAC on cpu_exp, shared by the cores with sound
// (VRC6, FDS).
//
// level: 11 bits from the core's own clock domain (CPU cycles). Full scale
// of a chip should come out near 1952-2016 (VRC6: mix 0..61 x 32 = 1952,
// FDS: sample 63 x gain 32 = 2016).
// gain: menu register $89, 128 = 1.0. At 1.0 the output uses
// level x 128 / 256 = up to ~1000 of 1024 steps; higher gains clamp.
// Then a first-order sigma-delta modulator updated every 16 board clocks
// (3.125 MHz, about the rate the original firmware's PWM uses on this pin;
// 50 MHz toggling gave no audible output on hardware), inverted as the
// cartridge audio path expects; the board/console filter smooths it.

module aud_dac (
    input         clk,           // board clock
    input  [10:0] level,
    input  [7:0]  gain,
    output        aud
);
    reg  [10:0] lv_c = 11'd0;
    reg  [18:0] prod = 19'd0;
    reg  [3:0]  sd_div = 4'd0;
    reg  [10:0] sd = 11'd0;
    reg         aud_r = 1'b1;
    wire [9:0]  lvl10 = prod[18] ? 10'd1023 : prod[17:8];      // clamp
    always @(posedge clk) begin
        lv_c   <= level;
        prod   <= lv_c * gain;
        sd_div <= sd_div + 4'd1;
        if (sd_div == 4'd0) begin
            sd    <= { 1'b0, sd[9:0] } + { 1'b0, 10'd1023 - lvl10 };
            aud_r <= sd[10];
        end
    end
    assign aud = aud_r;
endmodule
