# EverDrive N8 - Cyclone II pinout (EP2C5T144C8)

Source: pin assignments of Krikzz's mapper sample (`edfc-fpga.qsf`). Device
settings there: family Cyclone II, `EP2C5T144C8`, I/O standard 3.3-V LVTTL,
RBF generation on. These are hardware facts of the board; the signal names
are ours to change.

## CPU bus

| Signal | Pin | | Signal | Pin |
|---|---|---|---|---|
| cpu_addr[0] | 67 | | cpu_dat[0] | 87 |
| cpu_addr[1] | 65 | | cpu_dat[1] | 86 |
| cpu_addr[2] | 64 | | cpu_dat[2] | 81 |
| cpu_addr[3] | 63 | | cpu_dat[3] | 80 |
| cpu_addr[4] | 60 | | cpu_dat[4] | 72 |
| cpu_addr[5] | 48 | | cpu_dat[5] | 71 |
| cpu_addr[6] | 47 | | cpu_dat[6] | 70 |
| cpu_addr[7] | 45 | | cpu_dat[7] | 69 |
| cpu_addr[8] | 44 | | cpu_ce (/ROMSEL; low = `$8000-$FFFF`) | 88 |
| cpu_addr[9] | 43 | | cpu_rw | 94 |
| cpu_addr[10] | 26 | | cpu_m2 | 27 |
| cpu_addr[11] | 25 | | mclk (M2 on a clock input) | 21 |
| cpu_addr[12] | 28 | | cpu_irq (open drain) | 96 |
| cpu_addr[13] | 24 | | cpu_exp (expansion audio pin) | 97 |
| cpu_addr[14] | 30 | | | |

## PPU bus

| Signal | Pin | | Signal | Pin |
|---|---|---|---|---|
| ppu_addr[0] | 115 | | ppu_dat[0] | 119 |
| ppu_addr[1] | 114 | | ppu_dat[1] | 120 |
| ppu_addr[2] | 113 | | ppu_dat[2] | 121 |
| ppu_addr[3] | 112 | | ppu_dat[3] | 122 |
| ppu_addr[4] | 93 | | ppu_dat[4] | 139 |
| ppu_addr[5] | 91 | | ppu_dat[5] | 137 |
| ppu_addr[6] | 9 | | ppu_dat[6] | 136 |
| ppu_addr[7] | 92 | | ppu_dat[7] | 135 |
| ppu_addr[8] | 4 | | ppu_rd | 89 |
| ppu_addr[9] | 104 | | ppu_wr | 90 |
| ppu_addr[10] | 101 | | ppu_ciram_ce | 99 |
| ppu_addr[11] | 103 | | ppu_ciram_a10 | 100 |
| ppu_addr[12] | 2 | | ppu_dir (data buffer direction) | 7 |
| ppu_addr[13] | 3 | | ppu_ex (data buffer enable) | 8 |

## Memories

The SRAMs get A0-A9 directly from the console bus; the FPGA drives A10-A18.

| Signal | Pin | | Signal | Pin |
|---|---|---|---|---|
| prg_map[0] (PRG A10) | 58 | | chr_map[0] (CHR A10) | 1 |
| prg_map[1] (A11) | 59 | | chr_map[1] (A11) | 144 |
| prg_map[2] (A12) | 57 | | chr_map[2] (A12) | 143 |
| prg_map[3] (A13) | 55 | | chr_map[3] (A13) | 142 |
| prg_map[4] (A14) | 53 | | chr_map[4] (A14) | 141 |
| prg_map[5] (A15) | 73 | | chr_map[5] (A15) | 133 |
| prg_map[6] (A16) | 74 | | chr_map[6] (A16) | 132 |
| prg_map[7] (A17) | 75 | | chr_map[7] (A17) | 129 |
| prg_map[8] (A18) | 76 | | chr_map[8] (A18) | 126 |
| prg_ce | 52 | | chr_ce | 118 |
| prg_oe | 79 | | chr_oe | 134 |
| prg_we | 51 | | chr_we | 125 |
| ram_ce (save SRAM) | 32 | | | |
| ram_oe | 42 | | | |
| ram_we | 31 | | | |

The save SRAM shares the PRG address lines.

## CPLD link and clock

| Signal | Pin | Function |
|---|---|---|
| clk | 17 | board oscillator (frequency still to be determined) |
| max0 | 40 | bus mode bit 0 to the MAX II |
| max1 | 41 | bus mode bit 1 to the MAX II |
| max2 | 18 | from the MAX II (`bios_off` in the sample) |

Configuration pins in use (passive serial from the MAX II): TDO 10, TMS 11,
TCK 12, TDI 13, DATA0 14, DCLK 15, nCE 16, nCONFIG 20, nSTATUS 82,
CONF_DONE 83, MSEL1 84, MSEL0 85.
