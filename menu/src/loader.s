; Game loader: iNES header, MAPROUT lookup, PRG/CHR loading, FPGA core
; loading from SD and game start.
; Error codes: $40 not an iNES file   $41 size not supported
;              $42 trainer not supported   $43 mapper not in MAPROUT.BIN
;              $44 /EDFC/MAPROUT.BIN missing   $45 core (RBF) missing
;              $46 core file too fragmented   $47 RAM code too large
;              $48/$49 battery save (save.s)

MAX_EXT = 16

.import __RAMCODE_LOAD__, __RAMCODE_RUN__, __RAMCODE_SIZE__

; read_header: iNES header of LIST record `sel` -> hdr, rom_clus, mapper.
; Carry set on error (A = code, $40 = not an iNES file).
; Old "DiskDude!"-style headers have garbage in bytes 7-15: if bytes 12-15
; are not zero (and it is not NES 2.0), the mapper's upper nibble is ignored.
read_header:
    jsr sel_rec
    ldy #REC_CLUS
    ldx #0
@cp:
    lda (rec),y
    sta f_clus,x
    iny
    inx
    cpx #8                  ; cluster + size
    bne @cp
    MOV32 rom_clus, f_clus
    lda f_clus              ; empty file: no cluster
    ora f_clus+1
    ora f_clus+2
    ora f_clus+3
    beq @nothdr
    jsr stream_open
    bcc @hdr
    rts
@hdr:
    ldx #15
@h: lda SECBUF,x
    sta hdr,x
    dex
    bpl @h
    lda hdr
    cmp #'N'
    bne @nothdr
    lda hdr+1
    cmp #'E'
    bne @nothdr
    lda hdr+2
    cmp #'S'
    bne @nothdr
    lda hdr+3
    cmp #$1A
    beq @hdr_ok
@nothdr:
    lda #$40
    sec
    rts
@hdr_ok:
    lda hdr+6
    lsr
    lsr
    lsr
    lsr
    sta mapper
    lda hdr+7
    and #$0C
    cmp #$08                ; NES 2.0: byte 7 is valid
    beq @upper
    lda hdr+12
    ora hdr+13
    ora hdr+14
    ora hdr+15
    bne @done               ; garbage in 12-15: keep the lower nibble only
@upper:
    lda hdr+7
    and #$F0
    ora mapper
    sta mapper
@done:
    clc
    rts

; lookup_core: core_num = MAPROUT.BIN[mapper] ($FF = not supported).
; Carry set if /EDFC/MAPROUT.BIN cannot be read (A = $44 or SD error).
lookup_core:
    jsr find_edfc
    bcc @edfc
    lda #$44
    sec
    rts
@edfc:
    ldx #10
@m: lda name_maprout,x
    sta fname,x
    dex
    bpl @m
    MOV32 it_clus, dir_edfc
    jsr find_name
    bcc @mr
    lda #$44
    sec
    rts
@mr:
    MOV32 clus, f_clus
    jsr clus_to_lba
    jsr sd_read
    bcc @mr_ok
    rts
@mr_ok:
    ldy mapper
    lda SECBUF,y
    sta core_num
    clc
    rts

; launch: start the game in LIST record `sel`. Returns only on error
; (carry set, A = code); CHR pages 0/1 may be overwritten by then.
launch:
    jsr read_header
    bcc @hdr_ok
    rts
@hdr_ok:
    lda hdr+4               ; PRG 16 KB units: 1..32
    beq @badsize
    cmp #33
    bcs @badsize
    lda hdr+5               ; CHR 8 KB units: 0..64
    cmp #65
    bcc @size_ok
@badsize:
    lda #$41
    sec
    rts
@size_ok:
    lda hdr+6
    and #$04
    beq @notrainer
    lda #$42
    sec
    rts
@notrainer:
    ; --- MAPROUT.BIN: mapper -> core number
    jsr lookup_core
    bcc @mr_ok
    rts
@mr_ok:
    lda core_num
    cmp #$FF
    bne @have_core
    lda #$43
    sec
    rts
@have_core:
    ; --- battery save: .sav -> save SRAM page 0, pending record (save.s)
    jsr save_prepare
    bcc @saved
    rts
@saved:

    ; --- /EDFC/MAPS/NNN.RBF
    ldx #10
@mp:
    lda name_maps,x
    sta fname,x
    dex
    bpl @mp
    MOV32 it_clus, dir_edfc
    jsr find_name
    bcc @maps
    lda #$45
    sec
    rts
@maps:
    MOV32 it_clus, f_clus
    jsr core_fname
    jsr find_name
    bcc @rbf
    lda #$45
    sec
    rts
@rbf:
    jsr build_extents
    bcc @ext_ok
    rts
@ext_ok:

    ; --- game data: PRG to PRG RAM, CHR to CHR RAM
    ; (PRG goes through the $4800 window only, so the menu's "LOADING..."
    ; stays visible with rendering on; no PPU access until the CHR part)
    MOV32 f_clus, rom_clus
    jsr stream_open
    bcc @rom
    rts
@rom:
    lda #16                 ; skip the header
    sta st_off
    lda #0
    sta prg_page
    lda #FPGA_PRG_PAGE
    sta N8_IDX
    lda #0
    sta N8_DAT
    lda #$00
    sta dst
    lda #$48
    sta dst+1
    lda #0
    sta sink
    sta copy_n
    lda hdr+4               ; PRG bytes = units * $4000
    and #3
    lsr
    ror
    ror
    sta copy_n+1
    lda hdr+4
    lsr
    lsr
    sta copy_n+2
    jsr stream_copy
    bcc @prg_done
    rts
@prg_done:
    lda #FPGA_PRG_PAGE      ; diagnostics: read back game $8000 and $C000
    sta N8_IDX
    lda #0
    sta N8_DAT
    lda $4800
    sta win0
    lda #8
    sta N8_DAT
    lda $4800
    sta win1
    ; rendering off from here on (CHR via PPUDATA, then the FPGA is
    ; reconfigured): one change from the text to the black backdrop,
    ; switched in vblank so no half-drawn frame shows
    jsr vwait
    lda #0
    sta PPUMASK
    lda hdr+5
    beq @chr_done
    lda #0
    sta chr_blk             ; 8 KB block counter
@chr:
    lda chr_blk             ; CHR page = 2 * block + 1 -> PPU $0000-$1FFF
    asl
    clc
    adc #1
    ldx #FPGA_CHR_PAGE
    stx N8_IDX
    sta N8_DAT
    lda PPUSTATUS
    lda #0
    sta PPUADDR
    sta PPUADDR
    lda #1
    sta sink
    lda #0
    sta copy_n
    sta copy_n+2
    lda #$20
    sta copy_n+1
    jsr stream_copy
    bcc @chr_next
    rts
@chr_next:
    inc chr_blk
    lda chr_blk
    cmp hdr+5
    bne @chr
@chr_done:
    lda #FPGA_CHR_PAGE      ; diagnostics: CHR byte $0410 of block 0
    sta N8_IDX
    lda #1
    sta N8_DAT
    lda PPUSTATUS
    lda #$04
    sta PPUADDR
    lda #$10
    sta PPUADDR
    lda PPUDATA             ; buffered read: first one is stale
    lda PPUDATA
    sta chr_win

    ; --- core register values
    ldx hdr+4
    dex
    txa
    and #$1F
    sta cfg_prg
    lda hdr+5
    beq @chr_ram
    sec
    sbc #1
    and #$3F
    jmp @chr_set
@chr_ram:
    lda #$80                ; bit 7: CHR RAM
@chr_set:
    sta cfg_chr
    lda hdr+6
    and #$01                ; 1 = vertical mirroring
    sta cfg_map

    ; --- copy the RAM part and run it (never returns)
    lda #<__RAMCODE_SIZE__
    ldx #>__RAMCODE_SIZE__
    cpx #4                  ; RAMC in os.cfg: $0300-$06FF
    bcc @size_ok2
    lda #$47
    sec
    rts
@size_ok2:
    lda #<__RAMCODE_LOAD__
    sta src
    lda #>__RAMCODE_LOAD__
    sta src+1
    lda #<__RAMCODE_RUN__
    sta dst
    lda #>__RAMCODE_RUN__
    sta dst+1
    ldy #0
    ldx #5                  ; copy 1.25 KB (whole RAM code area)
@rc:
    lda (src),y
    sta (dst),y
    iny
    bne @rc
    inc src+1
    inc dst+1
    dex
    bne @rc
    jmp rc_entry

; rec = LIST record of list position `sel` (sorted order, see rec_of)
sel_rec:
    lda sel
    jmp rec_of

; dir_edfc = cluster of /EDFC. Carry set if missing.
find_edfc:
    ldx #10
@l: lda name_edfc,x
    sta fname,x
    dex
    bpl @l
    lda #0
    sta it_clus
    sta it_clus+1
    sta it_clus+2
    sta it_clus+3
    jsr find_name
    bcs @done
    MOV32 dir_edfc, f_clus
@done:
    rts

; fname = "NNN     RBF" from core_num (decimal)
core_fname:
    ldx #10
@l: lda name_rbf,x
    sta fname,x
    dex
    bpl @l
    lda core_num
    ldx #0
@h: cmp #100
    bcc @t
    sbc #100
    inx
    bne @h
@t: pha
    txa
    ora #'0'
    sta fname
    pla
    ldx #0
@tt:
    cmp #10
    bcc @o
    sbc #10
    inx
    bne @tt
@o: ora #'0'
    sta fname+2
    txa
    ora #'0'
    sta fname+1
    rts

name_edfc:    .byte "EDFC       "
name_maprout: .byte "MAPROUT BIN"
name_maps:    .byte "MAPS       "
name_rbf:     .byte "000     RBF"

; build_extents: sector runs of the RBF file (f_clus, f_size) in ext_tab as
; (card address 4 bytes, sector count 2 bytes). ext_n = number of runs.
build_extents:
    ; sectors needed = (size + 511) / 512
    clc
    lda f_size
    adc #<511
    lda f_size+1
    adc #>511
    sta rem
    lda f_size+2
    adc #0
    sta rem+1
    lsr rem+1               ; >> 9 = (bytes 1..2) >> 1
    ror rem
    lda #0
    sta ext_n
    MOV32 clus, f_clus
@clus:
    jsr clus_to_lba
    ; take = min(spc, rem)
    lda rem+1
    bne @full
    lda rem
    cmp spc
    bcs @full
    sta take
    jmp @t
@full:
    lda spc
    sta take
@t:
    lda ext_n
    beq @new
    ; contiguous with the current run?
    lda lba
    cmp ext_end
    bne @new
    lda lba+1
    cmp ext_end+1
    bne @new
    lda lba+2
    cmp ext_end+2
    bne @new
    lda lba+3
    cmp ext_end+3
    bne @new
    ldx ext_off
    clc
    lda ext_tab+4,x
    adc take
    sta ext_tab+4,x
    lda ext_tab+5,x
    adc #0
    sta ext_tab+5,x
    jmp @end_upd
@new:
    lda ext_n
    cmp #MAX_EXT
    bcc @room
    lda #$46
    sec
    rts
@room:
    asl                     ; offset = n * 6
    sta ext_off
    asl
    clc
    adc ext_off
    sta ext_off
    tax
    lda lba
    sta ext_tab,x
    lda lba+1
    sta ext_tab+1,x
    lda lba+2
    sta ext_tab+2,x
    lda lba+3
    sta ext_tab+3,x
    lda take
    sta ext_tab+4,x
    lda #0
    sta ext_tab+5,x
    inc ext_n
    MOV32 ext_end, lba
@end_upd:
    clc
    lda ext_end
    adc take
    sta ext_end
    lda ext_end+1
    adc #0
    sta ext_end+1
    lda ext_end+2
    adc #0
    sta ext_end+2
    lda ext_end+3
    adc #0
    sta ext_end+3
    sec
    lda rem
    sbc take
    sta rem
    lda rem+1
    sbc #0
    sta rem+1
    ora rem
    beq @convert
    jsr next_cluster
    bcs @chain_end
    jmp @clus
@chain_end:
    cmp #0
    bne @err
    lda #$24
@err:
    sec
    rts
@convert:
    ; LBAs -> card addresses (SDSC: bytes)
    lda #0
    sta tmp+3               ; run index
@cv:
    lda tmp+3               ; X = index * 6
    asl
    sta tmp+2
    asl
    clc
    adc tmp+2
    tax
    lda ext_tab,x
    sta lba
    lda ext_tab+1,x
    sta lba+1
    lda ext_tab+2,x
    sta lba+2
    lda ext_tab+3,x
    sta lba+3
    jsr sd_lba_to_arg       ; uses A only
    lda arg
    sta ext_tab,x
    lda arg+1
    sta ext_tab+1,x
    lda arg+2
    sta ext_tab+2,x
    lda arg+3
    sta ext_tab+3,x
    inc tmp+3
    lda tmp+3
    cmp ext_n
    bne @cv
    clc
    rts

