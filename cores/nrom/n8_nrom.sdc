# n8-open: timing constraints for the NROM core (EverDrive N8 clone, EP2C5T144C8)
#
# Without constraints Quartus neither optimises nor checks the paths that
# matter, so builds of the same sources could differ in behaviour. These
# constraints are deliberately conservative.

# ---------------------------------------------------------------- clocks
# Board clock on pin 17: source and frequency unknown (no oscillator on
# side A). The menu-mode M2 settle filter needs four samples per M2 high
# phase (~280 ns), so it is at least ~15 MHz; 50 MHz is a safe upper bound.
create_clock -name clk  -period 20.000  [get_ports clk]

# M2 on its clock pin, used to clock the register file. NTSC 1.79 MHz
# (PAL 1.66 MHz is slower and therefore covered).
create_clock -name mclk -period 558.000 [get_ports mclk]

derive_clock_uncertainty

# The two domains are asynchronous; osmap.v synchronises the M2 toggle and
# the watchdog flags explicitly.
set_clock_groups -asynchronous -group {clk} -group {mclk}

# ---------------------------------------------------------------- bus paths
# Console bus inputs and the board outputs they drive combinationally
# (address decoding, chip enables, SRAM upper address lines, mirroring,
# and the data buses a mapper answers reads on: MMC5).
set bus_in  [get_ports {cpu_addr[*] cpu_ce cpu_rw cpu_m2 cpu_dat[*] ppu_addr[*] ppu_rd ppu_wr ppu_dat[*] max2}]
set bus_out [get_ports {prg_map[*] prg_ce prg_oe prg_we chr_map[*] chr_ce chr_oe chr_we ram_ce ram_oe ram_we ppu_ciram_ce ppu_ciram_a10 ppu_dir ppu_ex cpu_irq max0 max1 cpu_dat[*] ppu_dat[*] cpu_exp}]

# Address/control in -> chip enable/address out: the SRAMs (10 ns, 70 ns for
# the save SRAM) need the rest of the CPU/PPU cycle, so keep this short.
set_max_delay -from $bus_in -to $bus_out 25.000

# Mapper/menu registers -> outputs (bank registers driving SRAM address
# lines, mirroring, enables).
set_max_delay -from [get_registers *] -to $bus_out 25.000

# Bus inputs -> registers (register writes are captured on the falling M2
# edge; the data is valid well before it).
set_max_delay -from $bus_in -to [get_registers *] 50.000
