; n8-open: SD write test (stage 1 of battery saves), simulator only.
; Build: ca65 -D SDW_TEST -I tests -o build/sdw.o src/main.s
; Writes two patterns to sectors 100 and 101 (in the gap between the MBR and
; the partition on our test images: never on a real card), reads both back
; and prints the result on the list row, then stops.

SDW_LBA = 100

sdw_test:
    lda #SDW_LBA
    sta tmp+3                   ; current sector (low byte; 100/101)
@sector:
    jsr sdw_fill
    jsr sdw_lba
    jsr sd_write
    bcc @written
    pha
    lda #LIST_ROW
    ldx #2
    jsr gotoxy_off
    PRINT "SDW WRITE ERR "
    pla
    jmp sdw_end_hex
@written:
    ldy #0                      ; clear the buffer, then read the sector back
    tya
@clr:
    sta SECBUF,y
    sta SECBUF+256,y
    iny
    bne @clr
    jsr sdw_lba
    jsr sd_read
    bcc @read
    pha
    lda #LIST_ROW
    ldx #2
    jsr gotoxy_off
    PRINT "SDW READ ERR "
    pla
    jmp sdw_end_hex
@read:
    ldy #0
@cmp:
    jsr sdw_byte_lo
    cmp SECBUF,y
    bne @bad
    jsr sdw_byte_hi
    cmp SECBUF+256,y
    bne @bad
    iny
    bne @cmp
    inc tmp+3
    lda tmp+3
    cmp #SDW_LBA+2
    beq @all
    jmp @sector
@all:
    lda #LIST_ROW
    ldx #2
    jsr gotoxy_off
    PRINT "SDW OK"
    jmp sdw_end
@bad:
    tya
    pha
    lda #LIST_ROW
    ldx #2
    jsr gotoxy_off
    PRINT "SDW BAD AT "
    pla
    jmp sdw_end_hex

; pattern byte for offset Y in the low/high half, depends on the sector
sdw_byte_lo:
    tya
    eor #$A5
    eor tmp+3
    rts
sdw_byte_hi:
    tya
    clc
    adc #$37
    eor tmp+3
    rts

sdw_fill:
    ldy #0
@f: jsr sdw_byte_lo
    sta SECBUF,y
    jsr sdw_byte_hi
    sta SECBUF+256,y
    iny
    bne @f
    rts

sdw_lba:
    lda tmp+3
    sta lba
    lda #0
    sta lba+1
    sta lba+2
    sta lba+3
    rts

sdw_end_hex:
    jsr puthex
sdw_end:
    jsr show
@h: jmp @h
