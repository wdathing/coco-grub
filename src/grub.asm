* Copyright (C) 2026 William Athing
*
* MIT License
*
* coco-grub: the boot menu One ROM serves from the CoCo's motherboard ROM
* socket ($8000-$BFFF) at power-on.
*
* It sets the machine up as Color BASIC's reset would, shows the entries
* build.py generated into menu.inc, and waits for a key 1-9.  Choosing an
* entry hands over to a stub in RAM, which knocks "!GRUBGO!" and the entry's
* four payload bytes to One ROM's plugin (plugins/user/drivewire,
* drivewire_do_grub()), then polls the reset vector until the plugin has
* copied the entry's ROMs over this one, and cold-starts it.
*
* Signalling: byte b is sent as a read of SIGPAGE+b, a page of this ROM
* nothing else reads.  One ROM captures every cycle the socket is selected,
* the 6809's dead cycles at $FFFF included, and the plugin
* (drivewire_grub_byte()) picks the reads of this page out of them.  The stub
* runs from RAM, so that once it starts, its signals are the only reads of
* this page.
*
* With the plugin running, nothing answers the cartridge select while the
* menu does - the plugin disables X1 at startup - so whatever is read at
* $C000 is a cartridge in the slot.  Entries that would put a ROM on the
* cartridge select are then shown and refused.

SCREEN  equ     $0400
PIA0    equ     $FF00
PIA1    equ     $FF20
SAMREG  equ     $FFC0
RSTFLG  equ     $71             Color BASIC's warm start flag - $55 means warm
CARTROM equ     $C000

* RAM, all below 16K so a 16K machine has it too.
STUB    equ     $3000           the loader stub runs here
KBUF    equ     $3100           knock and payload, 12 bytes
VEC     equ     $310C           the chosen entry's reset vector
CARTIN  equ     $310E           non-zero when a cartridge is fitted
STACK   equ     $3F00

RECLEN  equ     5+NAMELEN       menu.inc's record: slots, flags, vector, name

        org     $8000

START   orcc    #$50            no interrupts, ever - see the stub
        lds     #STACK

* Hardware set up exactly as Color BASIC 1.3's reset does it (bas.asm,
* RESVEC): PIAs, the SAM cleared with the display at $400, and the SAM's
* memory size from the RAM size input on PIA1 PB2.
        ldx     #PIA1
        clr     -3,x
        clr     -1,x
        clr     -4,x
        ldd     #$FF34
        sta     -2,x
        stb     -3,x
        stb     -1,x
        clr     1,x
        clr     3,x
        deca
        sta     ,x
        lda     #$F8
        sta     2,x
        stb     1,x
        stb     3,x
        clr     2,x
        ldb     #$02
        stb     ,x
        ldu     #SAMREG
        ldb     #16
SAMCLR  sta     ,u++
        decb
        bne     SAMCLR
        sta     SAMREG+9
        tfr     b,dp
        ldb     #$04
        clr     -2,x
        bitb    2,x
        beq     RAM64
        sta     -5,u
        sta     -11,u
        bra     RAMSET
RAM64   sta     -3,u
RAMSET

        lbsr    CLS
        ldx     #TITLE
        ldy     #SCREEN
        lbsr    PRINT
        ldx     #RULE
        ldy     #SCREEN+32
        lbsr    PRINT

* Give the plugin time to start and disable X1 before looking for a
* cartridge: a few hundred milliseconds.
        ldx     #$8000
WAITPL  leax    -1,x
        bne     WAITPL
        lbsr    CARTCHK

* The entries, one a row from row 3.
        ldx     #ENTRIES
        ldy     #SCREEN+3*32+1
        ldb     #'1
DRAWLP  pshs    b,x,y
        lda     2,x             flags
        anda    #$01
        beq     DRAWNUM
        tst     CARTIN
        beq     DRAWNUM
        lda     #'-             refused while a cartridge is fitted
        bra     DRAWKEY
DRAWNUM tfr     b,a
DRAWKEY lbsr    PUTC
        leax    5,x
        leay    2,y
        lbsr    PRINTN
        puls    b,x,y
        leax    RECLEN,x
        leay    32,y
        incb
        cmpb    #'1+NENTRY
        bne     DRAWLP

        tst     CARTIN
        beq     PROMPT
        ldx     #CARTMSG
        ldy     #SCREEN+13*32
        lbsr    PRINT
PROMPT  ldx     #PRESS
        ldy     #SCREEN+15*32
        lbsr    PRINT

* Wait for a key that picks an entry.
KEYWAIT ldb     #1
        ldx     #ENTRIES
KEYLP   lbsr    KEYDOWN
        beq     KEYNEXT
        lda     2,x
        anda    #$01
        beq     CHOSEN
        tst     CARTIN
        beq     CHOSEN
KEYNEXT leax    RECLEN,x
        incb
        cmpb    #NENTRY+1
        bne     KEYLP
        bra     KEYWAIT

* X = the chosen record.  Build the knock and payload, then the stub.
CHOSEN  ldu     #KBUF
        ldy     #KNOCK
CPKNOCK lda     ,y+
        sta     ,u+
        cmpy    #KNOCK+8
        bne     CPKNOCK
        lda     ,x              socket ROM's flash slot
        sta     ,u+
        adda    1,x
        adda    2,x
        ldb     1,x             cartridge ROM's flash slot, or $FF
        stb     ,u+
        ldb     2,x             flags
        stb     ,u+
        eora    #$5A            check byte, as drivewire_do_grub() wants
        sta     ,u+
        ldd     3,x
        std     VEC

        ldx     #STUBSRC
        ldu     #STUB
CPSTUB  lda     ,x+
        sta     ,u+
        cmpx    #STUBEND
        bne     CPSTUB
        jmp     STUB

* The stub, copied to STUB and run from there: this ROM is being replaced
* under it.  Position independent.
STUBSRC ldx     #KBUF
        lda     #SIGPAGE/256
SKNOCK  ldb     ,x+
        tfr     d,y
        tst     ,y              the signal: a read of SIGPAGE+b
        cmpx    #KBUF+12
        bne     SKNOCK
        IFDEF   DEBUGHALT
* Debug build: stop here, so One ROM's capture ring still holds the knock.
* SYNC, not a branch to itself: a branch's dead cycle at $FFFF selects this
* socket every time round, and fills the ring within microseconds.  SYNC
* holds $FFFF steady, so the chip select never goes active again.
SDEBUG  sync
        bra     SDEBUG
        ENDC

* The plugin copies the entry's socket ROM in ascending order, so its reset
* vector lands last.  Seeing it twice running means the entry is in place.
* About two seconds before giving up; the copy takes a fraction of that.
        ldy     #0
SPOLL   ldd     $BFFE
        cmpd    VEC
        bne     SNOT
        ldd     $BFFE
        cmpd    VEC
        beq     SGO
SNOT    leay    -1,y
        bne     SPOLL
        leax    SFAIL,pcr
        ldy     #SCREEN+15*32
SFAILLP lda     ,x+
        beq     SHALT
        sta     ,y+
        bra     SFAILLP
SHALT   bra     SHALT
SGO     clr     RSTFLG          a cold start, as at power-on
        jmp     [$FFFE]
* Screen codes already: the stub can't call this ROM's PRINT.
SFAIL   fcb     $4C,$4F,$41,$44,$60,$46,$41,$49,$4C,$45,$44,$60,$6D,$60
        fcb     $50,$4F,$57,$45,$52,$60,$43,$59,$43,$4C,$45,$00
STUBEND

* Sets CARTIN if a cartridge answers the cartridge select.  An empty bus
* gives back the last byte driven onto it.  Each read below follows a dead
* cycle at $FFFF, which reads this ROM's $BFFF, so an empty slot reads that
* byte at both $C000 and $C001 - or $FF at both, where the bus is pulled high
* or One ROM serves the blank X1 chip because the plugin isn't running.  A
* cartridge with one of those at both is unlikely.  An autostart ROM pack
* also toggles CART*, PIA1 CB1, which sets PIA1 CRB's flag.
CARTCHK clr     CARTIN
        lda     PIA1+2          clears the CART* flag
        lda     CARTROM
        ldb     CARTROM+1
        pshs    b
        cmpa    ,s+
        bne     CARTYES
        cmpa    #$FF
        beq     CARTQ
        cmpa    $BFFF
        beq     CARTQ
CARTYES inc     CARTIN
CARTQ   ldx     #$1000
CARTW   leax    -1,x
        bne     CARTW
        lda     PIA1+3
        bpl     CARTD
        inc     CARTIN
CARTD   rts

* B = a digit 1-9.  Returns NE if its key is down.  Keys 1-7 are row 4 of
* the matrix, columns 1-7; 8 and 9 are row 5, columns 0 and 1.
KEYDOWN pshs    b,x
        cmpb    #8
        blo     KEYROW4
        subb    #8
        lda     #$20
        bra     KEYCOL
KEYROW4 lda     #$10
KEYCOL  ldx     #COLTBL
        ldb     b,x
        stb     PIA0+2
        ldb     PIA0
        comb
        pshs    a
        andb    ,s+
        puls    b,x,pc

COLTBL  fcb     $FE,$FD,$FB,$F7,$EF,$DF,$BF,$7F

* Clears the text screen to green spaces.
CLS     ldx     #SCREEN
        lda     #$60
CLSLP   sta     ,x+
        cmpx    #SCREEN+512
        bne     CLSLP
        rts

* Puts ASCII character A at Y, as a VDG screen code, and advances Y.  The VDG
* has no lower case, and shows $00-$3F inverse, so ASCII $20-$3F move up to
* $60-$7F.
PUTC    cmpa    #$60
        blo     PUTC1
        suba    #$20
PUTC1   cmpa    #$40
        bhs     PUTC2
        adda    #$40
PUTC2   sta     ,y+
        rts

* Prints the zero-terminated ASCII string at X at Y.
PRINT   lda     ,x+
        beq     PRDONE
        bsr     PUTC
        bra     PRINT
PRDONE  rts

* Prints an entry name at X at Y: NAMELEN characters, or up to a zero.
PRINTN  ldb     #NAMELEN
PRNLP   lda     ,x+
        beq     PRDONE
        bsr     PUTC
        decb
        bne     PRNLP
        rts

KNOCK   fcc     "!GRUBGO!"
TITLE   fcc     "COCO-GRUB"
        fcb     0
RULE    fcc     "PICK A ROM SET:"
        fcb     0
CARTMSG fcc     "CARTRIDGE IN SLOT - '-' ENTRIES"
        fcb     0
PRESS   fcc     "PRESS A NUMBER TO BOOT"
        fcb     0

        include "menu.inc"

* The signalling page.  At $BC00 because the plugin looks for signals at
* chip offset $3C00.  Its contents don't matter; it's only ever read.
SIGPAGE equ     $BC00
        fill    $FF,SIGPAGE-*
        fill    $FF,$100

        fill    $FF,$BFF2-*
        fdb     START,START,START,START,START,START,START
