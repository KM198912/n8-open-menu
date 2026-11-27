// n8-open: MMC5 sound (mmc5_snd.v) against the reference model
// tools/n8sim/mmc5_audio.py, cycle for cycle:
//   python tools/n8sim/mmc5_audio.py gen mmc5_snd_stim.hex
//   iverilog -g2005 -o tb_mmc5_snd tb_mmc5_snd.v ../nrom/mmc5_snd.v
//   vvp -n tb_mmc5_snd           (writes mmc5_snd_out.txt)
//   python tools/n8sim/mmc5_audio.py check mmc5_snd_stim.hex mmc5_snd_out.txt
// One stimulus line per CPU cycle: rw (1 digit), address (4), data (2) -
// for reads the data is what the bus carries (PRG ROM bytes for the PCM
// read mode). Per cycle the output line holds the level and the IRQ after
// the cycle's falling M2 edge, and the data of a read the unit answers (0
// otherwise) before it.
`timescale 1ns/1ps

module tb_mmc5_snd;
    parameter N = 400000;
    reg  [27:0] stim [0:N-1];
    // M2 starts high: an initial x -> 0 would count as a falling edge
    reg         m2 = 1, rw = 1;
    reg  [15:0] a = 16'h0000;
    reg  [7:0]  d = 8'h00;
    wire [7:0]  rd_dat;
    wire        rd_oe, irq;
    wire [10:0] level;

    mmc5_snd dut (
        .mclk(m2), .rst(1'b0), .cpu_addr(a[14:0]), .cpu_ce(~a[15]), .cpu_rw(rw),
        .cpu_dat(d), .rd_dat(rd_dat), .rd_oe(rd_oe), .irq(irq), .level(level)
    );

    integer i, n, f;
    reg [7:0] rv;
    initial begin
        for (i = 0; i < N; i = i + 1) stim[i] = 28'hFFFFFFF;
        $readmemh("mmc5_snd_stim.hex", stim);
        n = 0;
        while (n < N && stim[n] != 28'hFFFFFFF) n = n + 1;
        f = $fopen("mmc5_snd_out.txt", "w");
        for (i = 0; i < n; i = i + 1) begin
            rw = stim[i][24];
            a  = stim[i][23:8];
            d  = stim[i][7:0];
            #100;
            rv = (rw && rd_oe) ? rd_dat : 8'h00;
            m2 = 0;                    // the cycle's falling edge
            #10;
            $fwrite(f, "%h %h %h\n", level, rv, irq);
            #90 m2 = 1;
        end
        $fclose(f);
        $display("tb_mmc5_snd: %0d cycles written", n);
        $finish;
    end
endmodule
