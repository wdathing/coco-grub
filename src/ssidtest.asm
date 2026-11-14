* Copyright (C) 2026 William Athing
*
* MIT License
*
* ssidtest: repeats FujiNet Config's WiFi "set SSID" exchange over a Becker
* port ($FF41 status, $FF42 data), run from the cartridge select as a
* coco-grub entry with One ROM's Becker port on, to catch a CoCo write the
* link drops.
*
* Config sends a ready request, OP_FUJI + FUJICMD_READY, reads the one byte
* reply, then sends OP_FUJI + FUJICMD_SET_SSID with a 33 byte SSID and a 64
* byte password, 99 bytes in all, through HDB-DOS's Becker DWWrite and DWRead.
* DWWRITE and DWREAD below are those routines' loops, cycle for cycle, so the
* bus sees what it sees from Config - DWREAD polling $FF41 every 10 cycles,
* with no timeout, as HDB-DOS's does.
*
* Each key sends one exchange, the time since the last key standing in for
* the user typing a password:
*   1  ready, then set SSID at once, as Config does
*   2  ready, about 10ms, then set SSID
*   3  set SSID alone
*
* A dropped byte leaves the FujiNet one short of the 97 it reads after the
* command.  The ready request sent afterwards then finishes that read with its
* OP_FUJI, and its FUJICMD_READY, $00, is DriveWire's OP_NOP, so that request
* goes unanswered and the next one is answered.  Two tries mark a drop, and
* the exchange puts the link back in step.  The FujiNet's log shows what
* arrived: "SSIDTEST" / "PASSTEST1", or each less its first character.
*
* The FujiNet stores the test network as its WiFi network; set the real one
* again in Config afterwards.

SCREEN  equ     $0400
PIA0    equ     $FF00
BECKST  equ     $FF41           bit 1 set while a byte waits at BECKDT
BECKDT  equ     $FF42

OPFUJI  equ     $E2             DriveWire OP_FUJI
FREADY  equ     $00             FUJICMD_READY, answered $01
FSETSID equ     $FB             FUJICMD_SET_SSID
CMDLEN  equ     2+33+64

MAXTRY  equ     4               ready requests after the exchange

* RAM, below 16K.
RUNS    equ     $0E00           exchanges, 16 bits per key
DROPS   equ     $0E06           exchanges needing two or more tries, per key
LASTK   equ     $0E0C           the last key, 0-2
TRIES   equ     $0E0D           ready requests the last exchange took
RREPLY  equ     $0E0E           the reply to its first ready request
STALE   equ     $0E0F           bytes waiting before it, read off
PREPLY  equ     $0E10           the reply to the ready request after it
VARLEN  equ     $11
STACK   equ     $3F00

        org     $C000

START   orcc    #$50
        lds     #STACK
        ldx     #RUNS
CLRV    clr     ,x+
        cmpx    #RUNS+VARLEN
        bne     CLRV
        lda     #$FF
        sta     LASTK

        ldx     #SCREEN
        lda     #$60
CLS     sta     ,x+
        cmpx    #SCREEN+512
        bne     CLS
        ldx     #TITLE
        ldy     #SCREEN
        lbsr    PRINT
        ldx     #HELP1
        ldy     #SCREEN+2*32
        lbsr    PRINT
        ldx     #HELP2
        ldy     #SCREEN+3*32
        lbsr    PRINT
        ldx     #HELP3
        ldy     #SCREEN+4*32
        lbsr    PRINT
        ldx     #HEAD
        ldy     #SCREEN+6*32
        lbsr    PRINT

* In step before the first key, whatever the FujiNet was doing.
        lbsr    POSTRDY
        lbsr    SHOW

MAIN    lbsr    KEYUP
KEYLP   lda     #$FD            column 1: key 1
        sta     PIA0+2
        lda     PIA0
        bita    #$10
        beq     KEY1
        lda     #$FB            column 2: key 2
        sta     PIA0+2
        lda     PIA0
        bita    #$10
        beq     KEY2
        lda     #$F7            column 3: key 3
        sta     PIA0+2
        lda     PIA0
        bita    #$10
        beq     KEY3
        bra     KEYLP
KEY1    clrb
        bra     RUN
KEY2    ldb     #1
        bra     RUN
KEY3    ldb     #2
RUN     stb     LASTK
        lbsr    DRAIN
        clr     RREPLY
        ldb     LASTK
        cmpb    #2
        beq     SETSID
        ldx     #RDYCMD
        ldy     #2
        lbsr    DWWRITE
        ldx     #RREPLY
        ldy     #1
        lbsr    DWREAD
        ldb     LASTK
        beq     SETSID
        ldx     #1100           about 10ms
GAP     leax    -1,x
        bne     GAP
SETSID  ldx     #SIDCMD
        ldy     #CMDLEN
        lbsr    DWWRITE
        lbsr    POSTRDY

* Count it.
        ldb     LASTK
        aslb
        ldx     #RUNS
        abx
        ldd     ,x
        addd    #1
        std     ,x
        lda     TRIES
        cmpa    #1
        beq     COUNTED
        ldd     DROPS-RUNS,x
        addd    #1
        std     DROPS-RUNS,x
COUNTED lbsr    SHOW
        lbra    MAIN

* Ready requests until one is answered, MAXTRY at most, each given about a
* second: the FujiNet takes a while over a set SSID, saving its config.  The
* tries go in TRIES, the answer in PREPLY, or $FF for none.
POSTRDY clr     TRIES
        lda     #$FF
        sta     PREPLY
POSTLP  inc     TRIES
        ldx     #RDYCMD
        ldy     #2
        lbsr    DWWRITE
        lbsr    RECV
        bcc     POSTOK
        lda     TRIES
        cmpa    #MAXTRY
        blo     POSTLP
        rts
POSTOK  sta     PREPLY
        rts

* Reads off and counts bytes waiting, as an exchange that went wrong leaves.
DRAIN   clr     STALE
DRAINLP lda     BECKST
        bita    #$02
        beq     DRAINED
        lda     BECKDT
        inc     STALE
        bne     DRAINLP
        dec     STALE           255 or more
        bra     DRAINLP
DRAINED rts

* Waits for every key to be up.
KEYUP   clr     PIA0+2
        lda     PIA0
        ora     #$80            the joystick comparator
        cmpa    #$FF
        bne     KEYUP
        rts

* HDB-DOS's Becker DWWrite: sends Y bytes from X.
DWWRITE pshs    d,cc
        orcc    #$50
TXBYTE  lda     ,x+
        sta     BECKDT
        leay    -1,y
        bne     TXBYTE
        puls    cc,d,pc

* HDB-DOS's Becker DWRead: receives Y bytes to X, with no timeout.
DWREAD  pshs    u,x
        leau    ,x
        ldx     #$0000
RXLOOP  ldb     BECKST
        bitb    #$02
        beq     RXLOOP
        ldb     BECKDT
        stb     ,u+
        abx
        leay    ,-y
        bne     RXLOOP
        puls    x,u,pc

* Returns the next byte in A with carry clear, or carry set after about a
* second with none.
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

SHOW    ldy     #SCREEN+7*32
        ldx     #RUNS
        lda     #'1
SHOWK   pshs    a,x
        lbsr    PUTC
        leay    3,y
        ldd     ,x
        lbsr    PHEX16
        leay    2,y
        ldx     1,s
        ldd     DROPS-RUNS,x
        lbsr    PHEX16
        puls    a,x
        leax    2,x
        leay    32-14,y
        inca
        cmpa    #'4
        bne     SHOWK

        ldy     #SCREEN+11*32
        ldx     #MLAST
        lbsr    PRINT
        lda     LASTK
        bmi     NOLAST
        adda    #'1
        lbsr    PUTC
        bra     SHOWT
NOLAST  lda     #'-
        lbsr    PUTC
SHOWT   ldx     #MTRIES
        lbsr    PRINT
        lda     TRIES
        lbsr    PHEX
        ldy     #SCREEN+12*32
        ldx     #MREPLY
        lbsr    PRINT
        lda     RREPLY
        lbsr    PHEX
        ldx     #MPOST
        lbsr    PRINT
        lda     PREPLY
        lbsr    PHEX
        ldy     #SCREEN+13*32
        ldx     #MSTALE
        lbsr    PRINT
        lda     STALE
        lbsr    PHEX
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

RDYCMD  fcb     OPFUJI,FREADY

SIDCMD  fcb     OPFUJI,FSETSID
SIDNAME fcc     "SSIDTEST"
        fill    0,33-(*-SIDNAME)
SIDPASS fcc     "PASSTEST1"
        fill    0,64-(*-SIDPASS)

TITLE   fcc     "FUJINET SET SSID LINK TEST"
        fcb     0
HELP1   fcc     "1 READY, SET SSID"
        fcb     0
HELP2   fcc     "2 READY, 10MS, SET SSID"
        fcb     0
HELP3   fcc     "3 SET SSID ALONE"
        fcb     0
HEAD    fcc     "KEY RUNS  DROPS"
        fcb     0
MLAST   fcc     "LAST KEY "
        fcb     0
MTRIES  fcc     "  TRIES "
        fcb     0
MREPLY  fcc     "READY "
        fcb     0
MPOST   fcc     "  AFTER "
        fcb     0
MSTALE  fcc     "STALE "
        fcb     0

        fill    $FF,$E000-*
