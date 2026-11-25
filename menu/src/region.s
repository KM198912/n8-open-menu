; ======================================================================
; Console and game region; NTSC games on a PAL console.
;
; An NTSC game on a PAL console (vblank ~50 lines longer, fewer CPU cycles
; per line) can lose its status bar split. Two remedies, both only for an
; NTSC game on a PAL console and both skipped when B is held while A starts
; the game:
;   - the core corrects CPU-cycle IRQ timing (VRC IRQ), told by $86 bit 6;
;   - pal_tab: small, verified code patches for games whose own code times
;     out (applied to the PRG in PRG RAM; the ROM file is not changed). An
;     entry applies only if mapper, PRG size and every original byte of its
;     compare block match exactly - a different revision gets no patch.
; ======================================================================

RG_NTSC  = 0
RG_PAL   = 1
RG_MULTI = 2
RG_DENDY = 3

; region_detect: console = RG_NTSC / RG_PAL / RG_DENDY, measured once at
; boot: passes of a 15-cycle loop from one vblank flag to the next (NTSC
; 29780 cycles = ~1985, PAL 33248 = ~2217, Dendy 35464 = ~2364). A missed
; flag ($2002 read race) gives ~4000: measured again, 3 tries, then NTSC.
region_detect:
    lda #3
    sta rg_try
@try:
    jsr vwait
    lda #0
    sta tmp
    sta tmp+1
@l: inc tmp                 ; 5
    bne @s                  ; 3
    inc tmp+1
@s: bit PPUSTATUS           ; 4
    bpl @l                  ; 3
    lda tmp+1               ; >= $0B00 (2816): a flag was missed
    cmp #$0B
    bcc @valid
    dec rg_try
    bne @try
    lda #RG_NTSC
    sta console
    rts
@valid:
    ldx #RG_NTSC
    lda tmp                 ; < 2100: NTSC
    cmp #<2100
    lda tmp+1
    sbc #>2100
    bcc @set
    ldx #RG_PAL
    lda tmp                 ; < 2290: PAL, else Dendy
    cmp #<2290
    lda tmp+1
    sbc #>2290
    bcc @set
    ldx #RG_DENDY
@set:
    stx console
    rts

; game_region: gregion of the ROM in hdr / LIST record rec. NES 2.0: byte
; 12 bits 1:0. iNES: byte 9 bit 0 (only if bytes 12-15 are clean - old
; "DiskDude!" headers have text there), else "(EUROPE)", "(E)" or "(PAL)"
; in the file name -> PAL, else NTSC.
game_region:
    lda hdr+7
    and #$0C
    cmp #$08
    bne @ines
    lda hdr+12
    and #3
    sta gregion
    rts
@ines:
    lda #RG_NTSC
    sta gregion
    lda hdr+12
    ora hdr+13
    ora hdr+14
    ora hdr+15
    bne @name
    lda hdr+9
    and #1
    beq @name
    lda #RG_PAL
    sta gregion
    rts
@name:
    ldx #0
@pat:
    lda rg_pats,x
    beq @done               ; end of the list
    stx rg_p
    jsr name_has
    bcs @pal
    ldx rg_p
@skip:                      ; to the next pattern
    lda rg_pats,x
    inx
    cmp #0
    bne @skip
    beq @pat
@pal:
    lda #RG_PAL
    sta gregion
@done:
    rts

; carry set if the name at (rec) contains the pattern at rg_pats+rg_p
; (upper case, 0-terminated), ignoring case
name_has:
    ldy #0
@start:
    lda (rec),y
    beq @no
    sty rg_s
    ldx rg_p
@c: lda rg_pats,x
    beq @yes
    sta tmp
    lda (rec),y
    jsr upcase
    cmp tmp
    bne @next
    inx
    iny
    bne @c
@next:
    ldy rg_s
    iny
    cpy #NAME_MAX
    bne @start
@no:
    clc
    rts
@yes:
    sec
    rts

rg_pats: .byte "(EUROPE)", 0, "(E)", 0, "(PAL)", 0, 0

; pal_decide: pal_fix = 1 for an NTSC game on a PAL console unless B was
; held at the start (no_fix). Needs hdr and rec (read_header).
pal_decide:
    jsr game_region
    lda #0
    sta pal_fix
    lda console
    cmp #RG_PAL
    bne @r
    lda gregion             ; RG_NTSC = 0
    bne @r
    lda no_fix
    bne @r
    inc pal_fix
@r: rts

; pal_patches: apply the matching pal_tab entries to the PRG in PRG RAM
; (through the $4800 window, 2 KB pages). Entry layout:
;   mapper, PRG size (16 KB units), PRG offset (3 bytes, little endian),
;   clen, compare bytes [clen], poff (into the compare block), plen,
;   patch bytes [plen]; the list ends with mapper $FF. A compare block must
;   not cross a 2 KB page.
pal_patches:
    lda #<pal_tab
    sta src
    lda #>pal_tab
    sta src+1
@entry:
    ldy #0
    lda (src),y
    cmp #$FF
    bne @have
    rts
@have:
    ldy #5
    lda (src),y
    sta pt_clen
    clc
    adc #6
    tay
    lda (src),y
    sta pt_poff
    iny
    lda (src),y
    sta pt_plen
    iny
    sty pt_pbase            ; index of the first patch byte
    tya
    clc
    adc pt_plen
    sta pt_len              ; whole entry (< 256)
    ldy #0
    lda (src),y
    cmp mapper
    bne @next
    iny
    lda (src),y
    cmp hdr+4
    bne @next
    ldy #3                  ; window address $4800 + (offset & $7FF)
    lda (src),y
    and #7
    ora #$48
    sta dst+1
    dey
    lda (src),y
    sta dst
    ldy #4                  ; page = offset >> 11
    lda (src),y
    asl
    asl
    asl
    asl
    asl
    sta tmp
    ldy #3
    lda (src),y
    lsr
    lsr
    lsr
    ora tmp
    ldx #FPGA_PRG_PAGE
    stx N8_IDX
    sta N8_DAT
    ldx #0                  ; every original byte must match
@cmp:
    txa
    clc
    adc #6
    tay
    lda (src),y
    sta tmp
    txa
    tay
    lda (dst),y
    cmp tmp
    bne @next
    inx
    cpx pt_clen
    bne @cmp
    ldx #0
@put:
    txa
    clc
    adc pt_pbase
    tay
    lda (src),y
    sta tmp
    txa
    clc
    adc pt_poff
    tay
    lda tmp
    sta (dst),y
    inx
    cpx pt_plen
    bne @put
@next:
    clc
    lda src
    adc pt_len
    sta src
    bcc @again
    inc src+1
@again:
    jmp @entry

pal_tab:
    ; Castlevania (USA): the sprite-0 wait at $F8C7 gives up after 256
    ; passes (~30 lines) - inside the PAL vblank. "BEQ" -> "NOP NOP": it
    ; waits for the old flag to clear (end of vblank), which always happens.
    .byte 2, 8                          ; UxROM, 128 KB
    .byte $C7, $F8, $01                 ; PRG $1F8C7 = bank 7 $F8C7
    .byte 12, $A2,$00,$E8,$F0,$07,$AD,$02,$20,$29,$40,$D0,$F6
    .byte 3, 2, $EA,$EA                 ; at +3 ($F8CA): F0 07 -> EA EA
    .byte $FF

; info screen: region line (row 13) and the B+A hint (row 16)
info_region:
    jsr game_region
    lda #13
    ldx #INFO_COL
    jsr gotoxy
    PRINT "REGION   "
    lda console
    cmp #RG_PAL
    bne @plain
    lda gregion
    bne @plain
    PRINT "NTSC ON PAL NES: FIX"
    lda #16
    ldx #INFO_COL
    jsr gotoxy
    PRINT "LIST: HOLD B+A = NO FIX"
    rts
@plain:
    lda gregion
    asl
    tax
    lda rg_names,x
    pha
    lda rg_names+1,x
    tax
    pla
    jmp puts
rg_names: .word rgn0, rgn1, rgn2, rgn3
rgn0: .byte "NTSC", 0
rgn1: .byte "PAL", 0
rgn2: .byte "NTSC + PAL", 0
rgn3: .byte "DENDY", 0
