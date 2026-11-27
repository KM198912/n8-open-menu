; Last game / quick start: SELECT ONLY / SELECT + LOAD in the file menu store
; the file, Start loads it from any folder.
;
; Record: save SRAM page 8 (the menu's page, battery backed) at $7FC0, the
; last directory-list slot (MAX_ENTRIES is 127, so the list never reaches
; it). Page 8 survives power-on: the BIOS writes only pages 9-15 (OS.BIN,
; loader at $F080 in the BIOS dump); its one page-8 select ($C13E) is
; followed by PPU writes only.
;   +$00  "N8LG" (written last)
;   +$04  volume ID          +$08  folder cluster (0 = root)
;   +$0C  file cluster       +$10  file size
;   +$14  first 23 characters of the long name, 0-terminated
; Start checks: the same card (volume ID), then the folder is loaded and the
; entry with that cluster and size is looked up; if it is not there,
; error $4C. Error code: $4C last game not found.

LG       = $7FC0
LG_NAME  = 23
LG_ROW   = 27

lg_magic: .byte "N8LG"

; carry clear: a record for this card exists (page 8 mapped on return)
lg_valid:
    lda #SRAM_MENU
    jsr sram_page
    ldy #3
@m: lda LG,y
    cmp lg_magic,y
    bne @no
    dey
    bpl @m
    ldy #3
@v: lda LG+4,y
    cmp vol_id,y
    bne @no
    dey
    bpl @v
    clc
    rts
@no:
    sec
    rts

; record for the selected file in cur_dir
lg_store:
    lda #SRAM_MENU
    jsr sram_page
    lda #0
    sta LG                  ; invalid until the magic is complete again
    ldy #3
@f: lda vol_id,y
    sta LG+4,y
    lda cur_dir,y
    sta LG+8,y
    dey
    bpl @f
    jsr sel_rec
    ldx #7                  ; cluster and size (adjacent in the LIST record)
    ldy #REC_CLUS+7
@c: lda (rec),y
    sta LG+$0C,x
    dey
    dex
    bpl @c
    ldy #0
@n: lda (rec),y
    sta LG+$14,y
    beq @named
    iny
    cpy #LG_NAME
    bne @n
    lda #0
    sta LG+$14,y
@named:
    ldy #3
@w: lda lg_magic,y
    sta LG,y
    dey
    bpl @w
    rts

; row LG_ROW: "START: <name>" if a record exists, else blank (PPU writes:
; rendering off or in vblank)
lg_draw:
    lda #LG_ROW
    ldx #1
    jsr gotoxy
    jsr lg_valid
    bcs @blank
    PRINT "START: "
    ldy #0
@l: lda LG+$14,y
    beq @pad
    sta PPUDATA
    iny
    cpy #LG_NAME
    bne @l
@pad:
    cpy #LG_NAME
    bcs @done
    lda #' '
    sta PPUDATA
    iny
    bne @pad
@done:
    rts
@blank:
    ldx #30
    lda #' '
@b: sta PPUDATA
    dex
    bne @b
    rts

; Start: open the stored game's folder (the current one goes on the folder
; stack, so B leads back), put the cursor on the game and start it
lg_start:
    jsr lg_valid
    bcc @have
    rts
@have:
    ldy #3
@same:
    lda LG+8,y
    cmp cur_dir,y
    bne @push
    dey
    bpl @same
    bmi @open
@push:
    lda depth
    cmp #16
    bcs @nopush
    asl
    asl
    tax
    lda cur_dir
    sta dirstack,x
    lda cur_dir+1
    sta dirstack+1,x
    lda cur_dir+2
    sta dirstack+2,x
    lda cur_dir+3
    sta dirstack+3,x
    inc depth
@nopush:
    ldy #3
@cd:
    lda LG+8,y
    sta cur_dir,y
    dey
    bpl @cd
@open:
    jsr open_dir
    lda err
    bne @show               ; folder unreadable: its error
    lda #0
    sta tmp+1               ; list position
@find:
    lda tmp+1
    cmp dcount
    bcs @missing
    jsr rec_of
    jsr lg_valid            ; page 8 (rec_of keeps it)
    ldx #7
    ldy #REC_CLUS+7
@cmp:
    lda (rec),y
    cmp LG+$0C,x
    bne @nxt
    dey
    dex
    bpl @cmp
    lda tmp+1               ; found
    sta sel
    jsr fix_top
    jsr redraw
    jmp start_file
@nxt:
    inc tmp+1
    bne @find
@missing:
    lda #$4C
    sta err
@show:
    jmp redraw
