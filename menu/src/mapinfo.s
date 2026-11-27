; "SUPPORTED MAPPERS" screen (Select in the list): what the card's
; /EDFC/MAPROUT.BIN routes to a core - the mapper numbers with an entry
; (7 per line, rows MI_ROW0.., at most MI_ROWS rows), then the FDS line
; (entry $FE). B or Select goes back. Without MAPROUT.BIN: the list shows
; the error (read_maprout's code, e.g. $44).

MI_COL  = 2
MI_ROW0 = 3
MI_ROWS = 22                ; rows 3-24 (154 numbers); FDS line at row 26
MI_PER  = 7

map_info:
    jsr read_maprout        ; SECBUF = MAPROUT.BIN (loader.s)
    bcc @ok
    sta err
    jsr menu_gfx
    jmp redraw
@ok:
    jsr vwait
    lda #0
    sta PPUMASK
    jsr clear_screen
    ldx #0                  ; count the entries (mappers 0-253)
    ldy #0
@cnt:
    lda SECBUF,y
    cmp #$FF
    beq :+
    inx
:   iny
    cpy #$FE
    bne @cnt
    stx mi_n
    lda #1
    ldx #MI_COL
    jsr gotoxy
    PRINT "SUPPORTED MAPPERS: "
    lda mi_n
    jsr num3
    lda #MI_ROW0
    sta tmp+3               ; row
    lda #0
    sta tmp+2               ; numbers in this row
    sta mi_i
    lda tmp+3
    ldx #MI_COL
    jsr gotoxy
@list:
    ldy mi_i
    lda SECBUF,y
    cmp #$FF
    beq @next
    lda tmp+3
    cmp #MI_ROW0 + MI_ROWS
    bcs @next               ; screen full
    lda mi_i
    jsr num3
    lda #' '
    sta PPUDATA
    inc tmp+2
    lda tmp+2
    cmp #MI_PER
    bne @next
    lda #0
    sta tmp+2
    inc tmp+3
    lda tmp+3
    ldx #MI_COL
    jsr gotoxy
@next:
    inc mi_i
    lda mi_i
    cmp #$FE
    bne @list
    lda #MI_ROW0 + MI_ROWS + 1
    ldx #MI_COL
    jsr gotoxy
    PRINT "FDS: "
    lda SECBUF+$FE
    cmp #$FF
    beq @nofds
    PRINT "YES"
    jmp @wait
@nofds:
    PRINT "NO"
@wait:
    lda #STATUS_ROW
    ldx #1
    jsr gotoxy
    PRINT "B:BACK"
    jsr show
@rel:                       ; all buttons released ...
    jsr vwait
    jsr read_joy
    lda joy
    bne @rel
@prs:                       ; ... then B or Select
    jsr vwait
    jsr read_joy
    lda joy
    and #BTN_B | BTN_SELECT
    beq @prs
    sta joy_prev            ; the press does not reach the list
    jsr menu_gfx
    jmp redraw

; A = 0..255, right-aligned in 3 characters (uses tmp, tmp+1, X)
num3:
    ldx #0
@h: cmp #100
    bcc @hd
    sbc #100
    inx
    bne @h
@hd:
    sta tmp
    txa
    beq @hs
    ora #'0'
    sta PPUDATA
    lda #1
    sta tmp+1               ; a digit was printed
    bne @t
@hs:
    lda #' '
    sta PPUDATA
    lda #0
    sta tmp+1
@t: lda tmp
    ldx #0
@tl:
    cmp #10
    bcc @td
    sbc #10
    inx
    bne @tl
@td:
    sta tmp
    txa
    bne @tp
    lda tmp+1
    bne @tz
    lda #' '
    sta PPUDATA
    jmp @u
@tz:
    lda #0
@tp:
    ora #'0'
    sta PPUDATA
@u: lda tmp
    ora #'0'
    sta PPUDATA
    rts
