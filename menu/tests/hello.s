; hello.nes: NROM-256 test game for the n8-open menu.
; Shows that PRG (both 16 KB halves), CHR ROM and the start path work:
;   HELLO FROM NROM
;   PRG $8000=A $C000=B      (wrong PRG mapping shows other letters)
; Mirroring is vertical; the text sits in nametable 0.

PPUCTRL   = $2000
PPUMASK   = $2001
PPUSTATUS = $2002
PPUSCROLL = $2005
PPUADDR   = $2006
PPUDATA   = $2007

.segment "HEADER"
    .byte "NES", $1A, 2, 1, $01, $00, 0,0,0,0,0,0,0,0

.segment "MARK1"            ; first byte of the $8000 half
    .byte "A"

.segment "CODE"             ; second half, $C000-$FFFF
mark2:
    .byte "B"
reset:
    sei
    cld
    ldx #$FF
    txs
    lda #0
    sta PPUCTRL
    sta PPUMASK
@v1: bit PPUSTATUS
    bpl @v1
@v2: bit PPUSTATUS
    bpl @v2
    ; palette
    lda #$3F
    sta PPUADDR
    lda #$00
    sta PPUADDR
    lda #$01                ; dark blue background
    sta PPUDATA
    lda #$30
    sta PPUDATA
    sta PPUDATA
    sta PPUDATA
    ; clear nametable 0
    lda #$20
    sta PPUADDR
    lda #$00
    sta PPUADDR
    ldy #3                  ; 960 tiles ' ' ...
    ldx #0
    lda #' '
@c: sta PPUDATA
    inx
    bne @c
    dey
    bne @c
    ldx #192
@c2: sta PPUDATA
    dex
    bne @c2
    lda #0                  ; ... and attributes 0 (palette 0 everywhere)
    ldx #64
@at: sta PPUDATA
    dex
    bne @at
    ; text
    lda #$21
    sta PPUADDR
    lda #$48
    sta PPUADDR
    ldx #0
@t1: lda text1,x
    beq @t1d
    sta PPUDATA
    inx
    bne @t1
@t1d:
    lda #$21
    sta PPUADDR
    lda #$88
    sta PPUADDR
    ldx #0
@t2: lda text2,x
    beq @t2d
    sta PPUDATA
    inx
    bne @t2
@t2d:
    lda $8000               ; marker of the first PRG half
    sta PPUDATA
    ldx #0
@t3: lda text3,x
    beq @t3d
    sta PPUDATA
    inx
    bne @t3
@t3d:
    lda mark2               ; marker of the second half
    sta PPUDATA
    ; show
@v3: bit PPUSTATUS
    bpl @v3
    lda #0
    sta PPUSCROLL
    sta PPUSCROLL
    sta PPUCTRL
    lda #$0A
    sta PPUMASK
done:
    jmp done
nmi:
    rti

text1: .byte "HELLO FROM NROM", 0
text2: .byte "PRG $8000=", 0
text3: .byte " $C000=", 0

.segment "VECTORS"
    .word nmi, reset, nmi

.segment "CHARS"
    .incbin "../font.chr"
