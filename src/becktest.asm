* Copyright (C) 2026 William Athing
*
* MIT License
*
* becktest: a DriveWire link test over a Becker port ($FF41 status, $FF42
* data), run from the cartridge select as a coco-grub entry with One ROM's
* Becker port on.
*
* Over and over: a DriveWire reset, then a read of drive 0 sector 0 with
* OP_READEX - the request, up to 256 bytes back, the checksum sent back, and
* the server's one byte result - and the outcome on screen.  Every receive
* gives up after about a second, so a link that drops bytes shows as a short
* count rather than a hang, as stock HDB-DOS's DWRead would.  Anything waiting
* before a request - the rest of a pass that timed out - is read off and
* counted first, so one bad pass doesn't put every pass after it a byte out.

SCREEN  equ     $0400
BECKST  equ     $FF41           bit 1 set while a byte waits at BECKDT
BECKDT  equ     $FF42

OPRESET equ     $FE             DriveWire OP_RESET1
OPREADX equ     $D2             DriveWire OP_READEX

* RAM, below 16K.
PASS    equ     $0E00           passes, 16 bits
TIMEOUT equ     $0E02           passes that timed out, 16 bits
RXCNT   equ     $0E04           bytes received this pass, 16 bits
CSUM    equ     $0E06           checksum of those bytes, 16 bits
RESULT  equ     $0E08           the server's result byte, or $FF on a timeout
IDLEST  equ     $0E09           $FF41 before the request
STALE   equ     $0E0A           bytes waiting before the request, read off
BUF     equ     $1000           the sector
STACK   equ     $3F00

        org     $C000

START   orcc    #$50
        lds     #STACK
        ldd     #0
        std     PASS
        std     TIMEOUT

        ldx     #SCREEN
        lda     #$60
CLS     sta     ,x+
        cmpx    #SCREEN+512
        bne     CLS
        ldx     #TITLE
        ldy     #SCREEN
        lbsr    PRINT

MAIN    ldd     PASS
        addd    #1
        std     PASS

        lda     BECKST
        sta     IDLEST
        clr     STALE
DRAIN   lda     BECKST
        bita    #$02
        beq     DRAINED
        lda     BECKDT
        inc     STALE
        bne     DRAIN
        dec     STALE           255 or more
        bra     DRAIN
DRAINED

        lda     #OPRESET
        lbsr    SEND
        ldx     #$0800          a moment for the server to reset
RSTDLY  leax    -1,x
        bne     RSTDLY

* The request: OP_READEX, drive 0, LSN 0.
        lda     #OPREADX
        lbsr    SEND
        clra
        lbsr    SEND
        lbsr    SEND
        lbsr    SEND
        lbsr    SEND

* Up to 256 bytes back.
        ldd     #0
        std     RXCNT
        std     CSUM
        ldu     #BUF
RXLOOP  lbsr    RECV
        bcs     RXSHORT
        sta     ,u+
        tfr     a,b
        clra
        addd    CSUM
        std     CSUM
        ldd     RXCNT
        addd    #1
        std     RXCNT
        cmpu    #BUF+256
        bne     RXLOOP

* All of it: the checksum back, high byte first, and the result.
        lda     CSUM
        lbsr    SEND
        lda     CSUM+1
        lbsr    SEND
        lbsr    RECV
        bcs     RXSHORT
        sta     RESULT
        bra     SHOW

RXSHORT lda     #$FF
        sta     RESULT
        ldd     TIMEOUT
        addd    #1
        std     TIMEOUT

SHOW    ldy     #SCREEN+2*32
        ldx     #MPASS
        lbsr    PRINT
        ldd     PASS
        lbsr    PHEX16
        ldy     #SCREEN+3*32
        ldx     #MIDLE
        lbsr    PRINT
        lda     IDLEST
        lbsr    PHEX
        ldx     #MSTALE
        lbsr    PRINT
        lda     STALE
        lbsr    PHEX
        ldy     #SCREEN+4*32
        ldx     #MRX
        lbsr    PRINT
        ldd     RXCNT
        lbsr    PHEX16
        ldy     #SCREEN+5*32
        ldx     #MCSUM
        lbsr    PRINT
        ldd     CSUM
        lbsr    PHEX16
        ldy     #SCREEN+6*32
        ldx     #MRES
        lbsr    PRINT
        lda     RESULT
        lbsr    PHEX
        ldy     #SCREEN+7*32
        ldx     #MTOUT
        lbsr    PRINT
        ldd     TIMEOUT
        lbsr    PHEX16
        ldy     #SCREEN+9*32
        ldx     #MDATA
        lbsr    PRINT
        ldx     #BUF
SHOWDAT lda     ,x+
        pshs    x
        lbsr    PHEX
        lda     #$60
        sta     ,y+
        puls    x
        cmpx    #BUF+8
        bne     SHOWDAT

        ldx     #$0000          about half a second
PAUSE   leax    -1,x
        bne     PAUSE
        lbra    MAIN

* Sends A.
SEND    sta     BECKDT
        rts

* Returns the next byte in A with carry clear, or carry set after about a
* second with none.  Keeps U.
RECV    ldx     #$0000
RECVL   lda     BECKST
        bita    #$02
        bne     RECVOK
        leax    -1,x
        bne     RECVL
        orcc    #$01
        rts
RECVOK  lda     BECKDT
        andcc   #$FE
        rts

* Prints D in hex at Y.
PHEX16  pshs    b
        bsr     PHEX
        puls    a
* Prints A in hex at Y.
PHEX    pshs    a
        lsra
        lsra
        lsra
        lsra
        bsr     PNIB
        puls    a
        anda    #$0F
PNIB    cmpa    #10
        blo     PDIGIT
        adda    #'A-10
        bra     PUTC
PDIGIT  adda    #'0
* Puts ASCII character A at Y, as a VDG screen code: $20-$3F move up to
* $60-$7F, as the VDG shows $00-$3F inverse.
PUTC    cmpa    #$40
        bhs     PUTC1
        adda    #$40
PUTC1   sta     ,y+
        rts

* Prints the zero-terminated ASCII string at X at Y.
PRINT   lda     ,x+
        beq     PRDONE
        bsr     PUTC
        bra     PRINT
PRDONE  rts

TITLE   fcc     "BECKER DRIVEWIRE LINK TEST"
        fcb     0
MPASS   fcc     "PASS     "
        fcb     0
MIDLE   fcc     "FF41 IDLE "
        fcb     0
MSTALE  fcc     "  STALE "
        fcb     0
MRX     fcc     "RX BYTES "
        fcb     0
MCSUM   fcc     "CHECKSUM "
        fcb     0
MRES    fcc     "RESULT   "
        fcb     0
MTOUT   fcc     "TIMEOUTS "
        fcb     0
MDATA   fcc     "DATA "
        fcb     0

        fill    $FF,$E000-*
