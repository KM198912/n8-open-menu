; vrc6_tone.nes: VRC6 (mapper 24) audio test ROM for n8-open.
; Steps through eight parts, 2 s each (100 frames), name on screen:
;   1  2A03 PULSE 440 HZ        2  VRC6 PULSE 440 HZ
;   3  2A03 PULSE 110 HZ        4  VRC6 PULSE 110 HZ
;   5  2A03 PULSE  55 HZ        6  VRC6 PULSE  55 HZ
;   7  VRC6 SAWTOOTH 55 HZ      8  SILENCE
; Pulses: duty 50%, full volume. At full volume the VRC6 pulse should be
; about as loud as the 2A03 pulse (NESdev wiki: VRC6 audio); comparing each
; pair in a recording gives the level ratio and, over the three pitches, the
; frequency response of the cartridge audio path. Frequencies are NTSC
; (CPU 1.789773 MHz); on PAL they are ~7% lower, the same for both chips.
; Written for mapper 24 (VRC6a): register addresses $x000-$x003 as is.

PPUCTRL   = $2000
PPUMASK   = $2001
PPUSTATUS = $2002
PPUSCROLL = $2005
PPUADDR   = $2006
PPUDATA   = $2007

PARTS = 8

.zeropage
part:   .res 1
frames: .res 1
ptr:    .res 2
plo:    .res 1              ; period of the current part
phi:    .res 1

.segment "HEADER"
    .byte "NES", $1A, 2, 1, $80, $10, 0,0,0,0,0,0,0,0   ; mapper 24, 32K PRG, 8K CHR

.segment "CODE"             ; fixed last 8 KB ($E000-$FFFF)
reset:
    sei
    cld
    ldx #$FF
    txs
    lda #0
    sta PPUCTRL
    sta PPUMASK
    jsr silence
    lda #$00
    sta $9003               ; no halt, no frequency shift (as the games do)
    lda #$00                ; CHR: 1 KB banks 0/1 = the font (tiles 0-127)
    sta $D000
    lda #$01
    sta $D001
    lda #$20                ; vertical mirroring, PPU mode 0
    sta $B003
@v1: bit PPUSTATUS
    bpl @v1
@v2: bit PPUSTATUS
    bpl @v2
    lda #$3F                ; palette: dark blue, white text
    sta PPUADDR
    lda #$00
    sta PPUADDR
    lda #$01
    sta PPUDATA
    lda #$30
    sta PPUDATA
    sta PPUDATA
    sta PPUDATA
    lda #$20                ; clear nametable 0
    sta PPUADDR
    lda #$00
    sta PPUADDR
    ldy #4
    ldx #0
    lda #' '
@c: sta PPUDATA
    inx
    bne @c
    dey
    bne @c
    lda #$23                ; attributes 0
    sta PPUADDR
    lda #$C0
    sta PPUADDR
    lda #0
    ldx #64
@at: sta PPUDATA
    dex
    bne @at
    lda #<title
    ldx #>title
    ldy #$84                ; row 4 ($2084)
    jsr line
    lda #<hint
    ldx #>hint
    ldy #$C4                ; row 6 ($20C4)
    jsr line
    lda #0
    sta part

next:
    jsr silence
    lda part                ; table entry: routine (2 bytes), period (2 bytes)
    asl
    asl
    tax
    lda parts,x
    sta ptr
    lda parts+1,x
    sta ptr+1
    lda parts+2,x
    sta plo
    lda parts+3,x
    sta phi
    jsr @call
    lda part                ; its name on row 12 ($2184), names 32 bytes apart
    asl
    asl
    asl
    asl
    asl
    clc
    adc #<names
    pha
    lda #>names
    adc #0
    tax
    pla
    ldy #$84
    jsr show_name
    lda #100
    sta frames
@f: bit PPUSTATUS
    bpl @f
    dec frames
    bne @f
    lda part
    clc
    adc #1
    cmp #PARTS
    bcc @keep
    lda #0
@keep:
    sta part
    jmp next
@call:
    jmp (ptr)

; A/X = 0-terminated text, Y = low byte of the address in $20xx (rendering off)
line:
    sta ptr
    stx ptr+1
    lda #$20
    sta PPUADDR
    sty PPUADDR
    ldy #0
@l: lda (ptr),y
    beq @d
    sta PPUDATA
    iny
    bne @l
@d: rts

; A/X = name (0-terminated), written to $21xx in vblank, then rendering on
show_name:
    sta ptr
    stx ptr+1
@v: bit PPUSTATUS
    bpl @v
    lda #$21
    sta PPUADDR
    sty PPUADDR
    ldy #0
@l: lda (ptr),y
    beq @d
    sta PPUDATA
    iny
    bne @l
@d: lda #0
    sta PPUSCROLL
    sta PPUSCROLL
    sta PPUCTRL
    lda #$0A
    sta PPUMASK
    rts

silence:
    lda #$00
    sta $4015               ; 2A03 channels off
    sta $9002               ; VRC6 pulse 1, pulse 2, saw off
    sta $A002
    sta $B002
    rts

start_apu:                  ; 2A03 pulse 1: duty 50%, constant volume 15
    lda #$01                ; enable first: while a channel is disabled the
    sta $4015               ; 2A03 ignores the length counter load ($4003)
    lda #$BF                ; duty 50%, length counter halted, constant vol 15
    sta $4000
    lda #$00
    sta $4001               ; no sweep
    lda plo
    sta $4002
    lda phi                 ; period high (3 bits) + length index 1
    ora #$08
    sta $4003
    rts
start_vrc6p:                ; VRC6 pulse 1: D = 7 (8/16 = 50%), volume 15
    lda #$7F
    sta $9000
    lda plo
    sta $9001
    lda phi
    ora #$80                ; enable
    sta $9002
    rts
start_saw:                  ; VRC6 saw: rate 42 (top without wrapping)
    lda #42
    sta $B000
    lda plo
    sta $B001
    lda phi
    ora #$80
    sta $B002
    rts
start_none:
    rts

; period for f: pulses CPU / (16 (t + 1)), saw CPU / (14 (t + 1)),
; CPU = 1789773 Hz (NTSC)
parts:
    .word start_apu,   253      ; 440 Hz
    .word start_vrc6p, 253
    .word start_apu,   1016     ; 110 Hz
    .word start_vrc6p, 1016
    .word start_apu,   2033     ;  55 Hz (2A03: 11 bits, fits)
    .word start_vrc6p, 2033
    .word start_saw,   2323     ;  55 Hz
    .word start_none,  0

title: .byte "N8-OPEN VRC6 AUDIO TEST", 0
hint:  .byte "RECORD ME: 8 PARTS, 2 S EACH", 0
names:                      ; 26 characters + 0, padded to 32 bytes
    .byte "1  2A03 PULSE    440 HZ   ", 0, 0,0,0,0,0
    .byte "2  VRC6 PULSE    440 HZ   ", 0, 0,0,0,0,0
    .byte "3  2A03 PULSE    110 HZ   ", 0, 0,0,0,0,0
    .byte "4  VRC6 PULSE    110 HZ   ", 0, 0,0,0,0,0
    .byte "5  2A03 PULSE     55 HZ   ", 0, 0,0,0,0,0
    .byte "6  VRC6 PULSE     55 HZ   ", 0, 0,0,0,0,0
    .byte "7  VRC6 SAWTOOTH  55 HZ   ", 0, 0,0,0,0,0
    .byte "8  SILENCE                ", 0, 0,0,0,0,0
nmi:
    rti

.segment "VECTORS"
    .word nmi, reset, nmi

.segment "CHARS"
    .incbin "../font.chr"
