; n8-open: FAT32 write test (stage 2 of battery saves), simulator only.
; Build: ca65 -D FATW_TEST [-D FT_COUNT=n] -I tests -o build/fatw.o src/main.s
; Creates /EDFC/SAVE if missing, then FT_COUNT files of 8 KB with long names
; (fixed names first, then "Generated save file name number NN.sav").
; The first byte of each file is set to its number (1, 2, ...) so a checker
; can see that the entry points at the right clusters.
; Prints "FATW OK nn" or the failing step and error code, then stops.

.ifndef FT_COUNT
FT_COUNT = 4
.endif
.ifndef FT_BASE                 ; first file number (second run: names differ,
FT_BASE = 0                     ; the 8.3 seeds collide on purpose)
.endif

fatw_test:
    jsr fat_mount
    bcc @mounted
    ldx #'M'
    jmp ft_fail
@mounted:
    ldx #10                     ; /EDFC
@e: lda ft_edfc,x
    sta fname,x
    dex
    bpl @e
    lda #0
    sta it_clus
    sta it_clus+1
    sta it_clus+2
    sta it_clus+3
    jsr find_name
    bcc @edfc
    ldx #'E'
    jmp ft_fail
@edfc:
    MOV32 dir_edfc, f_clus
    ldx #10                     ; /EDFC/SAVE, created if missing
@s: lda ft_save,x
    sta fname,x
    dex
    bpl @s
    MOV32 it_clus, dir_edfc
    jsr find_name
    bcc @have_save
    cmp #0
    beq @mkdir
    ldx #'S'
    jmp ft_fail
@mkdir:
    MOV32 dw_dir, dir_edfc
    jsr dir_create
    bcc @made
    ldx #'D'
    jmp ft_fail
@made:
    MOV32 f_clus, w_clus
@have_save:
    MOV32 cur_dir, f_clus       ; (cur_dir: free in this test build)

    lda #0
    sta sel                     ; file number - 1
@file:
    jsr ft_name
    lda #<namebuf
    sta nm
    lda #>namebuf
    sta nm+1
    MOV32 dw_dir, cur_dir
    lda sel                     ; 8.3 name from $00AB0000 + number
    sta w_seed
    lda #0
    sta w_seed+1
    lda #$AB
    sta w_seed+2
    lda #0
    sta w_seed+3
    jsr sfn_unique
    bcc @sfn
    ldx #'U'
    jmp ft_fail
@sfn:
    lda #0
    sta w_size
    sta w_size+2
    sta w_size+3
    lda #$20                    ; 8 KB
    sta w_size+1
    jsr file_create
    bcc @created
    ldx #'C'
    jmp ft_fail
@created:
    jsr clear_secbuf            ; marker: first byte = number
    lda sel
    clc
    adc #FT_BASE+1
    sta SECBUF
    MOV32 clus, w_clus
    jsr clus_to_lba
    jsr sd_write
    bcc @marked
    ldx #'W'
    jmp ft_fail
@marked:
    inc sel
    lda sel
    cmp #FT_COUNT
    beq @all
    jmp @file
@all:
    lda #LIST_ROW
    ldx #2
    jsr gotoxy_off
    PRINT "FATW OK "
    lda sel
    jsr puthex
    jmp ft_stop

; X = step letter, A = error code
ft_fail:
    pha
    txa
    pha
    lda #LIST_ROW
    ldx #2
    jsr gotoxy_off
    PRINT "FATW FAIL "
    pla
    sta PPUDATA
    lda #' '
    sta PPUDATA
    pla
    jsr puthex
ft_stop:
    jsr show
@h: jmp @h

; namebuf = name of file sel + FT_BASE (0-terminated)
ft_name:
    lda sel
    clc
    adc #FT_BASE
    sta tmp+3
    cmp #3
    bcs @gen
    asl
    tax
    lda ft_fixed,x
    sta ptr
    lda ft_fixed+1,x
    sta ptr+1
    ldy #0
@c: lda (ptr),y
    sta namebuf,y
    beq @done
    iny
    bne @c
@done:
    rts
@gen:
    ldy #0
@g: lda ft_gen,y
    beq @num
    sta namebuf,y
    iny
    bne @g
@num:
    lda tmp+3                   ; two hex digits, then ".sav"
    lsr
    lsr
    lsr
    lsr
    jsr @hex
    lda tmp+3
    jsr @hex
    ldx #0
@x: lda ft_ext,x
    sta namebuf,y
    beq @done
    iny
    inx
    bne @x
@hex:
    and #$0F
    cmp #10
    bcc @dig
    adc #6
@dig:
    adc #'0'
    sta namebuf,y
    iny
    rts

ft_edfc:  .byte "EDFC       "
ft_save:  .byte "SAVE       "
ft_fixed: .word ft_n0, ft_n1, ft_n2
ft_n0:    .byte "A.sav", 0                          ; 5 chars: 1 LFN entry
ft_n1:    .byte "Exactly twenty-six cha.sav", 0     ; 26 chars: 2 full LFN entries, no 0000
ft_n2:    .byte "Twelve c.sav", 0                   ; 12 chars
ft_gen:   .byte "Generated save file name number ", 0
ft_ext:   .byte ".sav", 0
.assert .strlen("Exactly twenty-six cha.sav") = 26, error, "name length changed"
