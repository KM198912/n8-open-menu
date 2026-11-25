; n8-open menu, milestone 2: browse the SD card (folders, long file names),
; load a game (PRG/CHR), load its core from SD into the FPGA, start it.
; Written from docs/hw-interface.md.
;
; Assembler: ca65 (cc65), linker config: os.cfg

.include "hw.inc"

LIST_ROW   = 3
VIS        = 24             ; visible list rows (3..26)
STATUS_ROW = 28
BTN_A      = $80
BTN_B      = $40
BTN_SELECT = $20
BTN_START  = $10
BTN_UP     = $08
BTN_DOWN   = $04
BTN_LEFT   = $02
BTN_RIGHT  = $01

.segment "ZEROPAGE"
ptr:        .res 2
row:        .res 1
col:        .res 1
tmp:        .res 4
lba:        .res 4
arg:        .res 4
r1:         .res 1
sdhc:       .res 1
cardv2:     .res 1
count:      .res 2
part_lba:   .res 4
fat_lba:    .res 4
data_lba:   .res 4
root_clus:  .res 4
clus:       .res 4
spc:        .res 1
spc_shift:  .res 1
boot_ctl:   .res 1
; directory iterator / listing
it_clus:    .res 4
it_lba:     .res 4
it_sec:     .res 1
it_ent:     .res 1
cur_dir:    .res 4
dcount:     .res 1
pass:       .res 1
lfn_ok:     .res 1
lfn_seq:    .res 1
lfn_pos:    .res 1
rec:        .res 2
f_clus:     .res 4          ; f_clus and f_size must stay adjacent
f_size:     .res 4
f_attr:     .res 1
; file stream
st_clus:    .res 4
st_lba:     .res 4
st_sec:     .res 1
st_off:     .res 2
copy_n:     .res 3
chunk:      .res 2
src:        .res 2
dst:        .res 2
sink:       .res 1
prg_page:   .res 1
; loader
rom_clus:   .res 4
dir_edfc:   .res 4
core_num:   .res 1
mapper:     .res 1
cfg_prg:    .res 1
cfg_chr:    .res 1
cfg_map:    .res 1
chr_blk:    .res 1
rem:        .res 2
take:       .res 1
ext_n:      .res 1
ext_off:    .res 1
ext_end:    .res 4
rc_off:     .res 1
rc_cnt:     .res 1
rc_t:       .res 2
rc_n:       .res 2
rc_mem:     .res 1
rc_att:     .res 1          ; load attempt (0 or 1)
rc_order:   .res 1          ; 0 = nCONFIG first, 1 = CMD18 first
rc_sv:      .res 2          ; bytes saved by the $5000 probe
rc_cd0:     .res 1          ; CONF_DONE right after nCONFIG
win0:       .res 1          ; PRG window readback ($8000 / $C000 of the game)
win1:       .res 1
gm:         .res 4          ; game mode reads: $8000, $C000, $FFFC, $FFFD
chr_win:    .res 1          ; CHR $0410 read through the boot core after loading
chr_game:   .res 1          ; CHR $0410 read in game mode (our core)
; user interface
sel:        .res 1
top:        .res 1
joy:        .res 1
joy_prev:   .res 1
joy_new:    .res 1
rep:        .res 1
depth:      .res 1
err:        .res 1
width:      .res 1

; FAT32 writing (fatw.s)
nfats:      .res 1          ; number of FAT copies
fat_size:   .res 4          ; sectors per FAT
fsi_lba:    .res 4          ; FSInfo sector
max_clus:   .res 4          ; cluster count + 2 = first invalid cluster number
fc_lba:     .res 4          ; FAT sector held in SECBUF ...
fc_ok:      .res 1          ; ... if 1 (sd_read clears it)
fp:         .res 2          ; FAT entry in SECBUF
fv:         .res 4          ; FAT entry value
fw_k:       .res 1          ; loop counter (FAT copies, sectors)
al_n:       .res 1          ; clusters wanted
al_got:     .res 1
al_pass:    .res 1
al_start:   .res 4
al_c:       .res 4          ; scan position
al_left:    .res 4          ; clusters left to scan
al_first:   .res 4          ; first allocated cluster
al_prev:    .res 4          ; last allocated cluster
dw_dir:     .res 4          ; directory to add to (0 = root)
de_clus:    .res 4          ; directory slot: cluster, sector LBA, sector in
de_lba:     .res 4          ; the cluster, entry in the sector
de_sec:     .res 1
de_ent:     .res 1
nm:         .res 2          ; long name (0-terminated), nm+1 = 0: none
lfn_len:    .res 1
lfn_n:      .res 1          ; LFN entries
lfn_k:      .res 1
lfn_sum:    .res 1          ; checksum of the 8.3 name
w_attr:     .res 1          ; new entry: attributes, first cluster, size
w_clus:     .res 4
w_size:     .res 4
w_seed:     .res 4          ; sfn_unique: number for the 8.3 name

.segment "BSS"
namebuf:    .res 64
fname:      .res 11
hdr:        .res 16
dirstack:   .res 64
ext_tab:    .res 96

.segment "BSS2"
vol_id:     .res 4          ; volume serial number (BPB $43)
sv_dir:     .res 4          ; /EDFC/SAVE cluster
sv_clus:    .res 4          ; .sav first cluster
sv_last:    .res 4          ; last cluster of a .sav chain (growing it)
sv_elba:    .res 4          ; .sav 8.3 entry: sector ...
sv_eent:    .res 1          ; ... and slot
sv_len:     .res 1
sv_k:       .res 1
sv_n:       .res 1
sv_have:    .res 1
sv_name:    .res 64         ; <rom name>.sav
order:      .res 128        ; list position -> LIST record (sorted, list_sort)
console:    .res 1          ; console region (region.s: RG_NTSC/PAL/DENDY)
gregion:    .res 1          ; region of the selected game
pal_fix:    .res 1          ; 1 = NTSC game on a PAL console: correct
no_fix:     .res 1          ; B was held when A started the game
rg_try:     .res 1
rg_p:       .res 1
rg_s:       .res 1
pt_clen:    .res 1          ; pal_patches: entry fields
pt_poff:    .res 1
pt_plen:    .res 1
pt_pbase:   .res 1
pt_len:     .res 1

.segment "CHARS"
    .incbin "font.chr"

.segment "RODATA"
font:
    .incbin "font.chr"
palette:
    .byte $0F,$30,$10,$00, $0F,$2A,$1A,$00, $0F,$16,$06,$00, $0F,$30,$10,$00

.segment "VECTORS"
    .word nmi, reset, nmi

.segment "CODE"

; ---------------------------------------------------------------- macros
; unnamed labels, so the macro does not end a cheap-local (@) label scope
.macro PRINT str
    lda #<:+
    ldx #>:+
    jsr puts
    jmp :++
:   .byte str, 0
:
.endmacro

.macro MOV32 dst, src
    lda src
    sta dst
    lda src+1
    sta dst+1
    lda src+2
    sta dst+2
    lda src+3
    sta dst+3
.endmacro

.macro ADD32 dst, a1, a2
    clc
    lda a1
    adc a2
    sta dst
    lda a1+1
    adc a2+1
    sta dst+1
    lda a1+2
    adc a2+2
    sta dst+2
    lda a1+3
    adc a2+3
    sta dst+3
.endmacro

; ---------------------------------------------------------------- reset
; MUST stay the first code in the CODE segment: the BIOS enters OS.BIN with
; JMP $8000, it does not use the reset vector.
reset:
    sei
    cld
    ldx #$FF
    txs
    lda #0
    sta PPUCTRL
    sta PPUMASK
    lda #$40
    sta APU_FRAME
    jsr vwait
    jsr vwait

    ldx #CPLD_CTL
    stx N8_IDX
    lda N8_DAT
    sta boot_ctl
    lda #FPGA_SRAM_PAGE     ; $6000 = save SRAM page 8 (menu data, LIST)
    sta N8_IDX
    lda #8
    sta N8_DAT
    jsr region_detect       ; NTSC / PAL / Dendy console (region.s)

    jsr menu_gfx
    lda #0
    sta err
    sta depth
    sta joy_prev
    sta cur_dir
    sta cur_dir+1
    sta cur_dir+2
    sta cur_dir+3

    jsr sd_init
    bcc @sd_ok
    pha
    lda #LIST_ROW
    ldx #2
    jsr gotoxy
    PRINT "SD INIT FAIL "
    jmp stop
@sd_ok:
.ifdef FATW_TEST
    jmp fatw_test           ; test build only (ca65 -D FATW_TEST), see tests/
.endif
.ifdef SDW_TEST
    jmp sdw_test            ; test build only (ca65 -D SDW_TEST), see tests/
.endif
    jsr fat_mount
    bcc @mnt_ok
    pha
    lda #LIST_ROW
    ldx #2
    jsr gotoxy
    PRINT "NO FAT32 VOLUME "
    jmp stop
@mnt_ok:
    jsr save_boot           ; last game's battery save -> SD (save.s)
    jsr open_dir
    jsr redraw

; ---------------------------------------------------------------- main loop
main_loop:
    jsr vwait
    jsr read_joy
    lda joy_prev
    eor #$FF
    and joy
    sta joy_new
    lda joy
    sta joy_prev

    ; up/down with auto-repeat
    lda joy_new
    and #BTN_UP | BTN_DOWN
    bne @new_dir
    lda joy
    and #BTN_UP | BTN_DOWN
    beq @buttons
    dec rep
    bne @buttons
    lda #5
    sta rep
    lda joy
    jmp @move
@new_dir:
    lda #20
    sta rep
    lda joy_new
@move:
    tax
    and #BTN_UP
    beq @down
    jsr cur_up
    jmp @moved
@down:
    txa
    and #BTN_DOWN
    beq @buttons
    jsr cur_down
@moved:
    jsr redraw
    jmp main_loop

@buttons:
    lda joy_new
    and #BTN_LEFT
    beq @r
    jsr page_up
    jsr redraw
    jmp main_loop
@r: lda joy_new
    and #BTN_RIGHT
    beq @a
    jsr page_down
    jsr redraw
    jmp main_loop
@a: lda joy_new
    and #BTN_A | BTN_START
    beq @b
    jsr activate
    jmp main_loop
@b: lda joy_new
    and #BTN_B
    beq @sel
    jsr go_back
    jmp main_loop
@sel:
    lda joy_new
    and #BTN_SELECT
    beq @none
    jsr show_info
@none:
    jmp main_loop

; ---------------------------------------------------------------- actions
cur_up:
    lda sel
    beq @done
    dec sel
    jsr fix_top
@done:
    rts

cur_down:
    lda sel
    clc
    adc #1
    cmp dcount
    bcs @done
    sta sel
    jsr fix_top
@done:
    rts

page_up:
    lda sel
    sec
    sbc #VIS
    bcs @set
    lda #0
@set:
    sta sel
    jmp fix_top

page_down:
    lda dcount
    beq @done
    lda sel
    clc
    adc #VIS
    bcs @last
    cmp dcount
    bcc @set
@last:
    ldx dcount
    dex
    txa
@set:
    sta sel
    jmp fix_top
@done:
    rts

fix_top:
    lda sel
    cmp top
    bcs @below
    sta top
    rts
@below:
    sec
    sbc top
    cmp #VIS
    bcc @ok
    lda sel
    sec
    sbc #VIS-1
    sta top
@ok:
    rts

activate:
    lda dcount
    bne @have
    rts
@have:
    jsr sel_rec
    ldy #REC_ATTR
    lda (rec),y
    and #$10
    beq @file
    ; enter folder
    lda depth
    cmp #16
    bcs @deep
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
    ldy #REC_CLUS
    ldx #0
@c: lda (rec),y
    sta cur_dir,x
    iny
    inx
    cpx #4
    bne @c
    jsr open_dir
    jmp redraw
@deep:
    rts
@file:
    lda #STATUS_ROW         ; "LOADING..." stays on screen while PRG loads;
    ldx #1                  ; the loader turns rendering off (in vblank)
    jsr gotoxy_off          ; before CHR, so the screen changes once, from
    PRINT "LOADING...                    "  ; the text to black - no flashing
    jsr show
    lda joy                 ; B held with A: no NTSC-on-PAL correction
    and #BTN_B
    sta no_fix
    jsr launch              ; returns only on error
    sta err
    jsr menu_gfx
    jmp redraw

; Select: ROM info for the selected file (not for folders)
show_info:
    lda dcount
    beq @done
    jsr sel_rec
    ldy #REC_ATTR
    lda (rec),y
    and #$10
    bne @done
    jsr rom_info
    jsr menu_gfx
    jmp redraw
@done:
    rts

go_back:
    lda depth
    beq @done
    dec depth
    lda depth
    asl
    asl
    tax
    lda dirstack,x
    sta cur_dir
    lda dirstack+1,x
    sta cur_dir+1
    lda dirstack+2,x
    sta cur_dir+2
    lda dirstack+3,x
    sta cur_dir+3
    jsr open_dir
    jmp redraw
@done:
    rts

open_dir:
    lda #0
    sta sel
    sta top
    jsr dir_load
    bcc @ok
    sta err
    lda #0
    sta dcount
    rts
@ok:
    jsr list_sort
    lda #0
    sta err
    rts

; ---------------------------------------------------------------- drawing
; full redraw with rendering off, then show
redraw:
    jsr vwait
    lda #0
    sta PPUMASK
    jsr draw_list
    jsr draw_status
    jmp show

show:
    jsr vwait
    lda PPUSTATUS
    lda #0
    sta PPUSCROLL
    sta PPUSCROLL
    sta PPUCTRL
    lda #$0A
    sta PPUMASK
    rts

draw_list:
    lda #0
    sta tmp+3               ; visible row index
@row:
    lda tmp+3
    clc
    adc #LIST_ROW
    ldx #1
    jsr gotoxy
    lda #0
    sta width
    lda tmp+3
    clc
    adc top
    cmp dcount
    bcs @blank
    pha
    cmp sel
    bne @nocur
    lda #'>'
    bne @cur
@nocur:
    lda #' '
@cur:
    sta PPUDATA
    inc width
    pla
    jsr rec_of
    ldy #0
@nm:
    lda (rec),y
    beq @nm_end
    sta PPUDATA
    inc width
    iny
    cpy #28
    bne @nm
@nm_end:
    ldy #REC_ATTR
    lda (rec),y
    and #$10
    beq @blank
    lda #'/'
    sta PPUDATA
    inc width
@blank:
    lda width
    cmp #30
    bcs @next
    lda #' '
    sta PPUDATA
    inc width
    bne @blank
@next:
    inc tmp+3
    lda tmp+3
    cmp #VIS
    bne @row
    rts

draw_status:
    lda #STATUS_ROW
    ldx #1
    jsr gotoxy
    lda err
    bne @err
    lda dcount
    bne @help
    PRINT "(EMPTY)  B:BACK               "
    rts
@help:
    PRINT "A:OPEN B:BACK SEL:INFO L/R:PG "
    rts
@err:
    PRINT "ERROR "
    lda err
    jsr puthex
    lda #' '
    sta PPUDATA
    ; message text
    ldx #0
@find:
    lda err_codes,x
    beq @nomsg
    cmp err
    beq @msg
    inx
    bne @find
@msg:
    txa
    asl
    tax
    lda err_text,x
    pha
    lda err_text+1,x
    tax
    pla
    jsr puts
    lda err
    cmp #$43
    bne @pad
    lda mapper              ; decimal, right-aligned in 5 like the info screen
    ldx #0                  ; (iNES mapper numbers are decimal everywhere)
    jsr putdec
@pad:
@nomsg:
    ldx #8                  ; clear the rest of the line
    lda #' '
@p: sta PPUDATA
    dex
    bne @p
    rts

err_codes:
    .byte $01,$03,$10,$11,$20,$21,$23,$24,$40,$41,$42,$43,$44,$45,$46,$47,0
err_text:
    .word t01,t03,t10,t11,t20,t21,t23,t24,t40,t41,t42,t43,t44,t45,t46,t47
t01: .byte "SD NO ANSWER",0
t03: .byte "SD INIT TIMEOUT",0
t10: .byte "SD READ REJECTED",0
t11: .byte "SD READ TIMEOUT",0
t20: .byte "NO MBR",0
t21: .byte "NO FAT32",0
t23: .byte "BAD CLUSTER",0
t24: .byte "FILE CUT SHORT",0
t40: .byte "NOT A NES FILE",0
t41: .byte "SIZE NOT SUPPORTED",0
t42: .byte "TRAINER NOT SUPP.",0
t43: .byte "NO CORE: MAPPER",0
t44: .byte "NO EDFC/MAPROUT.BIN",0
t45: .byte "CORE RBF MISSING",0
t46: .byte "RBF FRAGMENTED",0
t47: .byte "RAM CODE TOO BIG",0

; rec = LIST record shown at list position A (through the sorted order)
rec_of:
    tax
    lda order,x
    ; fall through
; rec = LIST record number A (64 bytes each, 4 per page of 256)
rec_addr:
    pha
    lsr
    lsr
    clc
    adc #>LIST
    sta rec+1
    pla
    and #3
    lsr
    ror
    ror
    sta rec
    rts

; list_sort: order = record numbers 0..dcount-1, folders first, then by
; name ignoring case. Insertion sort on the index only (stable: equal names
; keep the directory order); the 64-byte records do not move.
list_sort:
    ldx #0
@init:
    cpx dcount
    beq @sort
    txa
    sta order,x
    inx
    bne @init
@sort:
    lda #1
    sta tmp                 ; i
@outer:
    lda tmp
    cmp dcount
    bcs @done               ; (also dcount 0 or 1)
    tax
    lda order,x
    sta tmp+2               ; key = order[i]
    stx tmp+1               ; j = i
@inner:
    ldx tmp+1
    beq @place
    lda order-1,x
    jsr rec_less            ; key < order[j-1] ?
    bcc @place
    ldx tmp+1
    lda order-1,x
    sta order,x
    dec tmp+1
    jmp @inner
@place:
    ldx tmp+1
    lda tmp+2
    sta order,x
    inc tmp
    jmp @outer
@done:
    rts

; carry set if record tmp+2 sorts before record A (folders first, then the
; name ignoring case). Uses rec, dst, tmp+3.
rec_less:
    jsr rec_addr
    lda rec
    sta dst
    lda rec+1
    sta dst+1
    lda tmp+2
    jsr rec_addr
    ldy #REC_ATTR
    lda (rec),y
    and #$10
    sta tmp+3
    lda (dst),y
    and #$10
    cmp tmp+3
    beq @names
    lda tmp+3               ; one folder, one file: the folder first
    beq @no
    sec
    rts
@names:
    ldy #0
@l: lda (rec),y
    jsr upcase
    sta tmp+3
    lda (dst),y
    jsr upcase
    cmp tmp+3
    bne @r                  ; differ: carry = (b > a) = a sorts first
    lda tmp+3
    beq @no                 ; equal names
    iny
    cpy #NAME_MAX+1
    bne @l
@no:
    clc
@r: rts

; stop with an error code (pushed) shown after the message
stop:
    pla
    jsr puthex
    PRINT " R1 "
    lda r1
    jsr puthex
    jsr show
@h: jmp @h

; ---------------------------------------------------------------- video
menu_gfx:
    jsr vwait               ; rendering off first: VRAM writes while the PPU
    lda #0                  ; renders land at wrong addresses (garbled font
    sta PPUMASK             ; after the info screen, 2026-11-25)
    lda #FPGA_CHR_PAGE      ; $0000-$0FFF = page 0, $1000-$1FFF = page 1
    sta N8_IDX
    lda #1
    sta N8_DAT
    jsr upload_font
    jsr load_palette
    jsr clear_screen
    lda #1
    ldx #2
    jsr gotoxy
    PRINT "N8-OPEN MENU 0.2"
    rts

vwait:
    bit PPUSTATUS
@w: bit PPUSTATUS
    bpl @w
    rts

upload_font:
    lda PPUSTATUS
    lda #$00
    sta PPUADDR
    sta PPUADDR
    lda #<font
    sta ptr
    lda #>font
    sta ptr+1
    ldx #8
    ldy #0
@l: lda (ptr),y
    sta PPUDATA
    iny
    bne @l
    inc ptr+1
    dex
    bne @l
    rts

load_palette:
    lda PPUSTATUS
    lda #$3F
    sta PPUADDR
    lda #$00
    sta PPUADDR
    ldx #0
@l: lda palette,x
    sta PPUDATA
    inx
    cpx #16
    bne @l
    rts

clear_screen:
    lda PPUSTATUS
    lda #$20
    sta PPUADDR
    lda #$00
    sta PPUADDR
    ldy #4
    ldx #0
    lda #' '
@l: sta PPUDATA
    inx
    bne @l
    dey
    bne @l
    lda #$23
    sta PPUADDR
    lda #$C0
    sta PPUADDR
    ldx #64
    lda #0
@a: sta PPUDATA
    dex
    bne @a
    rts

; gotoxy with rendering switched off first (safe at any time)
gotoxy_off:
    pha
    txa
    pha
    jsr vwait
    lda #0
    sta PPUMASK
    pla
    tax
    pla
; A = row, X = column
gotoxy:
    sta row
    stx col
    lda PPUSTATUS
    lda row
    lsr
    lsr
    lsr
    ora #$20
    sta PPUADDR
    lda row
    asl
    asl
    asl
    asl
    asl
    ora col
    sta PPUADDR
    rts

puts:
    sta ptr
    stx ptr+1
    ldy #0
@l: lda (ptr),y
    beq @done
    sta PPUDATA
    iny
    bne @l
@done:
    rts

puthex:
    pha
    lsr
    lsr
    lsr
    lsr
    jsr @digit
    pla
    and #$0F
@digit:
    cmp #10
    bcc @num
    adc #'A'-10-1
    sta PPUDATA
    rts
@num:
    adc #'0'
    sta PPUDATA
    rts

read_joy:
    lda #1
    sta $4016
    lda #0
    sta $4016
    ldx #8
@l: lda $4016
    lsr
    rol joy
    dex
    bne @l
    rts

nmi:
    rti

.include "sd.s"
.include "fat32.s"
.include "fatw.s"
.include "loader.s"
.include "save.s"
.include "region.s"
.include "ramload.s"
.include "rominfo.s"
.ifdef SDW_TEST
.include "sdw_test.s"
.endif
.ifdef FATW_TEST
.include "fatw_test.s"
.endif
