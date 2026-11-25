; EverDrive N8 clone + NES registers, see docs/hw-interface.md

PPUCTRL     = $2000
PPUMASK     = $2001
PPUSTATUS   = $2002
PPUSCROLL   = $2005
PPUADDR     = $2006
PPUDATA     = $2007
APU_FRAME   = $4017

N8_IDX      = $4400     ; register index
N8_DAT      = $4401     ; register data
N8_MODE     = $4402     ; CPLD transfer mode ($03 idle)
N8_STAT     = $4403     ; R: bit 0 SPI done; W: FPGA config byte

; CPLD registers
CPLD_SPI    = $00       ; SPI data (SD card)
CPLD_CTL    = $02       ; bit 0 speed, bit 1 CS (1 = off), bit 2 auto-read, bit 3 setting (BIOS option)
CPLD_CFG    = $05       ; FPGA config data
CPLD_NCFG   = $06       ; FPGA nCONFIG
CPLD_FBANK  = $07       ; flash bank
CPLD_MEM    = $09       ; bits 1:0 source of $8000 (01 menu SRAM, 10 flash)

CTL_CS      = $02
CTL_AUTO    = $04

; FPGA OS map registers (write-only)
FPGA_PRG_PAGE  = $80    ; 2 KB PRG RAM page at $4800
FPGA_SRAM_PAGE = $81    ; 8 KB save SRAM page at $6000
FPGA_CHR_PAGE  = $82    ; 4 KB CHR page (PPU $1000 = n, $0000 = n-1)
FPGA_MAPPER    = $83
FPGA_PRG_SIZE  = $84
FPGA_CHR_SIZE  = $85
FPGA_MAP_CFG   = $86
FPGA_GG        = $87
FPGA_CART_CFG  = $88

SECBUF      = $0400     ; 512-byte sector buffer
BUF2        = $0600     ; second 512-byte buffer (auto-read probe)
