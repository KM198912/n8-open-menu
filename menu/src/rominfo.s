; ROM info screen (Select on a file): iNES header details and whether our
; MAPROUT.BIN has a core for the mapper.

INFO_COL = 2

; show the info screen for LIST record `sel`; returns when B or Select is
; pressed (the caller redraws the menu)
rom_info:
    jsr vwait
    lda #0
    sta PPUMASK
    jsr clear_screen
    lda #1
    ldx #INFO_COL
    jsr gotoxy
    PRINT "ROM INFO"

    jsr read_header         ; also sets rec for `sel`
    bcc @hdr
    sta tmp+3               ; error code (PRINT uses A/X)
    jsr info_name
    lda #6
    ldx #INFO_COL
    jsr gotoxy
    lda tmp+3
    cmp #$40
    bne @ioerr
    PRINT "NOT AN INES FILE"
    jmp @wait
@ioerr:
    PRINT "READ ERROR "
    lda tmp+3
    jsr puthex
    jmp @wait

@hdr:
    jsr info_name

    ; mapper number and name
    lda #6
    ldx #INFO_COL
    jsr gotoxy
    PRINT "MAPPER   "
    lda mapper
    ldx #0
    jsr putdec
    lda #' '
    sta PPUDATA
    sta PPUDATA
    jsr mapper_name

    ; PRG size: units * 16 KB
    lda #7
    ldx #INFO_COL
    jsr gotoxy
    PRINT "PRG     "
    lda hdr+4
    ldx #0
    stx tmp+1
    ldy #4
@p16:
    asl
    rol tmp+1
    dey
    bne @p16
    ldx tmp+1
    jsr putdec
    PRINT " KB"

    ; CHR size: units * 8 KB, 0 = CHR RAM
    lda #8
    ldx #INFO_COL
    jsr gotoxy
    PRINT "CHR     "
    lda hdr+5
    ldx #0
    stx tmp+1
    ldy #3
@c8:
    asl
    rol tmp+1
    dey
    bne @c8
    ldx tmp+1
    jsr putdec
    PRINT " KB"
    lda hdr+5
    bne @mirror
    PRINT " (RAM)"

@mirror:
    lda #9
    ldx #INFO_COL
    jsr gotoxy
    PRINT "MIRROR   "
    lda hdr+6
    and #$08
    beq @hv
    PRINT "FOUR-SCREEN"
    jmp @battery
@hv:
    lda hdr+6
    and #$01
    beq @horiz
    PRINT "VERTICAL"
    jmp @battery
@horiz:
    PRINT "HORIZONTAL"

@battery:
    lda #10
    ldx #INFO_COL
    jsr gotoxy
    PRINT "BATTERY  "
    lda hdr+6
    and #$02
    jsr yes_no

    lda #11
    ldx #INFO_COL
    jsr gotoxy
    PRINT "TRAINER  "
    lda hdr+6
    and #$04
    jsr yes_no

    lda #12
    ldx #INFO_COL
    jsr gotoxy
    PRINT "FORMAT   "
    lda hdr+7
    and #$0C
    cmp #$08
    bne @ines
    PRINT "NES 2.0"
    jmp @support
@ines:
    PRINT "INES"

@support:
    jsr info_region         ; region line (region.s)
    lda #14
    ldx #INFO_COL
    jsr gotoxy
    PRINT "SUPPORTED: "
    jsr lookup_core
    bcc @mr
    PRINT "? (NO MAPROUT.BIN)"
    jmp @wait
@mr:
    lda core_num
    cmp #$FF
    beq @no
    PRINT "YES ("
    lda core_num
    ldx #0
    jsr putdec3
    PRINT ".RBF)"
    jmp @wait
@no:
    PRINT "NO"

@wait:
    lda #STATUS_ROW
    ldx #1
    jsr gotoxy
    PRINT "B:BACK"
    jsr show
@rel:                       ; wait until all buttons are released ...
    jsr vwait
    jsr read_joy
    lda joy
    bne @rel
@prs:                       ; ... then for B or Select
    jsr vwait
    jsr read_joy
    lda joy
    and #BTN_B | BTN_SELECT
    beq @prs
    sta joy_prev            ; do not let the press reach the list
    rts

; file name of `rec`, wrapped over rows 3 and 4 (28 + 23 characters)
info_name:
    lda #3
    ldx #INFO_COL
    jsr gotoxy
    ldy #0
@a: lda (rec),y
    beq @done
    sta PPUDATA
    iny
    cpy #28
    bne @a
    lda #4
    ldx #INFO_COL
    jsr gotoxy_keep_y
@b: lda (rec),y
    beq @done
    sta PPUDATA
    iny
    cpy #NAME_MAX
    bne @b
@done:
    rts

; gotoxy without touching Y (gotoxy itself does not use Y either; kept as a
; named entry so the dependency is explicit)
gotoxy_keep_y = gotoxy

; Z flag clear -> "YES", set -> "NO"
yes_no:
    beq @no
    PRINT "YES"
    rts
@no:
    PRINT "NO"
    rts

; print the name of `mapper` if it is in the table
mapper_name:
    ldx #0
@f: lda map_ids,x
    cmp mapper
    beq @found
    inx
    cpx #MAP_COUNT
    bne @f
    rts
@found:
    txa
    asl
    tax
    lda map_names,x
    pha
    lda map_names+1,x
    tax
    pla
    jmp puts

; A/X = 16-bit value, printed right-aligned in 5 characters
putdec:
    sta tmp
    stx tmp+1
    lda #0
    sta tmp+2               ; 1 once a digit was printed
    ldy #0
@digit:
    ldx #0
@sub:
    lda tmp
    sec
    sbc dec_lo,y
    pha
    lda tmp+1
    sbc dec_hi,y
    bcc @under
    sta tmp+1
    pla
    sta tmp
    inx
    bne @sub
@under:
    pla
    txa
    bne @show
    lda tmp+2
    bne @show
    cpy #4                  ; always print the last digit
    beq @show
    lda #' '
    sta PPUDATA
    jmp @next
@show:
    txa
    ora #'0'
    sta PPUDATA
    lda #1
    sta tmp+2
@next:
    iny
    cpy #5
    bne @digit
    rts

; A = 0..255, printed as 3 digits with leading zeros (core numbers)
putdec3:
    ldx #0
@h: cmp #100
    bcc @t
    sbc #100
    inx
    bne @h
@t: pha
    txa
    ora #'0'
    sta PPUDATA
    pla
    ldx #0
@tt:
    cmp #10
    bcc @o
    sbc #10
    inx
    bne @tt
@o: pha
    txa
    ora #'0'
    sta PPUDATA
    pla
    ora #'0'
    sta PPUDATA
    rts

dec_lo: .byte <10000, <1000, <100, <10, <1
dec_hi: .byte >10000, >1000, >100, >10, >1

map_ids:
    .byte 0, 1, 2, 3, 4, 5, 7, 9, 10, 11, 13, 19, 21, 22, 23, 24, 25, 26, 34, 66, 69, 71, 73, 75, 85, 206
MAP_COUNT = * - map_ids
map_names:
    .word mn0, mn1, mn2, mn3, mn4, mn5, mn7, mn9, mn10, mn11, mn13, mn19, mn21, mn22
    .word mn23, mn24, mn25, mn26, mn34, mn66, mn69, mn71, mn73, mn75, mn85, mn206
mn0:   .byte "NROM", 0
mn1:   .byte "MMC1", 0
mn2:   .byte "UXROM", 0
mn3:   .byte "CNROM", 0
mn4:   .byte "MMC3", 0
mn5:   .byte "MMC5", 0
mn7:   .byte "AXROM", 0
mn9:   .byte "MMC2", 0
mn10:  .byte "MMC4", 0
mn11:  .byte "COLOR DREAMS", 0
mn13:  .byte "CPROM", 0
mn19:  .byte "NAMCO 163", 0
mn21:  .byte "VRC4", 0
mn22:  .byte "VRC2", 0
mn23:  .byte "VRC2/4", 0
mn24:  .byte "VRC6", 0
mn25:  .byte "VRC4", 0
mn26:  .byte "VRC6", 0
mn34:  .byte "BNROM/NINA", 0
mn66:  .byte "GXROM", 0
mn69:  .byte "FME-7", 0
mn71:  .byte "CAMERICA", 0
mn73:  .byte "VRC3", 0
mn75:  .byte "VRC1", 0
mn85:  .byte "VRC7", 0
mn206: .byte "NAMCO 108", 0
