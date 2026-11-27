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
is_fds:     .res 1          ; 1 = the game is an FDS image (RAM code uploads tables)
cpld_or:    .res 1          ; CPLD $09 bits set at game start ($10, FDS $14)
fds_off:    .res 1          ; FDS: 16 = fwNES header, 0 = none
fds_sides:  .res 1
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
old_sel:    .res 1          ; cursor / first visible row before a move
old_top:    .res 1
err:        .res 1
width:      .res 1
pop_sel:    .res 1          ; popup: highlighted item (0-2)
mi_n:       .res 1          ; mapinfo.s: number of mappers
mi_i:       .res 1          ; mapinfo.s: MAPROUT entry

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
fds_size:   .res 4          ; fds.s: size of the .fds file
fp_t:       .res 4          ; fds.s: side count / table building
fp_n:       .res 1
fp_p:       .res 2
fp_q:       .res 2
fp_e:       .res 1
fp_have:    .res 1
fp_size:    .res 2
fp_len:     .res 2

.segment "CHARS"
    .incbin "font.chr"

.segment "RODATA"
font:
    .incbin "font.chr"
; BG palette 0: the list (font colour 1); 1 and 2: the popup box (box font:
; colour 2 = grey background, colour 3 = text: white / yellow = highlighted).
; Colour 1 stays white in all three, so list text under a box attribute
; looks unchanged until the box tiles replace it.
palette:
    .byte $0F,$30,$10,$00, $0F,$30,$00,$30, $0F,$30,$00,$28, $0F,$30,$10,$00

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
    jsr poll_joy

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
    jsr keep_pos
    txa
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
    jsr update_list
    jmp main_loop

@buttons:
    lda joy_new
    and #BTN_LEFT
    beq @r
    jsr keep_pos
    jsr page_up
    jsr update_list
    jmp main_loop
@r: lda joy_new
    and #BTN_RIGHT
    beq @a
    jsr keep_pos
    jsr page_down
    jsr update_list
    jmp main_loop
@a: lda joy_new
    and #BTN_A
    beq @st
    jsr activate
    jmp main_loop
@st:
    lda joy_new
    and #BTN_START
    beq @b
    jsr lg_start            ; the stored game (lastgame.s)
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
    jsr map_info            ; SUPPORTED MAPPERS (mapinfo.s)
@none:
    jmp main_loop

; next frame: joy = buttons held, joy_new = pressed since the last call
poll_joy:
    jsr vwait
    jsr read_joy
    lda joy_prev
    eor #$FF
    and joy
    sta joy_new
    lda joy
    sta joy_prev
    rts

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
    bne @folder
    jmp popup               ; file: the file menu (SELECT + LOAD starts it)
@folder:
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

; start the selected file (sel)
start_file:
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

; ---------------------------------------------------------------- popup
; A on a file: a box over the list (FILE MENU) with SELECT + LOAD,
; SELECT ONLY, ROM INFO. Up/Down moves the highlight, A confirms, B closes.
; Drawn and removed with rendering on, a few rows per vblank (no black
; frame). The box covers columns 8-23, rows 4-19: whole attribute bytes, so
; palettes 1/2 colour it exactly; each item has its own 2-row band.
BOX_COL  = 8
BOX_ROW  = 4
BOX_W    = 16
BOX_H    = 16
BOX_ITEM = 10               ; row of item 0; items 2 rows apart
BOX_ROWS_PF = 4             ; box rows per vblank (~310 cycles each)

popup:
    lda dcount
    beq @done
    jsr sel_rec
    ldy #REC_ATTR
    lda (rec),y
    and #$10
    bne @done               ; folders: no menu
    lda #0
    sta pop_sel
    jsr box_open
@loop:
    jsr poll_joy
    lda joy_new
    and #BTN_UP
    beq @dn
    lda pop_sel
    beq @loop
    dec pop_sel
    jsr box_hl
    jmp @loop
@dn:
    lda joy_new
    and #BTN_DOWN
    beq @b
    lda pop_sel
    cmp #2
    beq @loop
    inc pop_sel
    jsr box_hl
    jmp @loop
@b:
    lda joy_new
    and #BTN_B
    beq @a
    jmp box_close
@a:
    lda joy_new
    and #BTN_A
    beq @loop
    lda pop_sel
    beq @load
    cmp #1
    beq @only
    jsr rom_info
    jsr menu_gfx
    jmp redraw
@load:
    jsr lg_store            ; SELECT + LOAD (lastgame.s)
    jmp start_file
@only:
    jsr lg_store            ; SELECT ONLY: store, close, show START: <name>
    jsr box_close
    jsr vwait
    jsr lg_draw
    jmp fix_scroll
@done:
    rts

; box attributes for pop_sel, then the box rows
box_open:
    jsr vwait
    jsr box_attr
    jsr fix_scroll
    lda #0
    sta tmp+3               ; box row
@frame:
    jsr vwait
    lda #BOX_ROWS_PF
    sta tmp+2
@r: jsr box_row
    inc tmp+3
    lda tmp+3
    cmp #BOX_H
    beq @end
    dec tmp+2
    bne @r
    jsr fix_scroll
    jmp @frame
@end:
    jmp fix_scroll

; new highlight: the 4 attribute bytes of the item bands, in vblank
box_hl:
    jsr vwait
    jsr box_attr
    jmp fix_scroll

; attribute bytes of the box (rows 4-19 = attribute rows 1-4, columns 8-23
; = attribute columns 2-5); quadrants: 1 = box, 2 = highlighted item band
box_attr:
    ldx #0                  ; attribute row 1..4 -> X = 0..3
@row:
    lda #$55                ; rows 4-7, 16-19: plain box
    cpx #1
    bne @r2
    lda #$55                ; rows 8-11: top half box, bottom half = item 0
    ldy pop_sel
    bne @put
    lda #$A5
    bne @put
@r2:
    cpx #2
    bne @put
    lda #$55                ; rows 12-15: top = item 1, bottom = item 2
    ldy pop_sel
    cpy #1
    bne :+
    lda #$5A
:   cpy #2
    bne @put
    lda #$A5
@put:
    sta tmp                 ; 4 bytes at $23C0 + (X + 1) * 8 + 2
    lda PPUSTATUS
    lda #$23
    sta PPUADDR
    txa
    asl
    asl
    asl
    clc
    adc #$C0 + 8 + 2
    sta PPUADDR
    lda tmp
    sta PPUDATA
    sta PPUDATA
    sta PPUDATA
    sta PPUDATA
    inx
    cpx #4
    bne @row
    rts

; box row tmp+3: 16 tiles of the box font (character + $80)
box_row:
    lda tmp+3
    clc
    adc #BOX_ROW
    ldx #BOX_COL
    jsr gotoxy
    ldx tmp+3
    lda box_lo,x
    sta ptr
    lda box_hi,x
    sta ptr+1
    ldy #0
@c: lda (ptr),y
    ora #$80
    sta PPUDATA
    iny
    cpy #BOX_W
    bne @c
    rts

; close: list rows under the box drawn again (whole rows, 2 per vblank),
; then the attributes back to palette 0
box_close:
    lda #BOX_ROW - LIST_ROW
    sta tmp+3
@frame:
    jsr vwait
    ldx #2
    stx tmp+2
@r: jsr draw_row
    inc tmp+3
    lda tmp+3
    cmp #BOX_ROW - LIST_ROW + BOX_H
    beq @attr
    dec tmp+2
    bne @r
    jsr fix_scroll
    jmp @frame
@attr:
    jsr fix_scroll
    jsr vwait
    ldx #0
@a: lda PPUSTATUS
    lda #$23
    sta PPUADDR
    txa
    asl
    asl
    asl
    clc
    adc #$C0 + 8 + 2
    sta PPUADDR
    lda #0
    sta PPUDATA
    sta PPUDATA
    sta PPUDATA
    sta PPUDATA
    inx
    cpx #4
    bne @a
    jmp fix_scroll

; box contents, one 16-character row each (BOX_ITEM = row 10 -> box row 6)
box_lo:
    .byte <bx_blank, <bx_title, <bx_line, <bx_blank, <bx_blank, <bx_blank
    .byte <bx_load, <bx_blank, <bx_only, <bx_blank, <bx_info, <bx_blank
    .byte <bx_blank, <bx_blank, <bx_blank, <bx_blank
box_hi:
    .byte >bx_blank, >bx_title, >bx_line, >bx_blank, >bx_blank, >bx_blank
    .byte >bx_load, >bx_blank, >bx_only, >bx_blank, >bx_info, >bx_blank
    .byte >bx_blank, >bx_blank, >bx_blank, >bx_blank
bx_blank: .byte "                "
bx_title: .byte "   FILE MENU    "
bx_line:  .byte "----------------"
bx_load:  .byte " SELECT + LOAD  "
bx_only:  .byte "  SELECT ONLY   "
bx_info:  .byte "    ROM INFO    "

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
; Cursor moves and page changes keep the picture on (a black frame per
; step was visible as flicker): within the page only the '>' moves, in
; vblank; when the page scrolls, the rows are redrawn a few per vblank.
keep_pos:
    lda sel
    sta old_sel
    lda top
    sta old_top
    rts

update_list:
    lda sel
    cmp old_sel
    beq @same
    lda top
    cmp old_top
    bne draw_list_live
    ; '>' off the old row, onto the new one: 2 bytes, in vblank
    jsr vwait
    lda old_sel
    sec
    sbc top
    clc
    adc #LIST_ROW
    ldx #1
    jsr gotoxy
    lda #' '
    sta PPUDATA
    lda sel
    sec
    sbc top
    clc
    adc #LIST_ROW
    ldx #1
    jsr gotoxy
    lda #'>'
    sta PPUDATA
    jmp fix_scroll
@same:
    rts

; draw_list_live: all list rows with rendering on, LIVE_ROWS per vblank
; (a row is ~800 cycles; NTSC/Dendy vblank 2273 cycles: 2 rows; PAL 7459:
; 6 rows)
draw_list_live:
    lda #0
    sta tmp+3
@frame:
    jsr vwait
    ldx #2
    lda console
    cmp #RG_PAL
    bne @n
    ldx #6
@n: stx tmp+2
@r: jsr draw_row
    inc tmp+3
    lda tmp+3
    cmp #VIS
    beq fix_scroll
    dec tmp+2
    bne @r
    jsr fix_scroll
    jmp @frame

; after PPUADDR writes with rendering on: scroll back to 0,0
fix_scroll:
    lda #0
    sta PPUSCROLL
    sta PPUSCROLL
    sta PPUCTRL
    rts

; full redraw with rendering off, then show
redraw:
    jsr vwait
    lda #0
    sta PPUMASK
    jsr draw_list
    jsr draw_status
    jsr lg_draw
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
    jsr draw_row
    inc tmp+3
    lda tmp+3
    cmp #VIS
    bne @row
    rts

; draw_row: list row tmp+3 (cursor, name, '/' for folders, padding)
draw_row:
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
    PRINT "A:MENU B:BACK SEL:MAPS L/R:PG "
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
    lda mapper
    cmp #$FE                ; FDS image: MAPROUT.BIN entry $FE
    bne @dec
    PRINT "  FDS"
    jmp @pad
@dec:
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
    .byte $01,$03,$10,$11,$20,$21,$23,$24,$40,$41,$42,$43,$44,$45,$46,$47
    .byte $48,$4A,$4B,$4C,$50,$51,$52,$53,0
err_text:
    .word t01,t03,t10,t11,t20,t21,t23,t24,t40,t41,t42,t43,t44,t45,t46,t47
    .word t48,t4A,t4B,t4C,t50,t51,t52,t53
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
t48: .byte "SAVE STILL PENDING",0
t4A: .byte "SAVE: OTHER CARD",0
t4B: .byte "SAVE FILE CHANGED",0
t4C: .byte "LAST GAME NOT FOUND",0
t50: .byte "NO EDFC/DISKSYS.ROM",0
t51: .byte "UNKNOWN FDS BIOS",0
t52: .byte "NOT AN FDS IMAGE",0
t53: .byte "FDS: MAX 4 SIDES",0

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

; tiles $00-$7F: the font (colour 1 on the backdrop); tiles $80-$FF: the
; box font, made from it here - the same glyph in plane 0, plane 1 all set:
; text in colour 3 on colour 2 (the popup's grey)
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
    lda #<font              ; PPU address is $0800 now
    sta ptr
    lda #>font
    sta ptr+1
    ldx #128
@t: ldy #0
@p0:
    lda (ptr),y
    sta PPUDATA
    iny
    cpy #8
    bne @p0
    lda #$FF
@p1:
    sta PPUDATA
    dey
    bne @p1
    lda ptr
    clc
    adc #16
    sta ptr
    bcc :+
    inc ptr+1
:   dex
    bne @t
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
.include "fds.s"
.include "save.s"
.include "region.s"
.include "ramload.s"
.include "rominfo.s"
.include "lastgame.s"
.include "mapinfo.s"
.ifdef SDW_TEST
.include "sdw_test.s"
.endif
.ifdef FATW_TEST
.include "fatw_test.s"
.endif
