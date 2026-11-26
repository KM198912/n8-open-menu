// n8-open: menu mode ("OS map", mapper index $FF) for the EverDrive N8 clone.
//
// Written from docs/hw-interface.md. Behaviour the existing menu relies on:
//   $4400 (mirrored every 4 bytes in $4400-$45FF): register index
//   $4401: register data, writes only take effect in menu mode
//   $80  2 KB PRG RAM page at $4800-$4FFF
//   $81  8 KB save SRAM page at $6000-$7FFF
//   $82  4 KB CHR page: PPU $1000-$1FFF = page n, $0000-$0FFF = page n-1
//   $83  active mapper index ($FF = menu)
//   $84  PRG size mask (A14-A18)
//   $85  CHR size mask (A13-A18), bit 7 = CHR RAM
//   $86  mapper config bits
//   $87  Game Genie: not implemented, writes are ignored
//   $88  bit 0: reset timeout long/short
//   $89  audio gain for cores with expansion audio (128 = 1.0)
// The menu's own PRG ($8000-$FFFF) sits in the save SRAM at $18000-$1FFFF
// while the MAX II reports "BIOS off".
//
// Return to the menu: when M2 stops toggling (the console holds the CPU in
// reset), the mapper index goes back to $FF.

module n8_osmap #(
    parameter RET_MENU = 0         // 1 = ret_menu latch; broke core start-up on hardware, see BACKLOG.md
) (
    input         clk,
    input         mclk,          // M2 on a clock pin, used to clock the registers
    input         m2,

    input  [7:0]  cpu_dat,
    input  [14:0] cpu_addr,
    input         cpu_ce,        // /ROMSEL
    input         cpu_rw,
    input  [13:0] ppu_addr,
    input         ppu_wr,        // /WR
    input         bios_off,

    output reg [7:0] map_idx,
    output reg [4:0] prg_size,
    output reg [5:0] chr_size,
    output reg       chr_is_ram,
    output reg [6:0] map_cfg,
    output reg [7:0] aud_gain,
    output           bus_quiet,
    output           m2_ok,

    // memory signals for menu mode
    output [18:10] prg_a,
    output         prg_rom,      // select PRG SRAM
    output         prg_ram,      // select save SRAM
    output         prg_wr,
    output [18:10] chr_a,
    output         chr_sel,
    output         chr_wr,
    output         ciram_a10,
    output         ciram_sel
);

    initial map_idx    = 8'hFF;  // power-up / after configuration: menu mode
    initial prg_size   = 5'd0;
    initial chr_size   = 6'd0;
    initial chr_is_ram = 1'b0;
    initial map_cfg    = 7'd0;
    initial aud_gain   = 8'd128;

    // ------------------------------------------------------------------
    // Address decoding (cpu_ce high = CPU $0000-$7FFF)
    // ------------------------------------------------------------------
    wire rom_area = ~cpu_ce;                                       // $8000-$FFFF
    wire ram_area =  cpu_ce & (cpu_addr[14:13] == 2'b11);          // $6000-$7FFF
    wire win_area =  cpu_ce & (cpu_addr[14:11] == 4'b1001);        // $4800-$4FFF
    // Signature window: the last 2 KB of PRG RAM at $5000-$57FF. The clone's
    // boot core leaves $5000 unmapped (open bus), so the menu can tell by a
    // write/read-back test whether this core is loaded. The PRG RAM chip
    // answers, the FPGA never drives the CPU bus.
    wire sig_area =  cpu_ce & (cpu_addr[14:11] == 4'b1010);        // $5000-$57FF
    wire reg_area =  cpu_ce & (cpu_addr[14:9]  == 6'b100010);      // $4400-$45FF
    wire reg_index = reg_area & (cpu_addr[1:0] == 2'd0);
    wire reg_data  = reg_area & (cpu_addr[1:0] == 2'd1);

    wire menu = (map_idx == 8'hFF);

    // ------------------------------------------------------------------
    // Registers, written at the end of the CPU cycle (falling M2)
    // ------------------------------------------------------------------
    // explicit power-up values (= the FPGA's register power-up state, and
    // needed so a simulator does not start from X)
    reg [7:0] index      = 8'd0;
    reg [7:0] prg_page   = 8'd0;     // $80
    reg [5:0] sram_page  = 6'd0;     // $81
    reg [6:0] chr_page   = 7'd0;     // $82
    reg       long_reset = 1'b0;     // $88 bit 0
    reg       m2_toggle  = 1'b0;
    // Set when a reset brings us back from a game. From then on the menu
    // image in the save SRAM is shown at $8000 without waiting for the
    // CPLD's "BIOS off" line: on the clone the CPLD does not raise it again
    // after a console reset (the CPU then fetched its reset vector from an
    // empty bus). Cleared only by reconfiguration.
    reg       ret_menu = 1'b0;

    wire menu_reset;             // from the M2 watchdog below

    always @(negedge mclk) begin
        m2_toggle <= ~m2_toggle;

        if (reg_index & ~cpu_rw)
            index <= cpu_dat;

        if (RET_MENU != 0 && menu_reset && !menu)
            ret_menu <= 1'b1;

        if (menu_reset)
            map_idx <= 8'hFF;
        else if (reg_data & ~cpu_rw & menu) begin
            case (index)
                8'h80: prg_page  <= cpu_dat;
                8'h81: sram_page <= cpu_dat[5:0];
                8'h82: chr_page  <= cpu_dat[6:0];
                8'h83: map_idx   <= cpu_dat;
                8'h84: prg_size  <= cpu_dat[4:0];
                8'h85: begin
                           chr_size   <= cpu_dat[5:0];
                           chr_is_ram <= cpu_dat[7];
                       end
                8'h86: map_cfg   <= cpu_dat[6:0];
                8'h88: long_reset <= cpu_dat[0];
                8'h89: aud_gain  <= cpu_dat;
                default: ;                       // $87 (Game Genie) and others ignored
            endcase
        end
    end

    // ------------------------------------------------------------------
    // M2 watchdog and settle filter (board clock domain)
    // ------------------------------------------------------------------
    reg [2:0]  toggle_sync = 3'd0;
    reg [25:0] idle        = 26'd0;
    reg [3:0]  m2_hist     = 4'd0;
    reg        quiet_r     = 1'b0;
    reg        reset_r     = 1'b0;

    always @(posedge clk) begin
        toggle_sync <= { toggle_sync[1:0], m2_toggle };
        m2_hist     <= { m2_hist[2:0], m2 };

        if (toggle_sync[2] != toggle_sync[1]) begin
            idle    <= 26'd0;              // M2 is running
            quiet_r <= 1'b0;
            reset_r <= 1'b0;
        end else begin
            if (~idle[25])
                idle <= idle + 26'd1;
            quiet_r <= idle[7];
            reset_r <= long_reset ? idle[25] : idle[7];
        end
    end

    assign bus_quiet  = quiet_r;
    assign menu_reset = reset_r;
    assign m2_ok      = (m2_hist == 4'b1111) & m2;

    // ------------------------------------------------------------------
    // Menu-mode memory map
    // ------------------------------------------------------------------
    // PRG/SRAM address bits 18:10
    assign prg_a = rom_area ? { 4'b0011, cpu_addr[14:10] } :      // menu PRG at $18000
                   ram_area ? { sram_page, cpu_addr[12:10] } :    // save SRAM window
                   sig_area ? { 8'hFF, cpu_addr[10] } :           // signature window
                              { prg_page, cpu_addr[10] };         // PRG RAM window

    assign prg_rom = (win_area | sig_area) & m2;
    assign prg_ram = m2 & (ram_area | ((bios_off | ret_menu) & rom_area));
    assign prg_wr  = ~cpu_rw & m2;

    // CHR: 8 KB view made of pages n-1 and n
    assign chr_a   = { (ppu_addr[12] ? chr_page : chr_page - 7'd1), ppu_addr[11:10] };
    assign chr_sel = ~ppu_addr[13];
    assign chr_wr  = ~ppu_wr;

    assign ciram_a10 = 1'b0;
    assign ciram_sel = ppu_addr[13];

endmodule
