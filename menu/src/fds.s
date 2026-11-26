; Famicom Disk System games (.fds) for the FDS core (cores/nrom/map_fds.v).
; Reference implementation of the same steps: tools/n8sim/fdsdisk.py.
;
; Memory layout the core expects:
;   PRG SRAM  $00000-$07FFF  32 KB RAM (left as it is)
;             $08000-$09FFF  BIOS: the user's own dump /EDFC/DISKSYS.ROM,
;                            patched
;             $0A000-$0A7FF  block tables, 512 bytes per side (staging: the
;                            RAM code sends them to the core once it is
;                            loaded, see ramload.s)
;             $20000, $30000, $40000   sides 1-3 (not kept)
;   save SRAM $00000-$0FFFF  side 0 (65500 bytes, .fds form) - battery
;                            backed, so what the game writes there survives
;                            power-off and goes back to the .fds file at the
;                            next menu start (fds_flush). Only one side: the
;                            chip is 256 KB, but A17 does not reach it (the
;                            board ties it; 128 KB reachable, see
;                            docs/hw-interface.md), and the rest of the lower
;                            128 KB is the menu's.
; Save record (36 bytes at save SRAM $0FFDC, REC in save.s - behind side A,
; the only bytes the BIOS does not rewrite at power-on):
;   $00 "N8FD" (written last)  $04 volume ID  $08 directory cluster
;   $0C .fds first cluster     $10 .fds size  $14 header offset (0/16)
;   $15 sides kept (1)         $16 .fds 8.3 name (11 bytes)
; Error codes: $50 /EDFC/DISKSYS.ROM missing or not 8 KB
;              $51 DISKSYS.ROM is not the BIOS the patch is for
;              $52 not an FDS image (no complete side)
;              $53 more than 4 sides
;              $4A/$4B (write-back): other card / .fds file changed, as in
;                  save.s

FDS_BIOS_PAGE = 16          ; PRG $08000 in 2 KB pages
FDS_TBL_PAGE  = 20          ; PRG $0A000
FDS_MAX_SIDES = 4
FDS_KEPT      = 1           ; sides in the save SRAM (side 0)

; fds_detect: is the file FDS? Call after read_header returned $40 (hdr =
; the first 16 bytes, f_size = file size). Carry clear: yes, fds_off (0 or
; 16), fds_sides and fds_size set. Carry set: A = $40 (not FDS), $52, $53.
fds_detect:
    lda rom_clus            ; empty file: hdr is stale
    ora rom_clus+1
    ora rom_clus+2
    ora rom_clus+3
    bne :+
    jmp @no
:
    lda hdr                 ; fwNES header: "FDS" $1A
    cmp #'F'
    bne @raw
    lda hdr+1
    cmp #'D'
    bne @raw
    lda hdr+2
    cmp #'S'
    bne @raw
    lda hdr+3
    cmp #$1A
    bne @raw
    lda #16
    bne @count
@raw:
    lda hdr                 ; no header: disk info block 1 "*NINTENDO-HVC*"
    cmp #$01
    beq :+
    jmp @no
:
    ldx #13
@hvc:
    lda hdr+1,x
    cmp fds_hvc,x
    bne @no
    dex
    bpl @hvc
    lda #0
@count:
    sta fds_off
    ldx #3
@sz:
    lda f_size,x
    sta fds_size,x
    dex
    bpl @sz
    ; sides = (size - off) / 65500
    sec
    lda f_size
    sbc fds_off
    sta fp_t
    lda f_size+1
    sbc #0
    sta fp_t+1
    lda f_size+2
    sbc #0
    sta fp_t+2
    lda f_size+3
    sbc #0
    sta fp_t+3
    lda #0
    sta fds_sides
@sub:
    lda fp_t+3              ; >= $FFDC left?
    ora fp_t+2
    bne @one
    lda fp_t+1
    cmp #$FF
    bcc @counted
    lda fp_t
    cmp #$DC
    bcc @counted
@one:
    sec
    lda fp_t
    sbc #$DC
    sta fp_t
    lda fp_t+1
    sbc #$FF
    sta fp_t+1
    lda fp_t+2
    sbc #0
    sta fp_t+2
    lda fp_t+3
    sbc #0
    sta fp_t+3
    inc fds_sides
    lda fds_sides
    cmp #FDS_MAX_SIDES + 1
    bcc @sub
    lda #$53
    sec
    rts
@counted:
    lda fds_sides
    bne @ok
    lda #$52
    sec
    rts
@ok:
    clc
    rts
@no:
    lda #$40
    sec
    rts

fds_hvc:     .byte "*NINTENDO-HVC*"
name_disksys: .byte "DISKSYS ROM"
fds_magic:   .byte "N8FD"
; save SRAM 8 KB page of the kept side (side 0 at $00000)
fds_sbase:   .byte 0
; BIOS IRQ handler, transfer path: $E1CE LDX $4031 / $E1D1 STA $4024 ->
; JSR $5700 / JSR $5704; end of a block write: $E729 JSR $E7A3 -> JSR $5708
; (the core's stub, see map_fds.v)
fds_bios_orig:  .byte $AE, $31, $40, $8D, $24, $40
fds_bios_patch: .byte $20, $00, $57, $20, $04, $57
fds_bios_orig2:  .byte $20, $A3, $E7
fds_bios_patch2: .byte $20, $08, $57

; launch_fds: load and start the FDS image in LIST record `sel` (after
; fds_detect). Returns only on error (carry set, A = code), with the menu's
; save SRAM page mapped again.
launch_fds:
    jsr fds_go              ; does not return when the game starts
    pha
    lda #SRAM_MENU
    jsr sram_page
    pla
    sec
    rts

fds_go:
    jsr save_pending        ; a save not yet written back lives in the save
    bcc @free               ; SRAM: loading would overwrite it
    lda #$48
    rts
@free:
    lda #1
    sta is_fds
    lda #$14                ; CPLD $09 bits 2 + 4, as the clone menu sets them
    sta cpld_or             ; for FDS (bit 2: meaning unknown)
    ; every FDS game is NTSC (Japan only): correct on a PAL console unless B
    lda #0
    sta pal_fix
    lda console
    cmp #RG_PAL
    bne @nopal
    lda no_fix
    bne @nopal
    inc pal_fix
@nopal:
    lda #$FE                ; MAPROUT.BIN entry $FE = FDS
    sta mapper
    jsr lookup_core
    bcc @mr
    rts
@mr:
    lda core_num
    cmp #$FF
    bne @core
    lda #$43
    sec
    rts
@core:
    jsr find_core_rbf       ; /EDFC/MAPS/NNN.RBF -> ext_tab
    bcc @bios
    rts

    ; --- BIOS: /EDFC/DISKSYS.ROM, 8 KB -> PRG $08000, check, patch
@bios:
    ldx #10
@bn:
    lda name_disksys,x
    sta fname,x
    dex
    bpl @bn
    MOV32 it_clus, dir_edfc
    jsr find_name
    bcs @nobios
    lda f_size
    ora f_size+2
    ora f_size+3
    bne @nobios
    lda f_size+1
    cmp #$20
    beq @bios_ok
@nobios:
    lda #$50
    sec
    rts
@bios_ok:
    jsr stream_open
    bcc @bs
    rts
@bs:
    lda #FDS_BIOS_PAGE
    jsr fds_window
    lda #0
    sta copy_n
    sta copy_n+2
    lda #$20
    sta copy_n+1
    jsr stream_copy
    bcc @bc
    rts
@bc:
    lda #FDS_BIOS_PAGE      ; $E1CE = page 16 + $1CE
    jsr fds_window
    ldx #5
@ck:
    lda $49CE,x
    cmp fds_bios_orig,x
    beq :+
    jmp @badbios
:
    dex
    bpl @ck
    ldx #2                  ; $E729 = page 16 + $729
@ck2:
    lda $4F29,x
    cmp fds_bios_orig2,x
    beq :+
    jmp @badbios
:   dex
    bpl @ck2
    ldx #5
@pt:
    lda fds_bios_patch,x
    sta $49CE,x
    dex
    bpl @pt
    ldx #2
@pt2:
    lda fds_bios_patch2,x
    sta $4F29,x
    dex
    bpl @pt2

    ; --- block table staging area: all $FF
    lda #FDS_TBL_PAGE
    jsr fds_window
    ldx #0
    lda #$FF
@ff:
    sta $4800,x
    sta $4900,x
    sta $4A00,x
    sta $4B00,x
    sta $4C00,x
    sta $4D00,x
    sta $4E00,x
    sta $4F00,x
    inx
    bne @ff

    ; --- side 0 -> save SRAM $00000, sides 1-3 -> PRG $20000/$30000/$40000
    MOV32 f_clus, rom_clus
    jsr stream_open
    bcc @so
    rts
@so:
    lda fds_off
    sta st_off
    lda #0
    sta fp_n
@side:
    ldx fp_n
    cpx #FDS_KEPT
    bcs @prgside
    lda fds_sbase,x
    jsr fds_swindow
    jmp @copy
@prgside:
    txa                     ; PRG page = 32 x (n + 1)
    clc
    adc #1
    asl
    asl
    asl
    asl
    asl
    jsr fds_window
@copy:
    lda #$DC                ; 65500 bytes
    sta copy_n
    lda #$FF
    sta copy_n+1
    lda #0
    sta copy_n+2
    jsr stream_copy
    bcc @snext
    rts
@snext:
    inc fp_n
    lda fp_n
    cmp fds_sides
    bne @side

    ; --- block tables
    lda #0
    sta fp_n
@tb:
    jsr fds_table
    inc fp_n
    lda fp_n
    cmp fds_sides
    bne @tb

    ; --- save record: written files go back to the .fds at the next start
    lda #SRAM_MENU
    jsr sram_page
    jsr fds_record
    bcc :+
    rts
:

    ; screen off once, in vblank (as before the CHR part of a .nes)
    jsr vwait
    lda #0
    sta PPUMASK
    lda #$1F                ; no PRG mask: the core addresses all of PRG SRAM
    sta cfg_prg
    lda #$80                ; CHR RAM
    sta cfg_chr
    lda pal_fix
    beq @cfg
    lda #$40                ; bit 6: NTSC game on PAL (timer correction)
@cfg:
    sta cfg_map
    jmp run_ramcode
@badbios:
    lda #$51
    sec
    rts

; fds_window: PRG window page A at $4800 (dst = $4800, sink = PRG)
fds_window:
    sta prg_page
    ldx #FPGA_PRG_PAGE
    stx N8_IDX
    sta N8_DAT
    lda #$00
    sta dst
    sta sink
    lda #$48
    sta dst+1
    rts

; fds_swindow: save SRAM page A at $6000 (dst = $6000, sink = save SRAM)
fds_swindow:
    sta prg_page
    jsr sram_page
    lda #$00
    sta dst
    lda #2
    sta sink
    lda #$60
    sta dst+1
    rts

; fds_record: the save record (page 8 mapped, rec = the image's LIST record).
; The record stores the file's 8.3 name: looked up from the long name in
; the current directory (and checked against the cluster we loaded).
; Carry set: A = error ($4B: the entry does not match).
fds_record:
    ldy #0
@nm:
    lda (rec),y             ; long name -> sv_name (0-terminated)
    sta sv_name,y
    beq @named
    iny
    cpy #NAME_MAX
    bne @nm
    lda #0
    sta sv_name,y
@named:
    MOV32 dw_dir, cur_dir
    lda #<sv_name
    sta nm
    lda #>sv_name
    sta nm+1
    jsr find_long           ; -> fname (8.3), f_clus
    bcc @found
    tax
    bne @err
@bad:
    lda #$4B
@err:
    sec
    rts
@found:
    ldx #3
@cc:
    lda f_clus,x
    cmp rom_clus,x
    bne @bad
    dex
    bpl @cc
    lda #SRAM_REC
    jsr sram_page
    ldy #3
@f: lda vol_id,y
    sta REC+4,y
    lda cur_dir,y
    sta REC+8,y
    lda rom_clus,y
    sta REC+$0C,y
    lda fds_size,y
    sta REC+$10,y
    dey
    bpl @f
    lda fds_off
    sta REC+$14
    lda fds_sides
    cmp #FDS_KEPT + 1
    bcc @k
    lda #FDS_KEPT
@k: sta REC+$15
    ldy #10
@n: lda fname,y
    sta REC+$16,y
    dey
    bpl @n
    ldy #3
@m: lda fds_magic,y
    sta REC,y
    dey
    bpl @m
    lda #SRAM_MENU
    jsr sram_page
    clc
    rts

; fds_table: block table of side fp_n into the staging area: the start of
; every block (types 1, 2, 3, 4 with the size from the preceding 3) until
; the zero fill or the end of the side, then the end, then $FFFF. At most
; 254 blocks (the core's table has 256 entries per side).
fds_table:
    lda #0
    sta fp_p
    sta fp_p+1
    sta fp_e
    sta fp_have
@blk:
    lda fp_p+1              ; at or past 65500: no further block
    cmp #$FF
    bcc @in
    lda fp_p
    cmp #$DC
    bcc :+
    jmp @end
:
@in:
    ldy #0
    jsr fp_rd
    cmp #1
    bne @t2
    lda #56
    bne @len8
@t2:
    cmp #2
    bne @t3
    lda #2
    bne @len8
@t3:
    cmp #3
    bne @t4
    ldy #13                 ; file size in the header (bytes 13-14)
    jsr fp_rd
    sta fp_size
    ldy #14
    jsr fp_rd
    sta fp_size+1
    lda #1
    sta fp_have
    lda #16
    bne @len8
@t4:
    cmp #4
    bne @end
    lda fp_have
    beq @end
    lda #0
    sta fp_have
    clc                     ; length = 1 + size
    lda fp_size
    adc #1
    sta fp_len
    lda fp_size+1
    adc #0
    sta fp_len+1
    bcs @end                ; size $FFFF: cannot fit
    bcc @add
@len8:
    sta fp_len
    lda #0
    sta fp_len+1
@add:
    clc                     ; q = p + len, must be <= 65500
    lda fp_p
    adc fp_len
    sta fp_q
    lda fp_p+1
    adc fp_len+1
    sta fp_q+1
    bcs @end
    cmp #$FF
    bcc @fits
    lda fp_q
    cmp #$DD
    bcs @end
@fits:
    lda fp_e
    cmp #254
    bcs @end
    lda fp_p
    ldx fp_p+1
    jsr fp_put
    lda fp_q
    sta fp_p
    lda fp_q+1
    sta fp_p+1
    jmp @blk
@end:
    lda fp_p
    ldx fp_p+1
    jsr fp_put
    lda #$FF
    tax
    ; fall through

; fp_put: table entry fp_e of side fp_n = A (low) / X (high)
fp_put:
    pha
    txa
    pha
    lda #FDS_TBL_PAGE
    ldx #FPGA_PRG_PAGE
    stx N8_IDX
    sta N8_DAT
    lda fp_e                ; address = $4800 + n x $200 + e x 2
    asl
    sta src
    lda #0
    rol                     ; e >> 7
    sta tmp
    lda fp_n
    asl
    clc
    adc tmp
    adc #$48
    sta src+1
    ldy #1
    pla
    sta (src),y
    dey
    pla
    sta (src),y
    inc fp_e
    rts

; fp_rd: A = byte at offset fp_p + Y of side fp_n: side 0 through the
; save SRAM window (8 KB pages at $6000), sides 1-3 through the PRG window
fp_rd:
    tya
    clc
    adc fp_p
    sta src
    lda fp_p+1
    adc #0
    sta src+1               ; src = offset (16 bit)
    ldx fp_n
    cpx #FDS_KEPT
    bcs @prg
    lsr                     ; save SRAM page = base + offset >> 13
    lsr
    lsr
    lsr
    lsr
    clc
    adc fds_sbase,x
    jsr sram_page
    lda src+1
    and #$1F
    ora #$60
    sta src+1
    ldy #0
    lda (src),y
    rts
@prg:
    lsr                     ; PRG page = 32 x (n + 1) + offset >> 11
    lsr
    lsr
    sta tmp
    txa
    clc
    adc #1
    asl
    asl
    asl
    asl
    asl
    clc
    adc tmp
    ldx #FPGA_PRG_PAGE
    stx N8_IDX
    sta N8_DAT
    lda src+1
    and #$07
    ora #$48
    sta src+1
    ldy #0
    lda (src),y
    rts

; ------------------------------------------------------------ menu start
; fds_flush: the pending FDS record -> its .fds file. Every sector of the
; kept sides is compared with the save SRAM and written only if it differs
; (in place, no FAT change); the header is never touched. Written only if
; the card's volume ID matches and the recorded 8.3 name in the recorded
; directory still is the file with the recorded cluster and size.
; Carry set: A = error ($4A, $4B, SD/FAT errors); the record stays.
fds_flush:
    jsr @go
    pha
    php
    lda #SRAM_MENU
    jsr sram_page
    plp
    pla
    rts
@go:
    lda #SRAM_REC
    jsr sram_page
    ldy #3
@f: lda REC+4,y
    sta sv_last,y           ; (recorded volume ID)
    lda REC+8,y
    sta sv_dir,y
    lda REC+$0C,y
    sta sv_clus,y
    lda REC+$10,y
    sta fds_size,y
    dey
    bpl @f
    lda REC+$14
    sta fds_off
    lda REC+$15
    sta fds_sides
    ldy #10
@n: lda REC+$16,y
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
    MOV32 it_clus, sv_dir   ; same file? (8.3 name in the recorded directory)
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
    ldx #3
@c: lda f_clus,x
    cmp sv_clus,x
    bne @changed
    lda f_size,x
    cmp fds_size,x
    bne @changed
    dex
    bpl @c
    lda fds_sides           ; sides kept: 1
    beq @changed
    cmp #FDS_KEPT + 1
    bcc @walk
@changed:
    lda #$4B
    sec
    rts

@walk:
    ; bytes to compare: sides x 65500 after the header
    lda #0
    sta fp_t
    sta fp_t+1
    sta fp_t+2
    ldx fds_sides
@mul:
    clc
    lda fp_t
    adc #$DC
    sta fp_t
    lda fp_t+1
    adc #$FF
    sta fp_t+1
    lda fp_t+2
    adc #0
    sta fp_t+2
    dex
    bne @mul
    lda fds_off             ; header bytes first (skipped)
    sta fp_e
    lda #0                  ; side 0, position 0
    sta fp_n
    sta fp_p
    sta fp_p+1
    lda fds_sbase
    sta prg_page
    jsr sram_page
    lda #$00
    sta dst
    lda #$60
    sta dst+1
    MOV32 de_clus, sv_clus
@cl:
    MOV32 clus, de_clus
    jsr clus_to_lba
    MOV32 de_lba, lba
    lda spc
    sta sv_n
@sec:
    MOV32 lba, de_lba
    lda #0
    sta fc_ok               ; (SECBUF no longer holds a FAT sector)
    jsr sd_read
    bcc @rd
    rts
@rd:
    lda #0
    sta fp_have             ; sector changed?
    lda #<SECBUF
    sta src
    lda #>SECBUF
    sta src+1
    lda #0
    sta fp_q
    lda #2                  ; 512 bytes
    sta fp_q+1
@byte:
    lda fp_e                ; still in the header?
    beq @data
    dec fp_e
    jmp @nextb
@data:
    lda fp_t                ; all compared?
    ora fp_t+1
    ora fp_t+2
    bne :+
    jmp @last
:
    ldy #0
    lda (dst),y
    cmp (src),y
    beq @same
    sta (src),y
    lda #1
    sta fp_have
@same:
    lda fp_t                ; remaining - 1 (24 bit)
    bne @d0
    lda fp_t+1
    bne @d1
    dec fp_t+2
@d1:
    dec fp_t+1
@d0:
    dec fp_t
    inc dst                 ; save SRAM pointer + 1, next page at $8000
    bne @pos
    inc dst+1
    lda dst+1
    cmp #$80
    bne @pos
    lda #$60
    sta dst+1
    inc prg_page
    lda prg_page
    jsr sram_page
@pos:
    inc fp_p                ; side position + 1, next side at 65500
    bne :+
    inc fp_p+1
:   lda fp_p+1
    cmp #$FF
    bne @nextb
    lda fp_p
    cmp #$DC
    bne @nextb
    lda #0
    sta fp_p
    sta fp_p+1
    inc fp_n
    ldx fp_n
    cpx #FDS_KEPT
    bcs @nextb              ; (all kept sides done: fp_t is 0 now)
    lda fds_sbase,x
    sta prg_page
    jsr sram_page
    lda #$00
    sta dst
    lda #$60
    sta dst+1
@nextb:
    inc src
    bne :+
    inc src+1
:   lda fp_q                ; 512 bytes per sector
    bne :+
    dec fp_q+1
:   dec fp_q
    lda fp_q
    ora fp_q+1
    beq :+
    jmp @byte
:
@last:
    lda fp_have
    beq @clean
    MOV32 lba, de_lba
    jsr sd_write
    bcc @clean
    rts
@clean:
    lda fp_t
    ora fp_t+1
    ora fp_t+2
    beq @done
    INC32 de_lba
    dec sv_n
    beq :+
    jmp @sec
:   MOV32 clus, de_clus
    jsr next_cluster
    bcc @nc
    tax                     ; chain shorter than the file: changed
    bne @err
    lda #$4B
    sec
    rts
@err:
    txa
    sec
    rts
@nc:
    MOV32 de_clus, clus
    jmp @cl
@done:
    jsr save_discard
    clc
    rts
