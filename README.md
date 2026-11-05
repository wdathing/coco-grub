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

## DriveWire plugin

The aim is a single build of the One ROM DriveWire plugin that works whether
HDB-DOS sits in the cartridge slot or in the motherboard socket.

## ROM images

Tandy and Microsoft ROM images are not stored in this repository. The build
fetches them, or takes them from a local directory. Before anything from the
two third-party projects is vendored, check their licences.
