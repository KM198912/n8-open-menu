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
FPGA_AUD_GAIN  = $89    ; expansion audio gain (our cores), 128 = 1.0
AUD_GAIN_DEFAULT = 128  ; until calibrated (tests/vrc6_tone.s)
FPGA_CHR_PAGE  = $82    ; 4 KB CHR page (PPU $1000 = n, $0000 = n-1)
FPGA_MAPPER    = $83
FPGA_PRG_SIZE  = $84
FPGA_CHR_SIZE  = $85
FPGA_MAP_CFG   = $86
FPGA_GG        = $87
FPGA_CART_CFG  = $88
; FDS core (map_fds.v), menu mode only
FPGA_FDS_TLO   = $91    ; block table address bits 7:0
FPGA_FDS_THI   = $92    ; bits 9:8 (= side)
FPGA_FDS_TDAT  = $93    ; entry: low byte, then high byte
FPGA_FDS_SIDE  = $94    ; bits 1:0 side, bit 7 = no disk
FPGA_FDS_NSIDES = $95   ; sides loaded (1-4), for the side swap

SECBUF      = $0400     ; 512-byte sector buffer
BUF2        = $0600     ; second 512-byte buffer (auto-read probe)
