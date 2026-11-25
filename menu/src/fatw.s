; ======================================================================
; FAT32 writing: cluster allocation (all FAT copies + FSInfo), directory
; entries with long file names, creating files and directories.
;
; Error codes (A, carry set): $25 volume full, $26 no free 8.3 name,
; $27 long name longer than 63 characters, $28 file too big (> 255 clusters)
; plus the SD/FAT read errors.
;
; Order of the writes (power loss safety): the FAT chain first, then the
; cluster contents, then the directory entry. A power loss in between leaves
; lost clusters at worst (chkdsk frees them), never a file pointing at
; unallocated or foreign clusters. FSInfo is only a hint (free count, next
; free cluster) and is updated together with the FAT.
;
; New entries go to the first slot that starts with $00 (end of the
; directory); deleted slots ($E5) are not reused. Everything after that slot
; is free by definition (FAT spec), so no terminator is written.
; ======================================================================

EOC_LO = $FF                ; end-of-chain value $0FFFFFFF

; ------------------------------------------------------------ FAT entries
; fat_entry: SECBUF = the FAT sector holding entry `clus` (read unless it
; is already there), fp = pointer to the entry. Carry set: A = error.
fat_entry:
    lda clus                ; lba = fat_lba + clus / 128
    asl
    lda clus+1
    rol
    sta lba
    lda clus+2
    rol
    sta lba+1
    lda clus+3
    rol
    sta lba+2
    lda #0
    rol
    sta lba+3
    ADD32 lba, lba, fat_lba
    lda clus                ; fp = SECBUF + (clus & 127) * 4
    and #$7F
    asl
    asl
    sta fp
    lda #>SECBUF
    adc #0
    sta fp+1
    lda fc_ok
    beq @read
    ldx #3
@cmp:
    lda lba,x
    cmp fc_lba,x
    bne @read
    dex
    bpl @cmp
    clc
    rts
@read:
    jsr sd_read             ; clears fc_ok
    bcs @r
    MOV32 fc_lba, lba
    lda #1
    sta fc_ok
    clc
@r: rts

; fat_get: fv = FAT[clus] (28 bits). Carry set: A = error.
fat_get:
    jsr fat_entry
    bcs @r
    ldy #0
@l: lda (fp),y
    sta fv,y
    iny
    cpy #4
    bne @l
    lda fv+3
    and #$0F
    sta fv+3
    clc
@r: rts

; fat_put: FAT[clus] = fv (the top 4 bits of the entry are kept), written
; to every FAT copy. Carry set: A = error.
fat_put:
    jsr fat_entry
    bcs @r
    ldy #3
    lda (fp),y
    and #$F0
    ora fv+3
    sta (fp),y
    dey
@l: lda fv,y
    sta (fp),y
    dey
    bpl @l
    MOV32 lba, fc_lba
    lda nfats
    sta fw_k
@w: jsr sd_write
    bcs @r
    ADD32 lba, lba, fat_size
    dec fw_k
    bne @w
    clc
@r: rts

; ------------------------------------------------------------ FSInfo
; fsi_read: SECBUF = FSInfo sector. A = 1 if its signatures are valid,
; else 0. Carry set: A = error.
fsi_read:
    MOV32 lba, fsi_lba
    jsr sd_read
    bcs @r
    ldx #3
@sig:
    lda SECBUF,x
    cmp fsi_sig0,x
    bne @bad
    lda SECBUF+484,x
    cmp fsi_sig1,x
    bne @bad
    dex
    bpl @sig
    lda #1
    clc
    rts
@bad:
    lda #0
    clc
@r: rts
fsi_sig0: .byte $52, $52, $61, $41      ; "RRaA"
fsi_sig1: .byte $72, $72, $41, $61      ; "rrAa"

; fsi_update: after an allocation of al_n clusters ending at al_prev: free
; count - al_n (an unknown count, $FFFFFFFF, stays unknown), next-free hint
; = al_prev + 1. Nothing to do without a valid FSInfo sector.
fsi_update:
    jsr fsi_read
    bcc @read
    rts
@read:
    cmp #1
    beq @valid
    clc                     ; no valid FSInfo: nothing to keep up to date
    rts
@valid:
    lda SECBUF+488
    and SECBUF+489
    and SECBUF+490
    and SECBUF+491
    cmp #$FF
    beq @hint
    sec
    lda SECBUF+488
    sbc al_n
    sta SECBUF+488
    lda SECBUF+489
    sbc #0
    sta SECBUF+489
    lda SECBUF+490
    sbc #0
    sta SECBUF+490
    lda SECBUF+491
    sbc #0
    sta SECBUF+491
@hint:
    clc                     ; hint = al_prev + 1, or 2 past the last cluster
    lda al_prev
    adc #1
    sta SECBUF+492
    lda al_prev+1
    adc #0
    sta SECBUF+493
    lda al_prev+2
    adc #0
    sta SECBUF+494
    lda al_prev+3
    adc #0
    sta SECBUF+495
    lda SECBUF+492          ; hint < max_clus ?
    cmp max_clus
    lda SECBUF+493
    sbc max_clus+1
    lda SECBUF+494
    sbc max_clus+2
    lda SECBUF+495
    sbc max_clus+3
    bcc @write
    lda #2
    sta SECBUF+492
    lda #0
    sta SECBUF+493
    sta SECBUF+494
    sta SECBUF+495
@write:
    MOV32 lba, fsi_lba
    jmp sd_write

; ------------------------------------------------------------ allocation
; fat_alloc: allocate al_n (1..255) free clusters as one chain (not
; necessarily contiguous), starting the search at the FSInfo hint.
; Pass 1 only checks that enough clusters are free, so a full volume leaves
; the FAT unchanged. Out: al_first, al_prev = last cluster.
; Carry set: A = error ($25 = volume full).
fat_alloc:
    lda #2                  ; default start: cluster 2
    sta al_start
    lda #0
    sta al_start+1
    sta al_start+2
    sta al_start+3
    jsr fsi_read
    bcc @fsi
    rts
@fsi:
    cmp #1
    bne @go
    ldx #3                  ; hint usable if 2 <= hint < max_clus
@cp:
    lda SECBUF+492,x
    sta al_c,x
    dex
    bpl @cp
    lda al_c+3
    ora al_c+2
    ora al_c+1
    bne @hi_ok
    lda al_c
    cmp #2
    bcc @go
@hi_ok:
    lda al_c                ; al_c < max_clus ?
    cmp max_clus
    lda al_c+1
    sbc max_clus+1
    lda al_c+2
    sbc max_clus+2
    lda al_c+3
    sbc max_clus+3
    bcs @go
    MOV32 al_start, al_c
@go:
    lda #0
    sta al_pass
@pass:
    MOV32 al_c, al_start
    sec                     ; al_left = max_clus - 2
    lda max_clus
    sbc #2
    sta al_left
    lda max_clus+1
    sbc #0
    sta al_left+1
    lda max_clus+2
    sbc #0
    sta al_left+2
    lda max_clus+3
    sbc #0
    sta al_left+3
    lda #0
    sta al_got
    sta al_prev
    sta al_prev+1
    sta al_prev+2
    sta al_prev+3
@scan:
    lda al_left
    ora al_left+1
    ora al_left+2
    ora al_left+3
    bne @more
    lda #$25                ; scanned everything: not enough free clusters
    sec
    rts
@more:
    MOV32 clus, al_c
    jsr fat_get
    bcc @got
    rts
@got:
    lda fv
    ora fv+1
    ora fv+2
    ora fv+3
    bne @used
    lda al_pass
    beq @count
    jsr al_take
    bcc @count
    rts
@count:
    inc al_got
    lda al_got
    cmp al_n
    beq @found
@used:
    INC32 al_c
    lda al_c                ; wrap around at max_clus
    cmp max_clus
    bne @dec
    lda al_c+1
    cmp max_clus+1
    bne @dec
    lda al_c+2
    cmp max_clus+2
    bne @dec
    lda al_c+3
    cmp max_clus+3
    bne @dec
    lda #2
    sta al_c
    lda #0
    sta al_c+1
    sta al_c+2
    sta al_c+3
@dec:
    sec
    lda al_left
    sbc #1
    sta al_left
    lda al_left+1
    sbc #0
    sta al_left+1
    lda al_left+2
    sbc #0
    sta al_left+2
    lda al_left+3
    sbc #0
    sta al_left+3
    jmp @scan
@found:
    lda al_pass
    bne @done
    inc al_pass
    jmp @pass
@done:
    jmp fsi_update

; pass 2 of fat_alloc: cluster al_c is free -> end of the chain, linked
; from the previous one (or the first of the chain)
al_take:
    MOV32 clus, al_c
    lda #EOC_LO
    sta fv
    sta fv+1
    sta fv+2
    lda #$0F
    sta fv+3
    jsr fat_put
    bcs @r
    lda al_prev
    ora al_prev+1
    ora al_prev+2
    ora al_prev+3
    bne @link
    MOV32 al_first, al_c
    jmp @set
@link:
    MOV32 clus, al_prev
    MOV32 fv, al_c
    jsr fat_put
    bcs @r
@set:
    MOV32 al_prev, al_c
    clc
@r: rts

; ------------------------------------------------------------ contents
clear_secbuf:
    lda #0
    sta fc_ok
    tay
@l: sta SECBUF,y
    sta SECBUF+256,y
    iny
    bne @l
    rts

; zero_chain: write $00 to every sector of the chain starting at clus.
; Carry set: A = error.
zero_chain:
@cl:
    jsr clear_secbuf        ; (next_cluster reads into SECBUF: clear each time)
    jsr clus_to_lba
    lda spc
    sta fw_k
@s: jsr sd_write
    bcs @r
    INC32 lba
    dec fw_k
    bne @s
    jsr next_cluster
    bcc @cl
    tax                     ; A = 0: end of the chain
    beq @end
    txa
    sec
    rts
@end:
    clc
@r: rts

; ------------------------------------------------------------ directory slots
; ptr = SECBUF + de_ent * 32
de_ptr:
    lda de_ent
    asl
    asl
    asl
    asl
    asl
    sta ptr
    lda de_ent
    lsr
    lsr
    lsr
    clc
    adc #>SECBUF
    sta ptr+1
    rts

; de_load: SECBUF = sector de_lba, ptr = slot de_ent
de_load:
    MOV32 lba, de_lba
    jsr sd_read
    bcs @r
    jsr de_ptr
    clc
@r: rts

de_store:
    MOV32 lba, de_lba
    jmp sd_write

; de_next_sector: slot 0 of the next directory sector. At the end of the
; cluster chain the directory grows by a zeroed cluster (zeroed before it
; is linked in). Carry set: A = error.
de_next_sector:
    lda #0
    sta de_ent
    inc de_sec
    lda de_sec
    cmp spc
    beq @clus
    INC32 de_lba
    clc
    rts
@clus:
    lda #0
    sta de_sec
    MOV32 clus, de_clus
    jsr next_cluster
    bcc @have
    tax
    beq @grow
    txa
    sec
    rts
@grow:
    lda #1
    sta al_n
    jsr fat_alloc
    bcs @r
    MOV32 clus, al_first
    jsr zero_chain
    bcs @r
    MOV32 clus, de_clus
    MOV32 fv, al_first
    jsr fat_put
    bcs @r
    MOV32 clus, al_first
@have:
    MOV32 de_clus, clus
    jsr clus_to_lba
    MOV32 de_lba, lba
    clc
@r: rts

; de_next_slot: advance one slot
de_next_slot:
    inc de_ent
    lda de_ent
    cmp #16
    bne @same
    jmp de_next_sector
@same:
    clc
    rts

; dw_find_end: de_* = first slot starting with $00 in directory dw_dir.
dw_find_end:
    MOV32 de_clus, dw_dir
    lda de_clus
    ora de_clus+1
    ora de_clus+2
    ora de_clus+3
    bne @have
    MOV32 de_clus, root_clus
@have:
    lda #0
    sta de_sec
    MOV32 clus, de_clus
    jsr clus_to_lba
    MOV32 de_lba, lba
@sec:
    lda #0
    sta de_ent
    jsr de_load
    bcs @r
@ent:
    jsr de_ptr
    ldy #0
    lda (ptr),y
    beq @found
    inc de_ent
    lda de_ent
    cmp #16
    bne @ent
    jsr de_next_sector
    bcs @r
    jmp @sec
@found:
    clc
@r: rts

; ------------------------------------------------------------ entries
; dir_add: add an entry to directory dw_dir: fname = 8.3 name (unique in
; the directory, see sfn_unique), nm = long name (nm+1 = 0: none), w_attr,
; w_clus, w_size. Carry set: A = error.
dir_add:
    jsr lfn_prep
    bcs @r
    jsr dw_find_end
    bcs @r
    lda lfn_n               ; long name entries, highest number first
    beq @sfn
    sta lfn_k
@lfn:
    jsr de_load
    bcs @r
    jsr build_lfn
    jsr de_store
    bcs @r
    jsr de_next_slot
    bcs @r
    dec lfn_k
    bne @lfn
@sfn:
    jsr de_load
    bcs @r
    jsr build_sfn
    jmp de_store
@r: rts

; lfn_prep: lfn_len, lfn_n (0 = no long name: nm+1 = 0), lfn_sum (from
; fname). Carry set: A = $27 (long name over 63 characters).
lfn_prep:
    lda #0
    sta lfn_n
    lda nm+1
    beq @done
    ldy #0                  ; long name length (max 63)
@len:
    lda (nm),y
    beq @lend
    iny
    cpy #64
    bne @len
    lda #$27
    sec
    rts
@lend:
    sty lfn_len
    tya                     ; entries = (len + 12) / 13
    clc
    adc #12
    ldx #0
@div:
    cmp #13
    bcc @dd
    sbc #13
    inx
    bne @div
@dd:
    stx lfn_n
    lda #0                  ; checksum of the 8.3 name
    ldx #0
@ck:
    lsr
    bcc @nb
    ora #$80
@nb:
    clc
    adc fname,x
    inx
    cpx #11
    bne @ck
    sta lfn_sum
@done:
    clc
    rts

; dir_room: make sure directory dw_dir has the lfn_n + 1 free slots a new
; entry needs at its end, growing it now - before any cluster of the new
; file is allocated (a full volume then fails cleanly, no lost clusters).
dir_room:
    jsr lfn_prep
    bcs @r
    jsr dw_find_end
    bcs @r
    lda lfn_n
    beq @ok
    sta lfn_k
@l: jsr de_next_slot
    bcs @r
    dec lfn_k
    bne @l
@ok:
    clc
@r: rts

; LFN entry lfn_k at (ptr): characters (lfn_k - 1) * 13 ... + 12 of the name
build_lfn:
    lda lfn_k
    cmp lfn_n
    bne @ord
    ora #$40                ; last part (stored first)
@ord:
    ldy #0
    sta (ptr),y
    ldy #11
    lda #$0F
    sta (ptr),y
    iny
    lda #0
    sta (ptr),y             ; type
    iny
    lda lfn_sum
    sta (ptr),y
    ldy #26
    lda #0
    sta (ptr),y             ; cluster: always 0
    iny
    sta (ptr),y
    lda lfn_k               ; lfn_pos = (lfn_k - 1) * 13
    sec
    sbc #1
    sta tmp
    asl
    asl
    sta tmp+1
    asl
    clc
    adc tmp+1
    clc
    adc tmp
    sta lfn_pos
    ldx #0
@ch:
    ldy lfn_pos
    cpy lfn_len
    beq @term
    bcs @pad
    lda (nm),y
    sta tmp+2
    lda #0
    sta tmp+3
    beq @put
@term:
    lda #0                  ; 0000 right after the name
    sta tmp+2
    sta tmp+3
    beq @put
@pad:
    lda #$FF                ; FFFF after that
    sta tmp+2
    sta tmp+3
@put:
    ldy lfn_off,x
    lda tmp+2
    sta (ptr),y
    iny
    lda tmp+3
    sta (ptr),y
    inc lfn_pos
    inx
    cpx #13
    bne @ch
    rts

; 8.3 entry at (ptr) from fname, w_attr, w_clus, w_size; dates 1980-01-01
build_sfn:
    ldy #31
    lda #0
@z: sta (ptr),y
    dey
    bpl @z
    ldy #10
@n: lda fname,y
    sta (ptr),y
    dey
    bpl @n
    ldy #11
    lda w_attr
    sta (ptr),y
    lda #$21                ; date: day 1, month 1, year 1980 (no clock)
    ldy #16
    sta (ptr),y             ; created
    ldy #18
    sta (ptr),y             ; accessed
    ldy #24
    sta (ptr),y             ; written
    ldy #20
    lda w_clus+2
    sta (ptr),y
    iny
    lda w_clus+3
    sta (ptr),y
    ldy #26
    lda w_clus
    sta (ptr),y
    iny
    lda w_clus+1
    sta (ptr),y
    ldy #28
    ldx #0
@sz:
    lda w_size,x
    sta (ptr),y
    iny
    inx
    cpx #4
    bne @sz
    rts

; ------------------------------------------------------------ names
; sfn_unique: fname = 8 hex digits of w_seed + "SAV", for the first of
; w_seed, w_seed + 1, ... (16 tries) not used in dw_dir yet.
; Carry set: A = error ($26: all tried names exist).
sfn_unique:
    lda #16
    sta lfn_k
@try:
    ldx #0
    ldy #3
@h: lda w_seed,y
    lsr
    lsr
    lsr
    lsr
    jsr @hex
    lda w_seed,y
    jsr @hex
    dey
    bpl @h
    lda #'S'
    sta fname+8
    lda #'A'
    sta fname+9
    lda #'V'
    sta fname+10
    MOV32 it_clus, dw_dir
    jsr find_name
    bcc @used
    tax                     ; A = 0: not found = free
    bne @err
    clc
    rts
@err:
    txa
    sec
    rts
@used:
    INC32 w_seed
    dec lfn_k
    bne @try
    lda #$26
    sec
    rts
@hex:
    and #$0F
    cmp #10
    bcc @dig
    adc #6
@dig:
    adc #'0'
    sta fname,x
    inx
    rts

; ------------------------------------------------------------ create
; file_create: new file in dw_dir with long name nm, 8.3 name fname and
; w_size bytes ($00). Clusters are allocated and zeroed before the entry
; is written. Out: w_clus = first cluster. Carry set: A = error.
file_create:
    lda w_size              ; sectors = (size + 511) / 512
    clc
    adc #$FF
    lda w_size+1
    adc #$01
    sta tmp
    lda w_size+2
    adc #0
    sta tmp+1
    lsr tmp+1
    ror tmp
    clc                     ; clusters = (sectors + spc - 1) >> spc_shift
    lda tmp
    adc spc
    sta tmp
    lda tmp+1
    adc #0
    sta tmp+1
    lda tmp
    bne @m1
    dec tmp+1
@m1:
    dec tmp
    ldx spc_shift
    beq @cl
@sh:
    lsr tmp+1
    ror tmp
    dex
    bne @sh
@cl:
    lda tmp+1
    beq @fit
    lda #$28
    sec
    rts
@fit:
    lda tmp
    bne @n
    lda #1                  ; empty file: still one cluster
@n: pha                     ; dir_room may allocate a directory cluster
    jsr dir_room            ; (fat_alloc changes al_n): keep the count
    pla                     ; (pla leaves the carry alone)
    bcs @r
    sta al_n
    jsr fat_alloc
    bcs @r
    MOV32 w_clus, al_first
    MOV32 clus, w_clus
    jsr zero_chain
    bcs @r
    lda #$20                ; archive
    sta w_attr
    jmp dir_add
@r: rts

; dir_create: new directory fname (8.3 only) in dw_dir, with "." and "..".
; Out: w_clus = its cluster. Carry set: A = error.
dir_create:
    lda #1
    sta al_n
    jsr fat_alloc
    bcc @alloc
    rts
@alloc:
    MOV32 w_clus, al_first
    MOV32 clus, w_clus
    jsr zero_chain
    bcc @zeroed
    rts
@zeroed:
    jsr clear_secbuf        ; first sector: "." and ".."
    ldy #10
    lda #' '
@sp:
    sta SECBUF,y
    sta SECBUF+32,y
    dey
    bpl @sp
    lda #'.'
    sta SECBUF
    sta SECBUF+32
    sta SECBUF+33
    lda #$10
    sta SECBUF+11
    sta SECBUF+32+11
    lda #$21
    sta SECBUF+16
    sta SECBUF+18
    sta SECBUF+24
    sta SECBUF+32+16
    sta SECBUF+32+18
    sta SECBUF+32+24
    lda w_clus              ; "." = this directory
    sta SECBUF+26
    lda w_clus+1
    sta SECBUF+27
    lda w_clus+2
    sta SECBUF+20
    lda w_clus+3
    sta SECBUF+21
    ldx #3                  ; ".." = parent, 0 for the root
@root:
    lda dw_dir,x
    cmp root_clus,x
    bne @parent
    dex
    bpl @root
    bmi @dots
@parent:
    lda dw_dir
    sta SECBUF+32+26
    lda dw_dir+1
    sta SECBUF+32+27
    lda dw_dir+2
    sta SECBUF+32+20
    lda dw_dir+3
    sta SECBUF+32+21
@dots:
    MOV32 clus, w_clus
    jsr clus_to_lba
    jsr sd_write
    bcs @r
    lda #$10
    sta w_attr
    lda #0
    sta nm+1
    sta w_size
    sta w_size+1
    sta w_size+2
    sta w_size+3
    jmp dir_add
@r: rts

; ------------------------------------------------------------ search by long name
; find_long: look up the name at (nm) in directory dw_dir, compared
; case-insensitively with each entry's long name, or with its 8.3 name if it
; has none (PC copies of short names like "smb3.sav" often have no long
; name). Directories and volume labels are skipped. Long names are compared
; as the list reads them: first 51 characters, non-ASCII as '?'.
; Carry clear: found; f_clus, f_size, fname = its 8.3 name, sv_elba/sv_eent
; = position of its 8.3 entry. Carry set: A = 0 not found, else error.
find_long:
    MOV32 it_clus, dw_dir
    jsr dir_open
    bcs @r
    lda #0
    sta lfn_ok
@next:
    jsr dir_next
    bcc @entry
@r: rts
@entry:
    ldy #0
    lda (ptr),y
    cmp #$E5
    beq @reset
    ldy #11
    lda (ptr),y
    cmp #$0F
    bne @regular
    jsr lfn_part
    jmp @next
@regular:
    and #$18                ; directory or volume label
    bne @reset
    lda lfn_ok
    beq @short
    lda namebuf
    bne @cmp
@short:
    jsr sfn_to_namebuf
@cmp:
    jsr name_equal
    bcc @found
@reset:
    lda #0
    sta lfn_ok
    jmp @next
@found:
    MOV32 sv_elba, it_lba
    ldx it_ent              ; dir_next already moved on
    dex
    stx sv_eent
    ldy #10
@n: lda (ptr),y
    sta fname,y
    dey
    bpl @n
    ldy #26
    lda (ptr),y
    sta f_clus
    iny
    lda (ptr),y
    sta f_clus+1
    ldy #20
    lda (ptr),y
    sta f_clus+2
    iny
    lda (ptr),y
    sta f_clus+3
    ldy #28
    ldx #0
@s: lda (ptr),y
    sta f_size,x
    iny
    inx
    cpx #4
    bne @s
    clc
    rts

; namebuf = "NAME.EXT" from the 8.3 entry at (ptr)
sfn_to_namebuf:
    ldx #0
    ldy #0
@n: lda (ptr),y
    cmp #' '
    beq @ext
    sta namebuf,x
    inx
    iny
    cpy #8
    bne @n
@ext:
    ldy #8
    lda (ptr),y
    cmp #' '
    beq @end
    lda #'.'
    sta namebuf,x
    inx
@e: lda (ptr),y
    cmp #' '
    beq @end
    sta namebuf,x
    inx
    iny
    cpy #11
    bne @e
@end:
    lda #0
    sta namebuf,x
    rts

; carry clear if namebuf and (nm) are equal, ignoring case
name_equal:
    ldy #0
@l: lda namebuf,y
    jsr upcase
    sta tmp
    lda (nm),y
    jsr upcase
    cmp tmp
    bne @ne
    lda tmp
    beq @eq
    iny
    cpy #64
    bne @l
@ne:
    sec
    rts
@eq:
    clc
    rts

upcase:
    cmp #'a'
    bcc @u
    cmp #'z'+1
    bcs @u
    and #$DF
@u: rts

; entry_fix: the 8.3 entry at sv_elba/sv_eent gets cluster sv_clus and
; size SAVE_SIZE. Carry set: A = error.
entry_fix:
    MOV32 lba, sv_elba
    jsr sd_read
    bcs @r
    lda sv_eent
    sta de_ent
    jsr de_ptr
    ldy #20
    lda sv_clus+2
    sta (ptr),y
    iny
    lda sv_clus+3
    sta (ptr),y
    ldy #26
    lda sv_clus
    sta (ptr),y
    iny
    lda sv_clus+1
    sta (ptr),y
    ldy #28
    lda #<SAVE_SIZE
    sta (ptr),y
    iny
    lda #>SAVE_SIZE
    sta (ptr),y
    iny
    lda #0
    sta (ptr),y
    iny
    sta (ptr),y
    MOV32 lba, sv_elba
    jmp sd_write
@r: rts
