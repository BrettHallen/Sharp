;=====================================================================
;
;   MZ-80B  RAM CHECKER
;
;   Re-creation of the Sharp service "RAM CHECKER" boot ROM described in
;   the MZ-80B Service Manual, pages 14-15 ("How to Use RAM CHECKER").
;
;   Fit in place of the 2 KB IPL (boot) ROM and switch on.  RAM TEST-1 and
;   RAM TEST-2 run automatically over the whole 64 KB, first $0000-$7FFF
;   (RAM (I)/(II) blocks) and then $8000-$FFFF (RAM (III)/(IV) blocks):
;
;        RAM TEST-1   0000-OK
;                     4000-OK
;        RAM TEST-2   00 FF 00 FF F0 OK
;
;        RAM TEST-1   8000-OK
;                     C000-OK
;        RAM TEST-2   00 FF 00 FF F0 OK
;
;   RAM TEST-1 : per 16 KB block, write/read $00 then $FF at every byte.
;                Error shown as   ER-235B-00, 01   (address-written, read)
;   RAM TEST-2 : a) $00 up   b) $FF up   c) $00 down   d) $FF down
;                e) $F0/$0F alternating up, then $0F/$F0 down ("vice versa")
;                Each pass fills its range (reading every byte straight back)
;                and then re-verifies the whole range.
;                Error shown as   ER-23FF-01      (address-read data)
;                after the label of the failing pass (00/FF/00/FF/F0).
;   On any error the check stops at that address (as in the manual).  As an
;   addition to the original, the bottom of the screen also shows the
;   written/read data, the RAM block and the IC number(s) to check, using
;   the chip numbering of the figure on manual p.15 (RAM 1..32).
;
;   ---------------------------------------------------------------------
;   How the whole 64 KB is reached
;   ---------------------------------------------------------------------
;   IPL state (after power-on / IPL reset, 8255 PC1 = 0):
;        $0000-$07FF  this ROM
;        $8000-$FFFF  RAM physical $0000-$7FFF      <- tested in phase 1
;   Normal state (after 8255 PC1 = 1, "NST"):
;        $0000-$FFFF  RAM physical $0000-$FFFF      <- $8000-$FFFF in phase 2
;   In both states, PIO port A bit 7 = 1 overlays the 2 KB text V-RAM at
;   $D000-$D7FF.  The test loops switch the overlay off so the RAM beneath
;   is tested too; the CRT always shows V-RAM, so the display is unaffected.
;
;   No main RAM is used for anything other than the test itself:
;   - the stack and the few work variables live in the unused tail of the
;     text V-RAM ($D7D0-$D7FF, beyond the 2000 bytes of an 80x25 screen);
;   - every test loop runs purely in registers with the overlay off, and
;     only turns the overlay back on before it touches the stack (RET).
;
;   To reach $8000-$FFFF the ROM is copied to physical $0000 (CPU $8000 in
;   IPL state), verified, and the copy's entry jump is patched to PHASE2.
;   Then PC1 is set.  Whether the NST line resets the CPU (restart at $0000
;   -> JP PHASE2 in the copy) or simply re-maps memory (execution carries
;   on in the identical copy), the program arrives at PHASE2 either way.
;   PHASE2 checks it really is running from RAM before continuing.
;
;   Assemble (Debian/Ubuntu "z80asm"):
;        z80asm -o RAMCHECK.BIN -l RAMCHECK.ASM
;   then pad to 2048 bytes with $FF for a 2716 / MB8516 EPROM.
;
;=====================================================================

; ---- I/O ports (as used by the factory IPL) -------------------------
PPIA:     equ   0E0h            ; 8255 port A  (cassette control)
PPIB:     equ   0E1h            ; 8255 port B
PPIC:     equ   0E2h            ; 8255 port C
PPICTL:   equ   0E3h            ; 8255 control / bit set-reset
PIOA:     equ   0E8h            ; Z80-PIO port A (bit7 = V-RAM overlay)
PIOCTLA:  equ   0E9h
PIOB:     equ   0EAh            ; Z80-PIO port B (keyboard data)
PIOCTLB:  equ   0EBh
GRPHCTL:  equ   0F4h            ; graphics V-RAM control

VON:      equ   093h            ; PIO-A: text V-RAM at $D000 (as IPL DISP)
VOFF:     equ   013h            ; PIO-A: RAM at $D000-$FFFF (as IPL idle)

; ---- screen ---------------------------------------------------------
VRAM:     equ   0D000h          ; 40 x 25 text screen, ASCII codes
COLS:     equ   40
RCOL:     equ   14              ; column where results start

; ---- work area in the spare tail of text V-RAM ----------------------
STACKTOP: equ   0D7F0h          ; stack grows down into $D7D0-$D7EF
CURPOS:   equ   0D7F0h          ; (2) cursor address in V-RAM
ADRXOR:   equ   0D7F2h          ; (1) CPU->physical high-byte XOR (80h/00h)
BLKSAV:   equ   0D7F3h          ; (2) start address of current test range
ERRW:     equ   0D7F5h          ; (1) failing write data
ERRR:     equ   0D7F6h          ; (1) failing read data
ERRA:     equ   0D7F7h          ; (2) failing physical address

; ---- test range (CPU addresses, identical in both phases) -----------
TSTART:   equ   08000h
COPYDST:  equ   08000h          ; = physical $0000 in IPL state
ROMSIZE:  equ   0800h

;=====================================================================
        org     0000h

        jp      START           ; RAM copy gets this patched to JP PHASE2

;---------------------------------------------------------------------
; PHASE 1 - IPL state.  Initialise exactly like the factory IPL.
;---------------------------------------------------------------------
START:  di
        ld      a,82h           ; 8255: A=out B=in C=out
        out     (PPICTL),a
        ld      a,0Fh           ; PIO A = output
        out     (PIOCTLA),a
        ld      a,0CFh          ; PIO B = bit mode ...
        out     (PIOCTLB),a
        ld      a,0FFh          ; ... all inputs
        out     (PIOCTLB),a
        ld      a,58h           ; BST=1 NST=0 OPEN=1 WRITE=1
        out     (PPIC),a
        ld      a,12h           ; cassette idle
        out     (PPIA),a
        xor     a
        out     (GRPHCTL),a     ; graphics: no CPU access, no output
        ld      a,VON
        out     (PIOA),a

        ld      hl,VRAM         ; clear $D000-$FFFF (no stack yet)
CLS:    ld      (hl),00h
        inc     hl
        ld      a,h
        or      l
        jr      nz,CLS

        ld      sp,STACKTOP     ; stack in V-RAM from here on
        ld      a,80h           ; CPU $8000 = physical $0000
        ld      (ADRXOR),a

        call    PRAT
        dw      VRAM+0*COLS+8 
        db      "MZ-80B RAM CHECKER 2026",0

        ; ---- RAM (I) / (II) : physical $0000-$7FFF ----
        call    PRAT
        dw      VRAM+2*COLS+1
        db      "RAM TEST-1",0
        call    SETCUR
        dw      VRAM+2*COLS+RCOL
        ld      hl,TSTART
        call    BLOCK1
        call    SETCUR
        dw      VRAM+3*COLS+RCOL
        ld      hl,TSTART+4000h
        call    BLOCK1

        call    PRAT
        dw      VRAM+4*COLS+1
        db      "RAM TEST-2",0
        call    SETCUR
        dw      VRAM+4*COLS+RCOL
        call    TEST2

        ;---- copy this ROM into the (now tested) low RAM -------------
        call    PRAT
        dw      VRAM+10*COLS+1
        db      "SWITCHING TO NORMAL STATE",0

        ld      hl,0000h
        ld      de,COPYDST
        ld      bc,ROMSIZE
        ldir
        ld      hl,0000h        ; verify the copy
        ld      de,COPYDST
        ld      bc,ROMSIZE
CPV:    ld      a,(de)
        cp      (hl)
        jp      nz,CPYERR
        inc     hl
        inc     de
        dec     bc
        ld      a,b
        or      c
        jr      nz,CPV

        ld      hl,PHASE2       ; patch the copy's entry: JP PHASE2
        ld      (COPYDST+1),hl

        ld      a,03h           ; set PC1 (NST) -> normal state
        out     (PPICTL),a
        ; If NST re-maps without a CPU reset, the next instruction is
        ; fetched from the RAM copy, which is identical: fall through.

;---------------------------------------------------------------------
; PHASE 2 - normal state, running from the RAM copy at $0000-$07FF.
;---------------------------------------------------------------------
PHASE2: di
        ld      sp,STACKTOP
        ld      a,0Fh           ; re-program the PIO in case NST reset it
        out     (PIOCTLA),a
        ld      a,0CFh
        out     (PIOCTLB),a
        ld      a,0FFh
        out     (PIOCTLB),a
        xor     a
        out     (GRPHCTL),a
        ld      a,VON
        out     (PIOA),a

        ld      hl,MODEFLG      ; are we really executing from RAM?
        ld      a,(hl)
        cpl
        ld      (hl),a
        cp      (hl)
        jp      nz,NSTERR

        xor     a               ; CPU address = physical address now
        ld      (ADRXOR),a

        call    PRAT
        dw      VRAM+10*COLS+1
        db      "                         ",0

        ; ---- RAM (III) / (IV) : physical $8000-$FFFF ----
        call    PRAT
        dw      VRAM+6*COLS+1
        db      "RAM TEST-1",0
        call    SETCUR
        dw      VRAM+6*COLS+RCOL
        ld      hl,TSTART
        call    BLOCK1
        call    SETCUR
        dw      VRAM+7*COLS+RCOL
        ld      hl,TSTART+4000h
        call    BLOCK1

        call    PRAT
        dw      VRAM+8*COLS+1
        db      "RAM TEST-2",0
        call    SETCUR
        dw      VRAM+8*COLS+RCOL
        call    TEST2

        call    PRAT
        dw      VRAM+10*COLS+1
        db      "ALL RAM O.K.  (64K BYTES)",0
STOP:   jr      STOP            ; finished - press IPL reset to repeat

MODEFLG: db     0A5h            ; scratch byte: writable only in the copy

;=====================================================================
; BLOCK1 - RAM TEST-1 over one 16 KB block.
;   in : HL = CPU start address, cursor at the result column
;   out: prints "xxxx-OK", or "ER-aaaa-ww, rr" and stops.
;=====================================================================
BLOCK1: ld      (BLKSAV),hl
        ld      bc,4000h
        call    T1
        jr      c,T1ERR
        ld      hl,(BLKSAV)
        call    PHYS
        call    PRADDR
        call    PRINT
        db      "-OK",0
        ret

T1ERR:  call    SAVERR
        call    PRINT
        db      "ER-",0
        call    PRADDR
        ld      a,'-'
        call    PUTC
        ld      a,d
        call    PRHEX
        call    PRINT
        db      ", ",0
        ld      a,e
        call    PRHEX
        jp      DIAG

;---------------------------------------------------------------------
; T1 - write/read $00 and $FF at each byte.  Runs with V-RAM overlay OFF
; and touches no RAM except the byte under test (no stack use).
;   in : HL = start, BC = length
;   out: CY=0 ok ; CY=1 HL = address, D = written, E = read
;---------------------------------------------------------------------
T1:     ld      a,VOFF
        out     (PIOA),a
T1L:    ld      (hl),00h
        ld      a,(hl)
        or      a
        jr      nz,T1E0
        ld      (hl),0FFh
        ld      a,(hl)
        inc     a
        jr      nz,T1EF
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,T1L
        ld      a,VON           ; overlay back on before RET
        out     (PIOA),a
        or      a               ; CY=0
        ret
T1E0:   ld      e,a             ; read
        ld      d,00h           ; written
        jr      TXERR
T1EF:   dec     a
        ld      e,a
        ld      d,0FFh
TXERR:  ld      a,VON
        out     (PIOA),a
        scf
        ret

;=====================================================================
; TEST2 - RAM TEST-2 over 32 KB starting at TSTART.
;   Cursor at the result column.  Prints each pass label as it starts,
;   then "OK", or "ER-aaaa-rr" and stops.
;=====================================================================
TEST2:  call    PRINT
        db      "00 ",0
        ld      de,0000h        ; a) $00 ascending
        call    DOUP
        call    PRINT
        db      "FF ",0
        ld      de,0FFFFh       ; b) $FF ascending
        call    DOUP
        call    PRINT
        db      "00 ",0
        ld      de,0000h        ; c) $00 descending
        call    DODN
        call    PRINT
        db      "FF ",0
        ld      de,0FFFFh       ; d) $FF descending
        call    DODN
        call    PRINT
        db      "F0 ",0
        ld      de,0F00Fh       ; e) even=$F0 odd=$0F ascending
        call    DOUP
        ld      de,00FF0h       ;    even=$0F odd=$F0 descending
        call    DODN
        call    PRINT
        db      "OK",0
        ret

DOUP:   ld      hl,TSTART
        ld      bc,8000h
        call    PASSUP
        ret     nc
        jr      T2ERR
DODN:   ld      hl,TSTART
        ld      bc,8000h
        call    PASSDN
        ret     nc
T2ERR:  call    SAVERR
        call    PRINT
        db      "ER-",0
        call    PRADDR
        ld      a,'-'
        call    PUTC
        ld      a,e
        call    PRHEX
        jp      DIAG

;---------------------------------------------------------------------
; PASSUP / PASSDN - fill range with pattern (D at even, E at odd
; addresses), reading each byte straight back, then verify the range.
; Overlay OFF and no stack use while running.
;   in : HL = lowest address, BC = length, D/E = patterns
;   out: CY=0 ok ; CY=1 HL = address, D = written, E = read
;---------------------------------------------------------------------
PASSUP: call    SHADOW          ; copy HL/BC/DE to the alternate set
        ld      a,VOFF
        out     (PIOA),a
PUF:    ld      a,d
        bit     0,l
        jr      z,PUF1
        ld      a,e
PUF1:   ld      (hl),a
        xor     (hl)
        jr      nz,PXERR
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,PUF
        exx                     ; fresh HL/BC/DE for the verify
PUV:    ld      a,d
        bit     0,l
        jr      z,PUV1
        ld      a,e
PUV1:   xor     (hl)
        jr      nz,PXERR
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,PUV
        jr      PXOK

PASSDN: add     hl,bc           ; HL = highest address
        dec     hl
        call    SHADOW
        ld      a,VOFF
        out     (PIOA),a
PDF:    ld      a,d
        bit     0,l
        jr      z,PDF1
        ld      a,e
PDF1:   ld      (hl),a
        xor     (hl)
        jr      nz,PXERR
        dec     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,PDF
        exx
PDV:    ld      a,d
        bit     0,l
        jr      z,PDV1
        ld      a,e
PDV1:   xor     (hl)
        jr      nz,PXERR
        dec     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,PDV

PXOK:   ld      a,VON
        out     (PIOA),a
        or      a
        ret

PXERR:  ld      c,a             ; A = written XOR read
        bit     0,l
        jr      z,PXE1
        ld      d,e             ; odd address -> E pattern
PXE1:   ld      a,d
        xor     c
        ld      e,a             ; E = read
        jp      TXERR           ; D = written

; SHADOW - copy HL, BC, DE into HL', BC', DE' (overlay must be ON).
SHADOW: pop     ix              ; return address
        push    hl
        push    bc
        push    de
        exx
        pop     de
        pop     bc
        pop     hl
        exx
        jp      (ix)

;=====================================================================
; Error handling
;=====================================================================
; SAVERR - HL = CPU address, D = written, E = read.
;          Converts HL to physical and keeps copies for DIAG.
SAVERR: call    PHYS
        ld      (ERRA),hl
        ld      a,d
        ld      (ERRW),a
        ld      a,e
        ld      (ERRR),a
        ret

; DIAG - extra detail below the results, then stop.
DIAG:   call    PRAT
        dw      VRAM+12*COLS+1
        db      "ADDRESS ",0
        ld      hl,(ERRA)
        call    PRADDR
        call    PRINT
        db      "  WRITE ",0
        ld      a,(ERRW)
        call    PRHEX
        call    PRINT
        db      "  READ ",0
        ld      a,(ERRR)
        call    PRHEX

        call    PRAT
        dw      VRAM+13*COLS+1
        db      "BLOCK  RAM (",0
        ld      a,(ERRA+1)      ; block = A15,A14
        rlca
        rlca
        and     03h
        ld      c,a             ; C = block 0..3
        add     a,a
        ld      e,a
        ld      d,0
        ld      hl,BLKNAM
        add     hl,de
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a
DG1:    ld      a,(hl)          ; print block name
        inc     hl
        or      a
        jr      z,DG2
        call    PUTC
        jr      DG1
DG2:    ld      a,')'
        call    PUTC

        call    PRAT
        dw      VRAM+14*COLS+1
        db      "CHECK  RAM",0
        ld      a,c             ; first IC number = block*8 + 1
        add     a,a
        add     a,a
        add     a,a
        inc     a
        ld      c,a
        ld      a,(ERRW)
        ld      hl,ERRR
        xor     (hl)
        ld      b,8             ; bit 0 .. bit 7
DG3:    rrca
        jr      nc,DG4
        push    af
        ld      a,' '
        call    PUTC
        ld      a,c
        call    PRDEC
        pop     af
DG4:    inc     c
        djnz    DG3

        ld      a,(ERRW)        ; every bit wrong -> more likely an
        ld      hl,ERRR         ; address / RAS / CAS / decode fault
        xor     (hl)
        inc     a
        jr      nz,DG5
        call    PRAT
        dw      VRAM+15*COLS+1
        db      "(ALL 8 BITS: CHECK ADDRESS/CONTROL)",0
DG5:

        call    PRAT
        dw      VRAM+16*COLS+1
        db      "CHECK STOPPED.",0
        jp      STOP

CPYERR: ex      de,hl
        ld      a,(de)
        ld      d,a             ; D = ROM byte (written)
        ld      e,(hl)          ; E = RAM byte (read)
        call    SAVERR
        call    PRAT
        dw      VRAM+10*COLS+1
        db      "ROM COPY ERROR           ",0
        jp      DIAG

NSTERR: call    PRAT
        dw      VRAM+10*COLS+1
        db      "NST FAILED - NOT IN RAM  ",0
        jp      STOP

BLKNAM: dw      BN1,BN2,BN3,BN4
BN1:    db      "I",0
BN2:    db      "II",0
BN3:    db      "III",0
BN4:    db      "IV",0

;=====================================================================
; Screen output.  Cursor kept in CURPOS (in V-RAM).  Overlay must be ON.
;=====================================================================
; SETCUR - set cursor to the word following the CALL.
SETCUR: ex      (sp),hl
        push    de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      (CURPOS),de
        pop     de
        ex      (sp),hl
        ret

; PRAT - set cursor from the following word, then print the following
;        zero-terminated string.  All registers preserved.
PRAT:   ex      (sp),hl
        push    de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      (CURPOS),de
        pop     de
        ex      (sp),hl         ; fall into PRINT

; PRINT - print the zero-terminated string following the CALL.
;         All registers preserved.
PRINT:  ex      (sp),hl
        push    af
PRL:    ld      a,(hl)
        inc     hl
        or      a
        jr      z,PRE
        call    PUTC
        jr      PRL
PRE:    pop     af
        ex      (sp),hl
        ret

; PUTC - write A at the cursor and advance.  All registers preserved.
PUTC:   push    hl
        ld      hl,(CURPOS)
        ld      (hl),a
        inc     hl
        ld      (CURPOS),hl
        pop     hl
        ret

; PRADDR - print HL as 4 hex digits.
PRADDR: ld      a,h
        call    PRHEX
        ld      a,l             ; fall into PRHEX

; PRHEX - print A as 2 hex digits.  All registers preserved.
PRHEX:  push    af
        rrca
        rrca
        rrca
        rrca
        call    PRNIB
        pop     af
PRNIB:  push    af
        and     0Fh
        add     a,90h
        daa
        adc     a,40h
        daa
        call    PUTC
        pop     af
        ret

; PRDEC - print A (0..99) as 2 decimal digits (leading space).
PRDEC:  push    bc
        ld      b,'0'-1
PD1:    inc     b
        sub     10
        jr      nc,PD1
        add     a,'0'+10
        ld      c,a
        ld      a,b
        cp      '0'
        jr      nz,PD2
        ld      a,' '
PD2:    call    PUTC
        ld      a,c
        call    PUTC
        pop     bc
        ret

; PHYS - convert CPU address in HL to physical RAM address.
PHYS:   push    af
        ld      a,(ADRXOR)
        xor     h
        ld      h,a
        pop     af
        ret

ROMEND:
        end
