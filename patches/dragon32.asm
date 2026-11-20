* Copyright (C) 2026 William Athing
*
* MIT License
*
* Patches that make the Dragon 32's BASIC ROM (d32.rom, pinned in fetch.py)
* run on a CoCo 2.  fetch.py assembles this file and lays each block over the
* stock ROM, giving roms/dragon32-coco.rom.
*
* The two machines differ, for the ROM's purposes, in two pieces of wiring:
* the RAM size input, and the keyboard.
*
* The RAM size input is PIA1 PB2 on both.  A Dragon's is a plain input, but a
* 64K CoCo's is linked to PIA0 PB6, a keyboard column, so it reads back
* whatever the ROM drives there - Color BASIC clears the columns before it
* reads it.  After a hardware reset the columns are 0, so the stock read works,
* but coco-grub starts this ROM with no reset, the columns still as its menu
* last scanned them, and PB2 read high set the SAM for 16K chips.  RAMSIZ
* clears them first, as Color BASIC does.
*
* The keyboard: both scan the same matrix, columns on PIA0 B ($FF02) and rows
* on PIA0 A ($FF00), but the Dragon's keyboard has its rows in a different
* order:
*
*   row    CoCo                  Dragon
*   0      @ A-G                 0-7
*   1      H-O                   8 9 : ; , - . /
*   2      P-W                   @ A-G
*   3      X Y Z arrows SPACE    H-O
*   4      0-7                   P-W
*   5      8 9 : ; , - . /       X Y Z arrows SPACE
*   6      ENTER CLEAR BREAK ... SHIFT, on both
*
* So a CoCo's row bit n is the Dragon's row bit n+2 for rows 0-3, and rows 4
* and 5 are the Dragon's 0 and 1.  The ROM reads the keyboard's rows in two
* places, and KBDROW reorders them for both - see each.  Programs that scan
* the keyboard themselves still see the CoCo's order.
*
* The Dragon starts a disk cartridge itself: cold start compares $C000 with
* "DK" and jumps to $C002 ($B432).  So DOSplus and DragonDOS start from the
* cartridge select with no help from CART*, which One ROM doesn't drive.

* The RAM size read, X = PIA1 ($FF20): was CLR 2,X then LDA 2,X.  No stack
* yet at this point in reset, so a jump there and back rather than a call.
        org     $BB67
        jmp     RAMSIZ
        nop

* The row read in the column scan, which every key decode goes through - the
* key number is built from it at $BC38, row * 8 + column.
        org     $BBCD
        jsr     KBDROW          was LDB $FF00

* The all-columns read that tells whether any key is down.  It's compared only
* with its own last value, but reordered too, so it means the same as the
* reads above.
        org     $BBF4
        jsr     KBDROW          was LDB $FF00

* In the stock ROM's unused zeros, $BE7F-$BFF1.
        org     $BE80

* The RAM size read, with PIA0's columns cleared first - see above.  A = PIA1
* B's inputs, PB2 among them, as the stock code leaves it.
RAMSIZ  clr     2,X
        clr     $FF02           PB6 low, so a 64K CoCo's PB2 reads low
        lda     2,X
        jmp     $BB6B

* Returns B = PIA0 A's rows in the Dragon's order: CoCo rows 0-3 move up to
* 2-5, rows 4-5 down to 0-1, and row 6 (ENTER ... SHIFT) and bit 7 (the
* joystick comparator) stay where they are.  Keeps A and X, as both callers
* need; the instruction after each sets the flags afresh.
KBDROW  ldb     $FF00
        pshs    a
        tfr     b,a
        lsra
        lsra
        lsra
        lsra
        anda    #$03            CoCo rows 4-5, as Dragon rows 0-1
        pshs    a
        tfr     b,a
        anda    #$C0            row 6 and the comparator, unmoved
        pshs    a
        aslb
        aslb
        andb    #$3C            CoCo rows 0-3, as Dragon rows 2-5
        orb     ,s+
        orb     ,s+
        puls    a,pc
