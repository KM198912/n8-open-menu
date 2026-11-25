; SD card over the CPLD's SPI port (SPI mode), as the BIOS does it.
; Error codes (A on carry set):
;   $01 no answer to CMD0      $02 CMD8 bad echo        $03 ACMD41 timeout
;   $04 CMD58 failed           $05 CMD16 failed         $10 CMD17 rejected
;   $11 no data token          $12 CMD24 rejected       $13 data not accepted
;   $14 write busy timeout

; A = byte out -> A = byte in
spi_xfer:
    ldx #CPLD_SPI
    stx N8_IDX
    sta N8_DAT
@w: lda N8_STAT
    and #$01                ; SPI done
    beq @w
    lda N8_DAT
    rts

spi_ff:
    lda #$FF
    jmp spi_xfer

sd_select:
    ldx #CPLD_CTL
    stx N8_IDX
    lda N8_DAT
    and #<~CTL_CS
    and #<~CTL_AUTO
    sta N8_DAT
    rts

sd_deselect:
    ldx #CPLD_CTL
    stx N8_IDX
    lda N8_DAT
    ora #CTL_CS
    and #<~CTL_AUTO
    sta N8_DAT
    jmp spi_ff              ; one more clock so the card releases MISO

; A = command index, arg = argument (little endian), Y = CRC byte
; leaves CS low; returns A = R1 (also in r1), N flag set = no response
sd_cmd:
    pha
    jsr sd_select
    jsr spi_ff
    pla
    ora #$40
    jsr spi_xfer
    lda arg+3
    jsr spi_xfer
    lda arg+2
    jsr spi_xfer
    lda arg+1
    jsr spi_xfer
    lda arg
    jsr spi_xfer
    tya
    jsr spi_xfer
    lda #16
    sta count
@poll:
    jsr spi_ff
    sta r1
    cmp #$FF
    bne @got
    dec count
    bne @poll
@got:
    lda r1
    rts

clear_arg:
    lda #0
    sta arg
    sta arg+1
    sta arg+2
    sta arg+3
    rts

; ------------------------------------------------------------ init
sd_init:
    lda #0
    sta sdhc
    sta cardv2
    jsr sd_deselect
    ldx #10                 ; 80 clocks with CS high
@clk:
    txa
    pha
    jsr spi_ff
    pla
    tax
    dex
    bne @clk

    ; CMD0: go idle
    lda #8
    sta tmp
@cmd0:
    jsr clear_arg
    lda #0
    ldy #$95
    jsr sd_cmd
    cmp #$01
    beq @cmd0_ok
    jsr sd_deselect
    dec tmp
    bne @cmd0
    lda #$01
    sec
    rts
@cmd0_ok:
    jsr sd_deselect

    ; CMD8: interface condition (v2 cards echo $1AA)
    jsr clear_arg
    lda #$AA
    sta arg
    lda #$01
    sta arg+1
    lda #8
    ldy #$87
    jsr sd_cmd
    and #$04                ; illegal command -> v1 card
    bne @v1
    jsr spi_ff
    jsr spi_ff
    jsr spi_ff
    jsr spi_ff
    cmp #$AA
    beq @v2
    jsr sd_deselect
    lda #$02
    sec
    rts
@v2:
    lda #1
    sta cardv2
@v1:
    jsr sd_deselect

    ; ACMD41 until ready
    lda #0
    sta tmp
    sta tmp+1
@acmd41:
    jsr clear_arg
    lda #55
    ldy #$01
    jsr sd_cmd
    jsr sd_deselect
    jsr clear_arg
    lda cardv2
    beq @nohcs
    lda #$40                ; HCS: we support SDHC
    sta arg+3
@nohcs:
    lda #41
    ldy #$01
    jsr sd_cmd
    pha
    jsr sd_deselect
    pla
    beq @ready
    inc tmp
    bne @acmd41
    inc tmp+1
    lda tmp+1
    cmp #$10                ; 4096 tries
    bne @acmd41
    lda #$03
    sec
    rts
@ready:

    ; CMD58: read OCR, CCS bit = block addressing
    lda cardv2
    beq @sdsc
    jsr clear_arg
    lda #58
    ldy #$01
    jsr sd_cmd
    beq @ocr
    jsr sd_deselect
    lda #$04
    sec
    rts
@ocr:
    jsr spi_ff
    and #$40
    beq @ocr_rest
    lda #1
    sta sdhc
@ocr_rest:
    jsr spi_ff
    jsr spi_ff
    jsr spi_ff
    jsr sd_deselect
    lda sdhc
    bne @done
@sdsc:
    ; byte-addressed card: block length 512
    jsr clear_arg
    lda #$02
    sta arg+1
    lda #16
    ldy #$01
    jsr sd_cmd
    pha
    jsr sd_deselect
    pla
    beq @done
    lda #$05
    sec
    rts
@done:
    clc
    rts

; arg = card address of sector `lba` (SDHC: the LBA, SDSC: LBA * 512)
sd_lba_to_arg:
    lda sdhc
    beq @bytes
    MOV32 arg, lba
    rts
@bytes:
    lda #0
    sta arg
    lda lba
    asl
    sta arg+1
    lda lba+1
    rol
    sta arg+2
    lda lba+2
    rol
    sta arg+3
    rts

; CMD17 for `lba` + wait for the data token; leaves CS low.
; Carry set on error (A = code).
sd_cmd17:
    jsr sd_lba_to_arg
    lda #17
    ldy #$01
    jsr sd_cmd
    beq @token
    jsr sd_deselect
    lda #$10
    sec
    rts
@token:
    lda #0
    sta count
    sta count+1
@wt:
    jsr spi_ff
    cmp #$FE
    beq @data
    inc count
    bne @wt
    inc count+1
    bne @wt
    jsr sd_deselect
    lda #$11
    sec
    rts
@data:
    clc
    rts

; ------------------------------------------------------------ read
; read sector `lba` into SECBUF, using auto-read.
; Hardware (measured): in auto-read mode a read of $4401 returns the byte of
; the PREVIOUS transfer and clocks the next one. So the first read after
; switching it on returns the token again and clocks data byte 0.
sd_read:
    lda #0                  ; SECBUF changes: drop the FAT sector cache (fatw.s)
    sta fc_ok
    jsr sd_cmd17
    bcc @data
    rts
@data:
    ldx #CPLD_CTL
    stx N8_IDX
    lda N8_DAT
    ora #CTL_AUTO
    sta N8_DAT
    ldx #CPLD_SPI
    stx N8_IDX
    lda N8_DAT              ; stale (token), clocks byte 0
    ldy #0
@d1:
    lda N8_DAT
    sta SECBUF,y
    iny
    bne @d1
@d2:
    lda N8_DAT
    sta SECBUF+256,y
    iny
    bne @d2
    lda N8_DAT              ; CRC 1, clocks CRC 2
    jsr sd_deselect         ; clears auto-read, CS high
    clc
    rts

; ------------------------------------------------------------ write
; write SECBUF to sector `lba` (CMD24, single block). Carry set on error
; (A = $12/$13/$14). The CPLD's auto-read mode only helps reading, so every
; byte goes through spi_xfer (~25 cycles: 8 KB in about 0.1 s).
sd_write:
    jsr sd_lba_to_arg
    lda #24
    ldy #$01
    jsr sd_cmd
    beq @accepted
    jsr sd_deselect
    lda #$12
    sec
    rts
@accepted:
    jsr spi_ff              ; one byte gap, then the data token
    lda #$FE
    jsr spi_xfer
    ldy #0
@d1:
    lda SECBUF,y
    jsr spi_xfer            ; keeps Y
    iny
    bne @d1
@d2:
    lda SECBUF+256,y
    jsr spi_xfer
    iny
    bne @d2
    jsr spi_ff              ; CRC (ignored in SPI mode)
    jsr spi_ff
    ldy #8                  ; data response: first byte that is not $FF
@resp:
    jsr spi_ff
    cmp #$FF
    bne @got
    dey
    bne @resp
@got:
    and #$1F
    cmp #$05                ; xxx0 010 1 = data accepted
    beq @busy
    jsr sd_deselect
    lda #$13
    sec
    rts
@busy:                      ; the card holds MISO low while programming
    lda #0
    sta count
    sta count+1
@bw:
    jsr spi_ff
    cmp #$00
    bne @done
    inc count
    bne @bw
    inc count+1
    bne @bw
    jsr sd_deselect         ; ~1.3 s without the card finishing
    lda #$14
    sec
    rts
@done:
    jsr sd_deselect
    clc
    rts
