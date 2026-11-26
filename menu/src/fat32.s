; FAT32: mount, directory iteration (with long file names), file search,
; sequential file stream.
; Error codes: $20 no 55AA in sector 0, $21 no FAT32 volume,
;              $22 sector size not 512, $23 bad cluster number,
;              $24 file ends early

LIST        = $6000     ; directory list, save SRAM page 8 (menu data)
REC_SIZE    = 64
REC_NAME    = 0         ; up to 51 chars + 0
REC_ATTR    = 52
REC_CLUS    = 53        ; 4 bytes
REC_FSIZE   = 57        ; 4 bytes
MAX_ENTRIES = 128
NAME_MAX    = 51

; unnamed label: keeps the cheap-local (@) label scope intact
.macro INC32 v
    inc v
    bne :+
    inc v+1
    bne :+
    inc v+2
    bne :+
    inc v+3
:
.endmacro

; ------------------------------------------------------------ mount
fat_mount:
    lda #0
    sta lba
    sta lba+1
    sta lba+2
    sta lba+3
    sta part_lba
    sta part_lba+1
    sta part_lba+2
    sta part_lba+3
    jsr sd_read
    bcc @s0
    rts
@s0:
    lda SECBUF+510
    cmp #$55
    bne @nosig
    lda SECBUF+511
    cmp #$AA
    beq @sig
@nosig:
    lda #$20
    sec
    rts
@sig:
    jsr is_fat32_vbr        ; superfloppy: sector 0 is the volume itself
    bcc @vbr
    MOV32 part_lba, SECBUF+$1C6
    MOV32 lba, part_lba
    jsr sd_read
    bcc @p
    rts
@p: jsr is_fat32_vbr
    bcc @vbr
    lda #$21
    sec
    rts
@vbr:
    lda SECBUF+$0B          ; bytes per sector must be 512
    bne @badsec
    lda SECBUF+$0C
    cmp #$02
    beq @sec_ok
@badsec:
    lda #$22
    sec
    rts
@sec_ok:
    lda SECBUF+$0D
    sta spc
    ldx #0
@log:
    lsr
    bcs @logdone
    inx
    bne @log
@logdone:
    stx spc_shift
    lda SECBUF+$0E
    sta tmp
    lda SECBUF+$0F
    sta tmp+1
    lda #0
    sta tmp+2
    sta tmp+3
    ADD32 fat_lba, part_lba, tmp
    MOV32 data_lba, fat_lba
    ldx SECBUF+$10
@fats:
    ADD32 data_lba, data_lba, SECBUF+$24
    dex
    bne @fats
    MOV32 root_clus, SECBUF+$2C
    MOV32 vol_id, SECBUF+$43        ; volume serial (save record check)
    ; for writing (fatw.s): FAT copies, FSInfo sector, cluster count
    lda SECBUF+$10
    sta nfats
    MOV32 fat_size, SECBUF+$24
    lda SECBUF+$30
    sta tmp
    lda SECBUF+$31
    sta tmp+1
    lda #0
    sta tmp+2
    sta tmp+3
    ADD32 fsi_lba, part_lba, tmp
    ADD32 tmp, part_lba, SECBUF+$20 ; end of the volume - data_lba
    sec                             ; = data sectors
    lda tmp
    sbc data_lba
    sta tmp
    lda tmp+1
    sbc data_lba+1
    sta tmp+1
    lda tmp+2
    sbc data_lba+2
    sta tmp+2
    lda tmp+3
    sbc data_lba+3
    sta tmp+3
    ldx spc_shift
    beq @ccount
@cshift:
    lsr tmp+3
    ror tmp+2
    ror tmp+1
    ror tmp
    dex
    bne @cshift
@ccount:
    clc                             ; max_clus = clusters + 2
    lda tmp
    adc #2
    sta max_clus
    lda tmp+1
    adc #0
    sta max_clus+1
    lda tmp+2
    adc #0
    sta max_clus+2
    lda tmp+3
    adc #0
    sta max_clus+3
    clc
    rts

is_fat32_vbr:
    ldx #4
@l: lda SECBUF+$52,x
    cmp fat32_id,x
    bne @no
    dex
    bpl @l
    clc
    rts
@no:
    sec
    rts
fat32_id:
    .byte "FAT32"

; ------------------------------------------------------------ clusters
; lba = data_lba + (clus - 2) << spc_shift
clus_to_lba:
    sec
    lda clus
    sbc #2
    sta tmp
    lda clus+1
    sbc #0
    sta tmp+1
    lda clus+2
    sbc #0
    sta tmp+2
    lda clus+3
    sbc #0
    sta tmp+3
    ldx spc_shift
    beq @add
@sh:
    asl tmp
    rol tmp+1
    rol tmp+2
    rol tmp+3
    dex
    bne @sh
@add:
    ADD32 lba, data_lba, tmp
    rts

; clus = FAT[clus]. Carry clear: next cluster in clus.
; Carry set: A = 0 end of chain, A = error code otherwise.
next_cluster:
    lda clus
    asl
    sta tmp
    lda clus+1
    rol
    sta tmp+1
    lda clus+2
    rol
    sta tmp+2
    lda clus+3
    rol
    sta tmp+3
    lda clus
    and #$7F
    asl
    asl
    pha
    php
    lda tmp+1
    sta lba
    lda tmp+2
    sta lba+1
    lda tmp+3
    sta lba+2
    lda #0
    sta lba+3
    ADD32 lba, lba, fat_lba
    jsr sd_read
    bcc @read_ok
    tax
    plp
    pla
    txa
    sec
    rts
@read_ok:
    plp
    pla
    tay
    bcs @hi
    lda SECBUF,y
    sta clus
    lda SECBUF+1,y
    sta clus+1
    lda SECBUF+2,y
    sta clus+2
    lda SECBUF+3,y
    and #$0F
    sta clus+3
    jmp @check
@hi:
    lda SECBUF+256,y
    sta clus
    lda SECBUF+257,y
    sta clus+1
    lda SECBUF+258,y
    sta clus+2
    lda SECBUF+259,y
    and #$0F
    sta clus+3
@check:
    lda clus+3
    cmp #$0F
    bne @not_end
    lda clus+2
    and clus+1
    cmp #$FF
    bne @not_end
    lda clus
    cmp #$F8
    bcc @not_end
    lda #0                  ; end of chain
    sec
    rts
@not_end:
    lda clus+3
    ora clus+2
    ora clus+1
    bne @ok
    lda clus
    cmp #2
    bcs @ok
    lda #$23
    sec
    rts
@ok:
    clc
    rts

; ------------------------------------------------------------ directory iterator
; dir_open: it_clus = directory cluster (0 = root). Reads the first sector.
dir_open:
    lda it_clus
    ora it_clus+1
    ora it_clus+2
    ora it_clus+3
    bne @have
    MOV32 it_clus, root_clus
@have:
    lda #0
    sta it_sec
    sta it_ent
    MOV32 clus, it_clus
    jsr clus_to_lba
    MOV32 it_lba, lba
    jmp sd_read

; dir_next: ptr = next 32-byte entry. Carry set: A = 0 end, else error code.
dir_next:
    lda it_ent
    cmp #16
    bne @have
    lda #0
    sta it_ent
    inc it_sec
    lda it_sec
    cmp spc
    bne @same
    lda #0
    sta it_sec
    MOV32 clus, it_clus
    jsr next_cluster
    bcc @nc
    rts                     ; A = 0 end of chain, or error
@nc:
    MOV32 it_clus, clus
    jsr clus_to_lba
    MOV32 it_lba, lba
    jmp @rd
@same:
    INC32 it_lba
@rd:
    MOV32 lba, it_lba
    jsr sd_read
    bcc @have
    rts
@have:
    lda it_ent
    asl
    asl
    asl
    asl
    asl
    sta ptr
    lda it_ent
    lsr
    lsr
    lsr
    clc
    adc #>SECBUF
    sta ptr+1
    inc it_ent
    ldy #0
    lda (ptr),y
    bne @ok
    lda #0                  ; end-of-directory marker
    sec
    rts
@ok:
    clc
    rts

; ------------------------------------------------------------ listing
; dir_load: reads directory cur_dir (0 = root) into LIST, folders first.
; Skips deleted, hidden, volume and "."/".." entries. dcount = entries.
dir_load:
    lda #0
    sta dcount
    sta pass
@pass:
    MOV32 it_clus, cur_dir
    jsr dir_open
    bcc @start
    rts
@start:
    lda #0
    sta lfn_ok
@next:
    jsr dir_next
    bcc @entry
    cmp #0
    beq @pass_done
    sec
    rts
@pass_done:
    inc pass
    lda pass
    cmp #2
    bne @pass
    clc
    rts
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
    and #$0A                ; volume label or hidden
    bne @reset
    ldy #0
    lda (ptr),y
    cmp #'.'
    beq @reset
    ldy #11
    lda (ptr),y
    and #$10
    beq @isfile
    lda pass                ; folder: only in pass 0
    bne @reset
    beq @take
@isfile:
    lda pass                ; file: only in pass 1
    beq @reset
@take:
    lda dcount
    cmp #MAX_ENTRIES
    bcs @reset
    jsr store_entry
    inc dcount
@reset:
    lda #0
    sta lfn_ok
    jmp @next

clear_namebuf:
    ldx #63
    lda #0
@l: sta namebuf,x
    dex
    bpl @l
    rts

; one long-file-name entry at (ptr) -> namebuf
lfn_part:
    ldy #0
    lda (ptr),y
    sta lfn_seq
    and #$40                ; last (= first stored) part starts a new name
    beq @cont
    jsr clear_namebuf
    lda #1
    sta lfn_ok
@cont:
    lda lfn_ok
    beq @done
    lda lfn_seq
    and #$1F
    beq @done
    sec
    sbc #1
    cmp #4                  ; parts 5+ start beyond NAME_MAX
    bcs @done
    sta tmp
    asl
    asl
    sta tmp+1               ; 4s
    asl                     ; 8s
    clc
    adc tmp+1               ; 12s
    clc
    adc tmp                 ; 13s
    sta lfn_pos
    ldx #0
@k: lda lfn_pos
    cmp #NAME_MAX
    bcs @done
    ldy lfn_off,x
    lda (ptr),y             ; low byte of the UTF-16 char
    sta tmp
    iny
    lda (ptr),y             ; high byte
    sta tmp+1
    ora tmp
    beq @store0             ; 0000 = end of name
    lda tmp
    and tmp+1
    cmp #$FF
    beq @skip               ; FFFF = padding
    lda tmp+1
    bne @q                  ; not ASCII
    lda tmp
    cmp #32
    bcc @q
    cmp #127
    bcs @q
    bcc @store
@q: lda #'?'
    bne @store
@store0:
    lda #0
@store:
    ldy lfn_pos
    sta namebuf,y
@skip:
    inc lfn_pos
    inx
    cpx #13
    bne @k
@done:
    rts
lfn_off:
    .byte 1,3,5,7,9,14,16,18,20,22,24,28,30

; directory entry at (ptr) -> record dcount in LIST
store_entry:
    lda dcount
    lsr
    lsr
    clc
    adc #>LIST
    sta rec+1
    lda dcount
    and #3
    lsr
    ror
    ror
    sta rec                 ; (dcount & 3) * 64
    lda lfn_ok
    beq @short
    lda namebuf
    beq @short              ; empty long name: use 8.3
    ldy #0
@lc:
    lda namebuf,y
    sta (rec),y
    iny
    cpy #NAME_MAX+1
    bne @lc
    lda #0
    ldy #NAME_MAX
    sta (rec),y
    jmp @meta
@short:
    ldx #0                  ; destination index
    ldy #0                  ; source index
@n: lda (ptr),y
    cmp #' '
    beq @ext
    sty tmp
    pha
    txa
    tay
    pla
    sta (rec),y
    ldy tmp
    inx
    iny
    cpy #8
    bne @n
@ext:
    ldy #8
    lda (ptr),y
    cmp #' '
    beq @end
    txa
    tay
    lda #'.'
    sta (rec),y
    inx
    ldy #8
@e: lda (ptr),y
    cmp #' '
    beq @end
    sty tmp
    pha
    txa
    tay
    pla
    sta (rec),y
    ldy tmp
    inx
    iny
    cpy #11
    bne @e
@end:
    txa
    tay
    lda #0
    sta (rec),y
@meta:
    ldy #11
    lda (ptr),y
    ldy #REC_ATTR
    sta (rec),y
    ldy #26                 ; cluster low word
    lda (ptr),y
    ldy #REC_CLUS
    sta (rec),y
    ldy #27
    lda (ptr),y
    ldy #REC_CLUS+1
    sta (rec),y
    ldy #20                 ; cluster high word
    lda (ptr),y
    ldy #REC_CLUS+2
    sta (rec),y
    ldy #21
    lda (ptr),y
    ldy #REC_CLUS+3
    sta (rec),y
    ldx #0
@sz:
    txa
    clc
    adc #28
    tay
    lda (ptr),y
    pha
    txa
    clc
    adc #REC_FSIZE
    tay
    pla
    sta (rec),y
    inx
    cpx #4
    bne @sz
    rts

; ------------------------------------------------------------ search
; find_name: 8.3 name in fname (11 bytes) in directory it_clus (0 = root).
; Carry clear: f_clus, f_size, f_attr set. Carry set: A = 0 not found, else error.
find_name:
    jsr dir_open
    bcc @next
    rts
@next:
    jsr dir_next
    bcc @entry
    rts
@entry:
    ldy #11
    lda (ptr),y
    cmp #$0F
    beq @next
    ldy #0
    lda (ptr),y
    cmp #$E5
    beq @next
    ldy #10
@c: lda (ptr),y
    cmp fname,y
    bne @next
    dey
    bpl @c
    ldy #11
    lda (ptr),y
    sta f_attr
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

; ------------------------------------------------------------ file stream
; stream_open: start reading the file at f_clus. Reads the first sector.
stream_open:
    MOV32 st_clus, f_clus
    lda #0
    sta st_sec
    sta st_off
    sta st_off+1
    MOV32 clus, st_clus
    jsr clus_to_lba
    MOV32 st_lba, lba
    jmp sd_read

stream_next_sector:
    inc st_sec
    lda st_sec
    cmp spc
    bne @same
    lda #0
    sta st_sec
    MOV32 clus, st_clus
    jsr next_cluster
    bcc @nc
    cmp #0
    bne @err
    lda #$24                ; chain ended but more data wanted
@err:
    sec
    rts
@nc:
    MOV32 st_clus, clus
    jsr clus_to_lba
    MOV32 st_lba, lba
    jmp @rd
@same:
    INC32 st_lba
@rd:
    lda #0
    sta st_off
    sta st_off+1
    MOV32 lba, st_lba
    jmp sd_read

; stream_copy: copy copy_n (24 bit) bytes from the stream to the sink:
;   sink = 0: PRG RAM window at dst ($4800-$4FFF), page in prg_page (reg $80)
;   sink = 1: PPU data port (address set by the caller)
;   sink = 2: save SRAM window at dst ($6000-$7FFF), page in prg_page (reg $81)
stream_copy:
@loop:
    lda copy_n
    ora copy_n+1
    ora copy_n+2
    bne @more
    clc
    rts
@more:
    lda st_off+1            ; st_off == 512 -> next sector
    cmp #2
    bne @have
    jsr stream_next_sector
    bcc @have
    rts
@have:
    ; chunk = 512 - st_off, max 256
    sec
    lda #0
    sbc st_off
    sta chunk
    lda #2
    sbc st_off+1
    sta chunk+1
    beq @c1                 ; < 256
    lda #0                  ; >= 256 -> 256
    sta chunk
    lda #1
    sta chunk+1
@c1:
    ; chunk = min(chunk, copy_n)
    lda copy_n+2
    bne @c2
    lda copy_n+1
    cmp chunk+1
    bcc @take_n
    bne @c2
    lda copy_n
    cmp chunk
    bcs @c2
@take_n:
    lda copy_n
    sta chunk
    lda copy_n+1
    sta chunk+1
@c2:
    lda sink
    cmp #1
    beq @c3
    ; window sinks: chunk = min(chunk, window end - dst)
    ldx #$50                ; PRG: $5000
    lda sink
    beq @wend
    ldx #$80                ; save SRAM: $8000
@wend:
    stx tmp+2
    sec
    lda #$00
    sbc dst
    sta tmp
    lda tmp+2
    sbc dst+1
    sta tmp+1
    lda tmp+1
    cmp chunk+1
    bcc @take_space
    bne @c3
    lda tmp
    cmp chunk
    bcs @c3
@take_space:
    lda tmp
    sta chunk
    lda tmp+1
    sta chunk+1
@c3:
    ; src = SECBUF + st_off
    clc
    lda #<SECBUF
    adc st_off
    sta src
    lda #>SECBUF
    adc st_off+1
    sta src+1
    ; copy chunk bytes (chunk is 1..256; low byte 0 means 256)
    ldy #0
    lda sink
    cmp #1
    beq @ppu
@prg:
    lda (src),y
    sta (dst),y
    iny
    cpy chunk
    bne @prg
    ; dst += chunk, next page at the window end
    clc
    lda dst
    adc chunk
    sta dst
    lda dst+1
    adc chunk+1
    sta dst+1
    cmp tmp+2
    bne @adv
    inc prg_page
    lda sink
    bne @spage
    lda #$48
    sta dst+1
    lda #FPGA_PRG_PAGE
    sta N8_IDX
    lda prg_page
    sta N8_DAT
    jmp @adv
@spage:
    lda #$60
    sta dst+1
    lda #FPGA_SRAM_PAGE
    sta N8_IDX
    lda prg_page
    sta N8_DAT
    jmp @adv
@ppu:
    lda (src),y
    sta PPUDATA
    iny
    cpy chunk
    bne @ppu
@adv:
    clc
    lda st_off
    adc chunk
    sta st_off
    lda st_off+1
    adc chunk+1
    sta st_off+1
    sec
    lda copy_n
    sbc chunk
    sta copy_n
    lda copy_n+1
    sbc chunk+1
    sta copy_n+1
    lda copy_n+2
    sbc #0
    sta copy_n+2
    jmp @loop
