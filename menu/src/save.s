; ======================================================================
; Battery saves: /EDFC/SAVE/<rom name>.sav (raw 8 KB, the format emulators
; use) <-> save SRAM page 0 (a game's $6000-$7FFF in our cores). The save
; SRAM keeps its contents through power-off and the BIOS boot (confirmed).
;
; Game start (save_prepare): load the .sav into page 0, or create it (8 KB
; of $00) and clear page 0; then write the "save pending" record. The game
; plays in page 0; reset restarts it, power-off keeps page 0.
; Menu start (save_boot): page 0 -> .sav, then the record is cleared. A
; power loss in between leaves the record: the next start writes it again.
;
; Record: 36 bytes at save SRAM $0FFDC-$0FFFF (page 7, REC). Of the 256 KB
; chip only 128 KB are reachable; pages 0-7 are game PRG RAM (MMC5: up to
; 64 KB, FDS: side A, which leaves exactly these 36 bytes free), page 8 is
; the menu's file list, and pages 9-15 are rewritten from OS.BIN by the
; BIOS at every power-on ($F080; the record used to be in page 9 and was
; lost at power-off). An MMC5 game using all 64 KB would overwrite it.
;   $00 "N8SV" (written last)  $04 volume ID  $08 SAVE directory cluster
;   $0C .sav first cluster     $10 .sav 8.3 name (11 bytes)
;
; Save names: the ROM's name as the list shows it, ".nes" replaced by
; ".sav", at most 47 characters before ".sav" (the list and the directory
; search keep 51 characters), '?' (non-ASCII in the list) -> '_'.
;
; FDS games keep their disk sides in the save SRAM and have their own
; record ("N8FD", see fds.s); save_pending sees both, save_flush passes an
; FDS record on to fds_flush.
;
; Error codes: $48 a previous save is still pending (not written back)
;              $4A the card is not the one the save came from (volume ID)
;              $4B the .sav is gone or changed (name, cluster, size)
; ======================================================================

SAVE_SIZE = 8192
SRAM_GAME = 0               ; save SRAM page of the game's PRG RAM
SRAM_REC  = 7               ; save SRAM page of the record ...
REC       = $7FDC           ; ... and its address in the $6000 window
SRAM_MENU = 8               ; menu data (LIST)

; A = save SRAM page shown at $6000 (keeps Y; changes X)
sram_page:
    ldx #FPGA_SRAM_PAGE
    stx N8_IDX
    sta N8_DAT
    rts

; carry set if a save record is pending (battery "N8SV" or FDS "N8FD")
save_pending:
    lda #SRAM_REC
    jsr sram_page
    ldy #3
@l: lda REC,y
    cmp sv_magic,y
    bne @fds
    dey
    bpl @l
    bmi @yes
@fds:
    ldy #3
@l2:
    lda REC,y
    cmp fds_magic,y
    bne @no
    dey
    bpl @l2
@yes:
    lda #SRAM_MENU
    jsr sram_page
    sec
    rts
@no:
    lda #SRAM_MENU
    jsr sram_page
    clc
    rts

sv_magic:  .byte "N8SV"
name_save: .byte "SAVE       "
sv_ext:    .byte ".sav", 0

; ------------------------------------------------------------ game start
; save_prepare: after the core lookup (dir_edfc valid, rec = the ROM's LIST
; record, page 8 mapped). Battery games: page 0 = their .sav (created if
; missing), record written. Carry set: A = error - the game must not start
; (its progress would not be saved, or it would overwrite a pending save).
save_prepare:
    jsr save_pending
    bcc @free
    lda #$48
    rts
@free:
    lda hdr+6
    and #$02
    bne @battery
    clc
    rts
@battery:
    jsr save_name
    ldx #10                 ; /EDFC/SAVE, created if missing
@d: lda name_save,x
    sta fname,x
    dex
    bpl @d
    MOV32 it_clus, dir_edfc
    jsr find_name
    bcc @have_dir
    tax
    beq @mkdir
    txa
    sec
    rts
@mkdir:
    MOV32 dw_dir, dir_edfc
    jsr dir_create
    bcc @made
    rts
@made:
    MOV32 f_clus, w_clus
@have_dir:
    MOV32 sv_dir, f_clus
    MOV32 dw_dir, sv_dir
    lda #<sv_name
    sta nm
    lda #>sv_name
    sta nm+1
    jsr find_long
    bcc @found
    tax
    beq @create
    txa
    sec
    rts
@create:
    MOV32 w_seed, rom_clus  ; 8.3 name: hex of the ROM's first cluster
    jsr sfn_unique
    bcs @r
    lda #<SAVE_SIZE
    sta w_size
    lda #>SAVE_SIZE
    sta w_size+1
    lda #0
    sta w_size+2
    sta w_size+3
    jsr file_create
    bcs @r
    MOV32 sv_clus, w_clus
    jsr sram0_clear
    jmp save_record
@found:
    MOV32 sv_clus, f_clus
    jsr sv_load
    bcs @r
    jsr sv_grow
    bcs @r
    jmp save_record
@r: rts

; sv_name = save name of LIST record rec (see the header)
save_name:
    ldy #0
@len:
    lda (rec),y
    beq @lend
    iny
    cpy #NAME_MAX
    bne @len
@lend:
    sty sv_len
    cpy #4                  ; ends with ".nes" (any case)?
    bcc @cap
    tya
    sec
    sbc #4
    tay
    lda (rec),y
    cmp #'.'
    bne @cap
    iny
    lda (rec),y
    jsr upcase
    cmp #'N'
    bne @cap
    iny
    lda (rec),y
    jsr upcase
    cmp #'E'
    bne @cap
    iny
    lda (rec),y
    jsr upcase
    cmp #'S'
    bne @cap
    lda sv_len
    sec
    sbc #4
    sta sv_len
@cap:
    lda sv_len
    cmp #48
    bcc @copy
    lda #47
    sta sv_len
@copy:
    ldy #0
@c: cpy sv_len
    beq @ext
    lda (rec),y
    cmp #'?'
    bne @s
    lda #'_'
@s: sta sv_name,y
    iny
    bne @c
@ext:
    ldx #0
@x: lda sv_ext,x
    sta sv_name,y
    beq @done
    iny
    inx
    bne @x
@done:
    rts

; page 0 = $00
sram0_clear:
    lda #SRAM_GAME
    jsr sram_page
    lda #0
    sta dst
    lda #$60
    sta dst+1
    ldy #0
    lda #0
@l: sta (dst),y
    iny
    bne @l
    inc dst+1
    ldx dst+1
    cpx #$80
    bne @l
    lda #SRAM_MENU
    jmp sram_page

; sv_load: page 0 = the first min(f_size, 8 KB) bytes of the file at f_clus
; (whole sectors), the rest $00. Carry set: A = error.
sv_load:
    jsr sram0_clear
    lda f_clus
    ora f_clus+1
    ora f_clus+2
    ora f_clus+3
    beq @done               ; empty file: no clusters
    lda f_size+3            ; sectors = min(16, (size + 511) / 512)
    ora f_size+2
    bne @full
    lda f_size+1
    cmp #>SAVE_SIZE
    bcs @full
    lda f_size
    clc
    adc #$FF
    lda f_size+1
    adc #$01
    lsr
    sta sv_n
    jmp @go
@full:
    lda #16
    sta sv_n
@go:
    lda sv_n
    beq @done
    jsr stream_open
    bcs @r
    lda #0
    sta sv_k
@sec:
    lda sv_k                ; dst = $6000 + k * 512
    asl
    clc
    adc #$60
    sta dst+1
    lda #0
    sta dst
    lda #SRAM_GAME
    jsr sram_page
    ldy #0
@c1:
    lda SECBUF,y
    sta (dst),y
    iny
    bne @c1
    inc dst+1
@c2:
    lda SECBUF+256,y
    sta (dst),y
    iny
    bne @c2
    lda #SRAM_MENU
    jsr sram_page
    inc sv_k
    lda sv_k
    cmp sv_n
    beq @done
    jsr stream_next_sector
    bcs @r
    jmp @sec
@done:
    clc
@r: rts

; sv_grow: a .sav shorter than 8 KB (some emulators write less) gets
; zeroed clusters appended and its entry set to 8 KB, so the write-back
; never runs out of clusters. Carry set: A = error.
sv_grow:
    lda f_size+3
    ora f_size+2
    bne @ok
    lda f_size+1
    cmp #>SAVE_SIZE
    bcc @short
@ok:
    clc
    rts
@short:
    ; need = clusters for 8 KB = (16 + spc - 1) >> spc_shift
    lda #16
    clc
    adc spc
    sec
    sbc #1
    ldx spc_shift
    beq @n1
@s1:
    lsr
    dex
    bne @s1
@n1:
    sta sv_n
    ; have = clusters of the file now (from its size; 1 if it has a
    ; cluster but size 0, 0 without a cluster)
    lda #0
    sta sv_have
    lda f_clus
    ora f_clus+1
    ora f_clus+2
    ora f_clus+3
    beq @extra
    lda f_size              ; sectors = (size + 511) / 512 (size < 8 KB)
    clc
    adc #$FF
    lda f_size+1
    adc #$01
    lsr
    clc
    adc spc
    sec
    sbc #1
    ldx spc_shift
    beq @n2
@s2:
    lsr
    dex
    bne @s2
@n2:
    cmp #0                  ; (the flags are still from ldx/dex here)
    bne @h
    lda #1
@h: sta sv_have
@extra:
    lda sv_n
    sec
    sbc sv_have
    bne @need
    jmp entry_fix           ; enough clusters, only the size changes
@need:
    sta al_n
    jsr fat_alloc
    bcc @alloc
    rts
@alloc:
    MOV32 clus, al_first
    jsr zero_chain
    bcs @r
    lda sv_have
    bne @append
    MOV32 sv_clus, al_first ; no clusters before: the new chain is the file
    jmp @fix
@append:
    MOV32 clus, f_clus      ; find the last cluster of the old chain
@walk:
    MOV32 sv_last, clus
    jsr next_cluster
    bcc @walk
    tax
    beq @last
    txa
    sec
    rts
@last:
    MOV32 clus, sv_last
    MOV32 fv, al_first
    jsr fat_put
    bcs @r
@fix:
    jmp entry_fix
@r: rts

; save_record: the pending record (magic last, so a half-written record
; is never taken for valid)
save_record:
    lda #SRAM_REC
    jsr sram_page
    ldy #3
@f: lda vol_id,y
    sta REC+4,y
    lda sv_dir,y
    sta REC+8,y
    lda sv_clus,y
    sta REC+$0C,y
    dey
    bpl @f
    ldy #10
@n: lda fname,y
    sta REC+$10,y
    dey
    bpl @n
    ldy #3
@m: lda sv_magic,y
    sta REC,y
    dey
    bpl @m
    lda #SRAM_MENU
    jsr sram_page
    clc
    rts

; ------------------------------------------------------------ menu start
; save_boot: after the mount. A pending save is written to its .sav
; ("SAVING..." on the status row). If that fails, the player chooses:
; A = retry (e.g. after putting the right card back), Select = discard.
; Never returns with a record pending unless the player keeps retrying.
save_boot:
    jsr save_pending
    bcs @retry
    rts
@retry:
    lda #STATUS_ROW
    ldx #1
    jsr gotoxy_off
    PRINT "SAVING...                     "
    jsr show
    jsr save_flush
    bcs @failed
    rts
@failed:
    pha
    lda #STATUS_ROW         ; "SAVING..." is over
    ldx #1
    jsr gotoxy_off
    PRINT "                              "
    lda #LIST_ROW
    ldx #2
    jsr gotoxy
    PRINT "LAST SAVE NOT WRITTEN TO SD"
    lda #LIST_ROW+1
    ldx #2
    jsr gotoxy
    PRINT "ERROR "
    pla
    jsr puthex
    lda #LIST_ROW+3
    ldx #2
    jsr gotoxy
    PRINT "A:      RETRY"
    lda #LIST_ROW+4
    ldx #2
    jsr gotoxy
    PRINT "SELECT: DISCARD THE SAVE"
    jsr show
@rel:                       ; all buttons released ...
    jsr vwait
    jsr read_joy
    lda joy
    bne @rel
@prs:                       ; ... then A or Select
    jsr vwait
    jsr read_joy
    lda joy
    and #BTN_A | BTN_SELECT
    beq @prs
    sta joy_prev            ; do not let the press reach the list
    and #BTN_A
    beq @discard
    jmp @retry
@discard:
    jmp save_discard

; save_discard: clear the record (magic only)
save_discard:
    lda #SRAM_REC
    jsr sram_page
    lda #0
    sta REC
    sta REC+1
    sta REC+2
    sta REC+3
    lda #SRAM_MENU
    jsr sram_page
    clc
    rts

; save_flush: page 0 -> the .sav of the pending record, then the record is
; cleared. Written only if the card's volume ID matches and the recorded
; 8.3 entry still points at the recorded cluster with at least 8 KB.
; Carry set: A = error ($4A, $4B, SD/FAT errors); the record stays.
save_flush:
    lda #SRAM_REC
    jsr sram_page
    lda REC+2               ; "N8FD": an FDS game's disk sides
    cmp #'F'
    bne @battery
    lda #SRAM_MENU
    jsr sram_page
    jmp fds_flush
@battery:
    ldy #3
@f: lda REC+4,y
    sta sv_last,y           ; (recorded volume ID)
    lda REC+8,y
    sta sv_dir,y
    lda REC+$0C,y
    sta sv_clus,y
    dey
    bpl @f
    ldy #10
@n: lda REC+$10,y
    sta fname,y
    dey
    bpl @n
    lda #SRAM_MENU
    jsr sram_page
    ldx #3                  ; same card?
@v: lda sv_last,x
    cmp vol_id,x
    bne @other
    dex
    bpl @v
    MOV32 it_clus, sv_dir   ; same file?
    jsr find_name
    bcc @entry
    tax
    beq @changed
    txa
    sec
    rts
@other:
    lda #$4A
    sec
    rts
@entry:
    lda f_attr
    and #$18
    bne @changed
    ldx #3
@c: lda f_clus,x
    cmp sv_clus,x
    bne @changed
    dex
    bpl @c
    lda f_size+3
    ora f_size+2
    bne @size_ok
    lda f_size+1
    cmp #>SAVE_SIZE
    bcs @size_ok
@changed:
    lda #$4B
    sec
    rts
@size_ok:
    MOV32 de_clus, sv_clus  ; 16 sectors along the chain
    lda #0
    sta sv_k
@cl:
    MOV32 clus, de_clus
    jsr clus_to_lba
    MOV32 de_lba, lba
    lda spc
    sta sv_n
@sec:
    lda sv_k                ; SECBUF = page 0 sector k
    asl
    clc
    adc #$60
    sta src+1
    lda #0
    sta src
    sta fc_ok               ; (SECBUF no longer holds a FAT sector)
    lda #SRAM_GAME
    jsr sram_page
    ldy #0
@c1:
    lda (src),y
    sta SECBUF,y
    iny
    bne @c1
    inc src+1
@c2:
    lda (src),y
    sta SECBUF+256,y
    iny
    bne @c2
    lda #SRAM_MENU
    jsr sram_page
    MOV32 lba, de_lba
    jsr sd_write
    bcs @r
    inc sv_k
    lda sv_k
    cmp #16
    beq @done
    INC32 de_lba
    dec sv_n
    bne @sec
    MOV32 clus, de_clus
    jsr next_cluster
    bcc @next
    tax                     ; chain shorter than 8 KB: changed behind our back
    bne @err
    lda #$4B
    sec
    rts
@err:
    txa
    sec
    rts
@next:
    MOV32 de_clus, clus
    jmp @cl
@done:
    jmp save_discard
@r: rts
