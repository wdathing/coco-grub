# coco-grub

A boot menu for the Tandy Color Computer, served by a One ROM. At power-on the
CoCo shows a menu, and the chosen ROM set is then served in place of the menu
and cold-started.

## Targets

1. **First:** CoCo 2 26-3134 and 26-3136. Color BASIC and Extended Color BASIC
   share a single 27128 in one motherboard socket.
2. **Later:** CoCo 1 and CoCo 2 boards with two 2764 sockets, one for Color
   BASIC and one for Extended Color BASIC.

## Using the cartridge select without a cartridge

One ROM can serve a second ROM image at the same time as the first, selected by
its own chip-select line through the X1 or X2 pin. This is a "multi-ROM slot"
(see One ROM's `docs/MULTI-ROM-SETS.md`, which fire-28-c supports).

The plan is to wire CTS\* to one of these pins with a flying lead. One ROM then
answers reads at $C000–$DFFF as well, so HDB-DOS runs from the motherboard
socket with nothing in the cartridge slot.

This works on a 26-3134. Disk Extended BASIC 1.1 boots from X1 with no cartridge
fitted; the config is `configs/coco2-27128-disk11.json`.

Two things about this board shape every config:

- **OE (pin 22) is tied active.** Both chips must mark `oe` as `ignore`, so CE
  (pin 20) alone selects BASIC and CTS\* alone selects the X1 chip. Chip 0 also
  needs `allow_cs_ignore`. With OE left in, One ROM treats it as a chip select
  that is always active, drives the data bus on every cycle, and the CoCo
  doesn't boot.
- **The slot's table is 512KB, so there is only one RAM slot.** The menu can't
  load an entry into a second RAM slot and switch to it. Instead the plugin
  copies the entry over the live slot while the CoCo runs from its own RAM.

On the two-socket boards, the Extended BASIC socket's chip select takes the
other X pin. That gives three images in one slot: BASIC, Extended BASIC and
HDB-DOS. Three is the most a multi-ROM slot holds.

## Menu entries

The list is fixed at compile time for now. It may become configurable at run
time later.

| # | Entry | Notes |
| --- | --- | --- |
| 1 | Color BASIC + ECB + HDB-DOS (One ROM build) | The default. |
| 2 | Color BASIC + ECB | No HDB-DOS. The DriveWire plugin ignores knocks, and One ROM doesn't answer CTS\*. |
| 3 | CoCo 3 BASIC, CoCo 2 port | ROMs from the Color Computer Archive. |
| 4 | Entry 3 + HDB-DOS | |
| 5 | Diagnostics | Based on varmfskii/cocodiag, which needs work. |
| 6 | Forth | hcgernhardtiii/coco-forth-rom |

## Booting and RESET

The CoCo fetches its reset vector from $FFFE, which the SAM maps to $BFFE, the
top of the motherboard socket. So the boot slot's chip 0 is the grub image: menu
code at $8000-$BFFF with its own reset vector. Choosing an entry copies that
entry's image over the live slot and jumps through its reset vector.

- **Power-on goes to grub.** One ROM is powered from the socket, so a power
  cycle restarts it into the grub slot.
- **RESET stays in the chosen system,** as it would with a real ROM. Many games
  need RESET pressed to get artifact colours right, and BASIC's warm start
  relies on it too.
- **To do:** holding a key through RESET returns to grub. One ROM doesn't see the
  RESET line, so this needs the plugin to watch for the reset vector fetch, or
  RESET wired to a spare pin.

## DriveWire plugin

The aim is a single build of the One ROM DriveWire plugin that works whether
HDB-DOS sits in the cartridge slot or in the motherboard socket.

## ROM images

Tandy and Microsoft ROM images are not stored in this repository. The build
fetches them, or takes them from a local directory. Before anything from the
two third-party projects is vendored, check their licences.
