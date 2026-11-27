; ======================================================================
; RAM part of the loader: runs from CPU RAM ($0300-$07FF) while the FPGA
; is reconfigured. During that time nothing above $4800 is reachable (the
; FPGA drives those chip selects), so this code only touches CPU RAM, the
; PPU and the CPLD.
;
; Follows the BIOS core load ($FF34): CPLD reg $09 = 0 during the load and
; restored afterwards, nCONFIG pulse, auto-read, $4402 = $05, every SD data
; byte written to $4403. No "configured" status bit is known.
;
; Our cores answer a write/read-back test at $5000 (signature window in
; PRG RAM); the clone's boot core leaves $5000 unmapped. The loader checks
; that the window is absent before and present after loading. If the first
; attempt does not bring our core up, it retries once with $4402 kept at $05
; across the gaps between the file's runs (the BIOS sets $03 only at the end).
;
; The screen stays black (rendering off, menu backdrop $0F) during the whole
; load: no progress colours, so nothing flashes. Only a failure changes the
; screen, once, to a steady colour (palette entry $3F00), and stops:
;   brown    $17  our core did not come up after both attempts
;   pink     $24  CMD18 rejected (R1 != 0)
;   red      $16  no data token
;   purple   $13  SPI never reported "done"
; ======================================================================
.segment "RAMCODE"

rc_entry:
    sei
    ; like the BIOS: reg $09 = 0 during the load
    lda #CPLD_MEM
    sta N8_IDX
    lda N8_DAT
    sta rc_mem
    lda #0
    sta N8_DAT
    ; (no check before loading: with our own 255.RBF the menu core answers
    ; at $5000 too; nCONFIG wipes it, so the check after loading stays valid)
    lda #0
    sta rc_att
    sta rc_order
    jsr rc_load
    jsr rc_probe
    bcs @loaded
    ; second attempt in the BIOS order
    inc rc_att
    inc rc_order
    jsr rc_load
    jsr rc_probe
    bcs @loaded
    lda #$17
    jmp rc_fail
@loaded:
    lda #CPLD_MEM           ; restore reg $09 (as the BIOS does): bit 4 set
    sta N8_IDX              ; before every game start, bit 3 (save states)
    lda rc_mem              ; clear, as Krikzz's menu does with save states
    and #<~$08              ; off ($AF32-$AF57) -> $11 with the BIOS value $01;
    ora cpld_or             ; FDS: bits 2 + 4 ($14), as the clone menu does
    sta N8_DAT
    ; the new core starts in menu mode: set the game registers
    lda #FPGA_PRG_SIZE
    sta N8_IDX
    lda cfg_prg
    sta N8_DAT
    lda #FPGA_CHR_SIZE
    sta N8_IDX
    lda cfg_chr
    sta N8_DAT
    lda #FPGA_MAP_CFG
    sta N8_IDX
    lda cfg_map
    sta N8_DAT
    lda #FPGA_CART_CFG      ; short reset = back to the menu
    sta N8_IDX
    lda #0
    sta N8_DAT
    ; registers Krikzz's menu (v1.26) writes right before every game start;
    ; our core ignores them, the CPLD may not (reset -> menu under test):
    ; $8B/$8C save-state keys ($FF = off), $8F = 0, $90 = $1A
    lda #$8B
    sta N8_IDX
    lda #$FF
    sta N8_DAT
    lda #$8C
    sta N8_IDX
    lda #$FF
    sta N8_DAT
    lda #$8F
    sta N8_IDX
    lda #$00
    sta N8_DAT
    lda #$90
    sta N8_IDX
    lda #$1A
    sta N8_DAT
    lda #FPGA_AUD_GAIN      ; expansion audio level (VRC6 ...), 128 = 1.0
    sta N8_IDX
    lda #AUD_GAIN_DEFAULT
    sta N8_DAT
    ; FDS: the block tables staged at PRG $0A000 (fds.s) go to the core,
    ; which only takes them in menu mode, i.e. now: 2 KB = 4 sides x 256
    ; entries, the core's table address advances by itself. Side A in.
    lda is_fds
    beq @nofds
    lda #FPGA_PRG_PAGE
    sta N8_IDX
    lda #FDS_TBL_PAGE
    sta N8_DAT
    lda #FPGA_FDS_TLO
    sta N8_IDX
    lda #0
    sta N8_DAT
    lda #FPGA_FDS_THI
    sta N8_IDX
    lda #0
    sta N8_DAT
    lda #FPGA_FDS_TDAT
    sta N8_IDX
    lda #$00
    sta src
    lda #$48
    sta src+1
    ldy #0
@tbl:
    lda (src),y
    sta N8_DAT
    iny
    bne @tbl
    inc src+1
    lda src+1
    cmp #$50
    bne @tbl
    lda #FPGA_PRG_PAGE      ; side IDs (automatic swap): 64 bytes at $0A800
    sta N8_IDX
    lda #FDS_ID_PAGE
    sta N8_DAT
    lda #FPGA_FDS_IDA
    sta N8_IDX
    lda #0
    sta N8_DAT
    lda #FPGA_FDS_IDD
    sta N8_IDX
    ldy #0
@ids:
    lda $4800,y
    sta N8_DAT
    iny
    cpy #64
    bne @ids
    lda #FPGA_FDS_NSIDES    ; for the side swap (Select + Down)
    sta N8_IDX
    lda fds_sides
    sta N8_DAT
    lda #FPGA_FDS_SIDE
    sta N8_IDX
    lda #$00                ; side 0, disk inserted
    sta N8_DAT
@nofds:
    ; clean CPU RAM for the game, as after power-on: zero page, the stack
    ; page, pages 2 and 7 = $00 (pages 3-6 hold this code). Menu leftovers
    ; changed games that read RAM before writing it (Castlevania: page 7 and
    ; $F0-$FF are not cleared by its reset code -> status bar split lost).
    ; Nothing below uses RAM or the stack; the mapper index stays in Y.
    ldy mapper
    lda #0
    tax
@clr:
    sta $00,x
    sta $0100,x
    sta $0200,x
    sta $0700,x
    inx
    bne @clr
    lda #FPGA_MAPPER
    sta N8_IDX
    bit PPUSTATUS
@vb:
    bit PPUSTATUS
    bpl @vb
    sty N8_DAT              ; game mode from here: $8000 = game PRG
    ldx #$FD
    txs
    lda #0
    tax
    tay
    jmp ($FFFC)

; ---------------------------------------------------------------- load
; one load attempt. rc_order 0: $4402 = $05 only while streaming each run
; (back to $03 for the SD commands in between); rc_order 1: $4402 = $05 for
; the whole load, $03 only at the end (as the BIOS, which streams one run)
rc_load:
    jsr rc_ncfg
    lda rc_order
    beq @per_run
    lda #$05
    sta N8_MODE
@per_run:
    lda #0
    sta rc_off
    lda ext_n
    sta rc_cnt
@ext:
    ; CMD18: read multiple blocks from the run's start address
    jsr rc_select
    lda #$FF
    jsr rc_spi
    lda #$40+18
    jsr rc_spi
    ldy rc_off
    lda ext_tab+3,y
    jsr rc_spi
    lda ext_tab+2,y
    jsr rc_spi
    lda ext_tab+1,y
    jsr rc_spi
    lda ext_tab,y
    jsr rc_spi
    lda #$01
    jsr rc_spi
    lda #16
    sta rc_t
@r1:
    lda #$FF
    jsr rc_spi
    cmp #$FF
    bne @got
    dec rc_t
    bne @r1
@got:
    cmp #0
    beq @r1ok
    lda #$24
    jmp rc_fail
@r1ok:
    ldy rc_off
    lda ext_tab+4,y
    sta rc_n
    lda ext_tab+5,y
    sta rc_n+1
    ; auto-read on, then every SD byte goes to the FPGA configuration
    ldx #CPLD_CTL
    stx N8_IDX
    lda N8_DAT
    ora #CTL_AUTO
    sta N8_DAT
    ldx #CPLD_SPI
    stx N8_IDX
    lda #$05
    sta N8_MODE
@sec:
    lda #0
    sta rc_t
    sta rc_t+1
@tw:
    lda N8_DAT              ; each read clocks a byte, returns the previous one
    cmp #$FE
    beq @tok
    inc rc_t
    bne @tw
    inc rc_t+1
    bne @tw
    lda #$16
    jmp rc_fail
@tok:
    ldx #0
@b1:
    lda N8_DAT
    sta N8_STAT             ; config byte
    inx
    bne @b1
@b2:
    lda N8_DAT
    sta N8_STAT
    inx
    bne @b2
    lda N8_DAT              ; returns CRC 1, clocks CRC 2
    lda N8_DAT              ; returns CRC 2 - must not reach the token search:
                            ; a CRC byte of $FE looked like the next data token
                            ; and shifted the core by a few bytes (the BIOS has
                            ; the same dummy read at $FF65)
    lda rc_n
    bne @dl
    dec rc_n+1
@dl:
    dec rc_n
    lda rc_n
    ora rc_n+1
    bne @sec
    ; end of the run: auto-read off ($4402 back to $03 only in mode 0), CMD12
    lda rc_order
    bne @keep5
    lda #$03
    sta N8_MODE
@keep5:
    ldx #CPLD_CTL
    stx N8_IDX
    lda N8_DAT
    and #<~CTL_AUTO
    sta N8_DAT
    lda #$40+12
    jsr rc_spi
    lda #0
    jsr rc_spi
    lda #0
    jsr rc_spi
    lda #0
    jsr rc_spi
    lda #0
    jsr rc_spi
    lda #$01
    jsr rc_spi
    lda #$FF                ; stuff byte
    jsr rc_spi
    lda #16
    sta rc_t
@r12:
    lda #$FF
    jsr rc_spi
    cmp #$FF
    bne @busy0
    dec rc_t
    bne @r12
@busy0:
    lda #0
    sta rc_t
    sta rc_t+1
@busy:
    lda #$FF
    jsr rc_spi
    bne @notbusy
    inc rc_t
    bne @busy
    inc rc_t+1
    bne @busy
@notbusy:
    jsr rc_deselect
    lda rc_off
    clc
    adc #6
    sta rc_off
    dec rc_cnt
    beq @all
    jmp @ext
@all:
    lda #$03                ; end of the load: transfer mode back to idle
    sta N8_MODE
    jsr rc_delay            ; give the core time to start (as the BIOS)
    jsr rc_delay
    rts

; nCONFIG pulse: the FPGA clears and waits for a bitstream
rc_ncfg:
    ldx #CPLD_NCFG
    stx N8_IDX
    lda #0
    sta N8_DAT
    jsr rc_delay
    ldx #CPLD_NCFG
    stx N8_IDX
    lda #1
    sta N8_DAT
    jsr rc_delay
    rts

; Signature test at $5000: carry set = our core answers. The two bytes are
; restored afterwards (they belong to the last 2 KB of PRG RAM).
; Diagnostic build only (ca65 -D AB_TEST): cores 200 and up are foreign
; cores (e.g. the original firmware's, renamed) without the signature
; window; they are accepted without the test.
rc_probe:
.ifdef AB_TEST
    lda core_num
    cmp #200
    bcc @probe
    sec
    rts
@probe:
.endif
    lda $5000
    sta rc_sv
    lda $5001
    sta rc_sv+1
    lda #$A5
    sta $5000
    lda #$5A
    sta $5001
    lda $5000
    cmp #$A5
    bne @no
    lda $5001
    cmp #$5A
    bne @no
    lda rc_sv
    sta $5000
    lda rc_sv+1
    sta $5001
    sec
    rts
@no:
    clc
    rts

; Diagnostics (temporary, milestone 2 bring-up), independent of the CHR
; contents, valid for hello.nes: compares game-mode PRG/CHR with the
; readings taken while loading and shows ONE colour, then waits for A
; (released, then pressed) and starts the game.
;   red    $16  PRG readback through the boot core is not "A"/"B"
;   pink   $24  game mode PRG differs from that readback
;   blue   $12  CHR readback through the boot core is not $38
;   purple $13  game mode CHR differs from that readback
;   green  $2A  everything matches (first attempt)
;   pale green $3A  everything matches (second attempt, $4402 kept at $05)
rc_diag:
    lda $8000
    sta gm
    lda $C000
    sta gm+1
    lda PPUSTATUS           ; CHR byte $0410 in game mode
    lda #$04
    sta PPUADDR
    lda #$10
    sta PPUADDR
    lda PPUDATA
    lda PPUDATA
    sta chr_game
    lda #$16
    ldx win0
    cpx #$41
    bne @show
    ldx win1
    cpx #$42
    bne @show
    lda #$24
    ldx gm
    cpx win0
    bne @show
    ldx gm+1
    cpx win1
    bne @show
    lda #$12
    ldx chr_win
    cpx #$38
    bne @show
    lda #$13
    cpx chr_game
    bne @show
    lda #$2A
    ldx rc_att
    beq @show
    lda #$3A
@show:
    jsr rc_color
@rel:                       ; wait until A is released ...
    jsr rc_joy_a
    bne @rel
@wa:                        ; ... then for a new press
    jsr rc_joy_a
    beq @wa
    rts

; A = state of the A button (bit 0 of the first read), Z flag set = released
rc_joy_a:
    lda #1
    sta $4016
    lda #0
    sta $4016
    lda $4016
    and #1
    rts

; A = failure colour: show it and stop (power-cycle to recover)
rc_fail:
    pha
    lda #$03
    sta N8_MODE
    pla
    jsr rc_color
@h: jmp @h

; A = colour -> palette $3F00, PPU address left there so it shows
rc_color:
    pha
    lda PPUSTATUS
    lda #$3F
    sta PPUADDR
    lda #$00
    sta PPUADDR
    pla
    sta PPUDATA
    lda #$3F
    sta PPUADDR
    lda #$00
    sta PPUADDR
    rts

; A = byte out -> A = byte in (plain SPI transfer), with timeout
rc_spi:
    ldx #CPLD_SPI
    stx N8_IDX
    sta N8_DAT
    ldx #0
@w: lda N8_STAT
    and #$01
    bne @ok
    dex
    bne @w
    lda #$13
    jmp rc_fail
@ok:
    lda N8_DAT
    rts

rc_select:
    ldx #CPLD_CTL
    stx N8_IDX
    lda N8_DAT
    and #<~(CTL_CS | CTL_AUTO)
    sta N8_DAT
    rts

rc_deselect:
    ldx #CPLD_CTL
    stx N8_IDX
    lda N8_DAT
    ora #CTL_CS
    and #<~CTL_AUTO
    sta N8_DAT
    lda #$FF
    jmp rc_spi

; ~40 ms (uses X and Y)
rc_delay:
    ldx #0
    ldy #$20
@l: nop
    dex
    bne @l
    dey
    bne @l
    rts

.segment "CODE"
