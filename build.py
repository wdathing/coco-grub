#!/usr/bin/env python3
# Copyright (C) 2026 William Athing
#
# MIT License

"""Build a coco-grub One ROM firmware image from menu.json.

menu.json lists the menu's entries.  Each names the 16K ROM for the
motherboard socket and, optionally, a ROM for the cartridge select (CTS*),
which One ROM answers on X1.  Or it is a submenu instead -
{"name": ..., "submenu": [entries]} - one level deep, its own entries in
the same form.  Each menu has up to nine entries, picked by keys 1-9, and
BREAK goes back from a submenu to the top.  An entry may also give:

- "start": the address to start it at, in hex, where it isn't started through
  its socket ROM's reset vector.  A cartridge that relies on autostart needs
  this, as One ROM doesn't drive CART*.
- "needs_64k": true where it needs a 64K machine.  The menu refuses it on a
  smaller one.
- "becker": true where it talks DriveWire through a Becker port at
  $FF41-$FF42, such as toolshed's hdbdw3bck HDB-DOS.  One ROM then answers
  SCS*, wired to X2, with R/W on the socket's pin 22, and the DriveWire plugin
  bridges the port to the FujiNet's UART.  "becker": "dragon" puts its
  registers at a Dragon's $FF49-$FF4A instead, for a Dragon DOS's Becker
  driver, which keeps clear of the WD2797 at $FF40-$FF43.

Every src/*.asm but grub.asm is a test tool of this repository's own, such
as becktest.asm, a DriveWire link test.  Each is assembled to build/<name>.rom,
which menu.json names like any other ROM.

From it this script:

1. Gives every distinct ROM a single-chip flash slot of its own.  A 27128
   slot costs 32KB of flash, where a whole entry stored as a multi-ROM slot
   would cost 512KB.
2. Writes build/menu.inc, the menus grub.asm assembles in: per menu, its
   entry count and title, then per entry the flash slots to load, the
   flags, the entry's reset vector, its start address and its name - or,
   for a submenu, its menu in place of the vector.
3. Assembles src/grub.asm into build/grub.rom.
4. Writes build/onerom.json - flash slot 0 is the boot slot, grub in the
   socket and nothing on X1 - and composes build/coco-grub.bin with the
   onerom CLI.

Flash slot numbers count the ROM slots only, as the plugin's
ORA_FLASH_SLOT_FLAG_EXCLUDE_PLUGINS enumeration does: plugins come ahead of
the config's slots and are left out.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "build"

# Shown at the top left of the menu.
VERSION = "0.3"

SOCKET_SIZE = 16384
# CTS* selects all of $C000-$FEFF, so X1's chip is a 27128.  An 8K cartridge
# ROM is stored twice over, as a 2764 appears in that window.
CARTRIDGE_SIZE = 16384
CARTRIDGE_SIZE_8K = 8192
NAME_LEN = 26
MAX_ENTRIES = 9  # keys 1-9, in each menu

# Bit 0 of an entry's flags: One ROM answers the cartridge select.  The
# plugin's drivewire_grub_load() reads the same bit.
FLAG_CTS = 0x01
# Bit 1: the entry needs 64K.  The menu alone reads it.
FLAG_64K = 0x02
# Bit 2: One ROM answers a Becker port on SCS*.  The plugin's drivewire_grub_load()
# reads the same bit.
FLAG_BECKER = 0x04
# Bit 3: that Becker port's registers are at a Dragon's $FF49-$FF4A, not
# $FF41-$FF42.  The plugin's drivewire_grub_load() reads the same bit.
FLAG_BECKER_DRAGON = 0x08
# Bit 7: the entry is a submenu.  The menu alone reads it, and never sends it.
FLAG_SUBMENU = 0x80

# The top menu's title.  A submenu's is its name.
TOP_TITLE = "PICK A ROM SET:"

# A config that marks a line "ignore" must say it means it.  On the 26-3134
# OE (pin 22) is tied active, so CE alone selects the socket's ROM and CTS*
# alone the X1 chip - see the README.
SOCKET_CHIP = {"type": "27128", "oe": "ignore", "allow_cs_ignore": True}
CARTRIDGE_CHIP = {"type": "27128", "oe": "ignore"}


def fail(message):
    sys.exit(f"build.py: {message}")


def rom(path, sizes, what):
    full = (ROOT / path).resolve()
    if not full.is_file():
        fail(f"{what} {path} not found - see fetch.py")
    data = full.read_bytes()
    if len(data) not in sizes:
        fail(f"{what} {path} is {len(data)} bytes, not {' or '.join(map(str, sizes))}")
    return full, data


def cartridge(path):
    """The cartridge ROM at path as X1's 16K chip, mirrored into build/ if 8K."""
    full, data = rom(path, (CARTRIDGE_SIZE, CARTRIDGE_SIZE_8K), "cartridge ROM")
    if len(data) == CARTRIDGE_SIZE:
        return full
    mirrored = BUILD / f"{full.stem}-x2.bin"
    mirrored.write_bytes(data * 2)
    return mirrored


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--onerom", required=True, help="the onerom CLI to compose with")
    parser.add_argument("--base-firmware", required=True, help="One ROM base firmware")
    parser.add_argument("--plugin", required=True, help="the DriveWire plugin binary")
    parser.add_argument("--debug-halt", action="store_true",
                        help="stop the menu straight after its knock, leaving One ROM's "
                             "capture ring holding it")
    args = parser.parse_args()

    menu = json.loads((ROOT / "menu.json").read_text())

    BUILD.mkdir(exist_ok=True)

    for tool in sorted((ROOT / "src").glob("*.asm")):
        if tool.name != "grub.asm":
            subprocess.run(["lwasm", "--raw", "-o", str(BUILD / f"{tool.stem}.rom"),
                            "-l" + str(BUILD / f"{tool.stem}.lst"), str(tool)], check=True)

    # Flash slot 0 is the boot slot, so the ROMs take slots 1 onwards, in the
    # order the menus first name them.
    # Each ROM's own slot is never served, only copied from, so it takes the
    # chip type plain.
    slots = []  # (path, chip type)
    slot_of = {}

    def slot_for(path, chip):
        if path not in slot_of:
            slot_of[path] = len(slots) + 1
            slots.append((path, chip))
        return slot_of[path]

    # menus[0] is the top menu.  Each is (title, records), a record either
    # ("rom", socket slot, cartridge slot, flags, vector, start, name) or
    # ("sub", menu index, name).
    menus = []

    def add_menu(title, entries, depth):
        if not 1 <= len(entries) <= MAX_ENTRIES:
            fail(f"menu {title!r} has {len(entries)} entries, wants 1-{MAX_ENTRIES}")
        index = len(menus)
        menus.append(None)
        records = []
        for entry in entries:
            name = entry["name"].upper()
            if len(name) > NAME_LEN:
                fail(f"entry name {entry['name']!r} is longer than {NAME_LEN}")
            if "submenu" in entry:
                if depth > 0:
                    fail(f"submenu {entry['name']!r} is inside another - one level only")
                if set(entry) != {"name", "submenu"}:
                    fail(f"submenu {entry['name']!r} has keys besides name and submenu")
                records.append(("sub", add_menu(f"{name}:", entry["submenu"], depth + 1), name))
                continue
            socket_path, socket_data = rom(entry["socket"], (SOCKET_SIZE,), "socket ROM")
            socket_slot = slot_for(socket_path, "27128")
            cart_slot, flags = 0xFF, 0
            if "cartridge" in entry:
                cart_slot = slot_for(cartridge(entry["cartridge"]), "27128")
                flags |= FLAG_CTS
            if entry.get("needs_64k", False):
                flags |= FLAG_64K
            becker = entry.get("becker", False)
            if becker not in (False, True, "dragon"):
                fail(f"entry {entry['name']!r} has becker {becker!r}, wants true or \"dragon\"")
            if becker:
                flags |= FLAG_BECKER
            if becker == "dragon":
                flags |= FLAG_BECKER_DRAGON
            vector = int.from_bytes(socket_data[0x3FFE:0x4000], "big")
            start = int(entry["start"], 16) if "start" in entry else vector
            records.append(("rom", socket_slot, cart_slot, flags, vector, start, name))
        menus[index] = (title, records)
        return index

    add_menu(TOP_TITLE, menu["entries"], 0)

    def padded(name):
        return list(name.encode("ascii")) + [0] * (NAME_LEN - len(name))

    inc = [
        "* Generated by build.py from menu.json - do not edit.",
        f"NAMELEN equ     {NAME_LEN}",
        f"VERSION fcc     \"{VERSION}\"",
        "        fcb     0",
    ]
    for index, (title, records) in enumerate(menus):
        inc.append(f"MENU{index}   fcb     {len(records)}")
        inc.append(f"        fdb     MTITLE{index}")
        for record in records:
            if record[0] == "sub":
                _, sub, name = record
                inc.append(f"        fcb     0,$FF,${FLAG_SUBMENU:02X}")
                inc.append(f"        fdb     MENU{sub},$0000")
            else:
                _, socket_slot, cart_slot, flags, vector, start, name = record
                inc.append(f"        fcb     {socket_slot},${cart_slot:02X},${flags:02X}")
                inc.append(f"        fdb     ${vector:04X},${start:04X}")
            inc.append("        fcb     " + ",".join(f"${b:02X}" for b in padded(name)))
    for index, (title, _) in enumerate(menus):
        inc.append(f"MTITLE{index} fcc     \"{title}\"")
        inc.append("        fcb     0")
    (BUILD / "menu.inc").write_text("\n".join(inc) + "\n")

    grub = BUILD / "grub.rom"
    subprocess.run(
        ["lwasm", "--raw", f"-I{BUILD}"] + (["-DDEBUGHALT"] if args.debug_halt else []) + [ "-o", str(grub), "-l" + str(BUILD / "grub.lst"),
         str(ROOT / "src" / "grub.asm")],
        check=True,
    )
    if grub.stat().st_size != SOCKET_SIZE:
        fail(f"grub.rom is {grub.stat().st_size} bytes, not {SOCKET_SIZE}")

    blank = BUILD / "blank-27128.bin"
    blank.write_bytes(b"\xFF" * CARTRIDGE_SIZE)

    config = {
        "version": 1,
        "name": "coco-grub",
        "description": "coco-grub boot menu, generated by build.py from menu.json",
        # The DriveWire plugin's UART1 is on SEL_A and SEL_B, and the FujiNet's
        # TX holds SEL_B high, which boot would read as a jumper fitted and
        # serve another slot.  Reserved, boot leaves them alone.
        "reserved_pins": ["sel_a", "sel_b"],
        "chip_sets": [
            {
                "type": "multi",
                "description": "Boot slot: the menu in the socket, nothing on X1",
                "chips": [
                    dict(SOCKET_CHIP, file=str(grub)),
                    dict(CARTRIDGE_CHIP, file=str(blank)),
                ],
            }
        ]
        + [
            {
                "type": "single",
                "description": f"Flash slot {i + 1}: {path.name}",
                "chips": [{"type": chip, "file": str(path)}],
            }
            for i, (path, chip) in enumerate(slots)
        ],
    }
    (BUILD / "onerom.json").write_text(json.dumps(config, indent=4) + "\n")

    subprocess.run(
        [args.onerom, "firmware", "build", "--board", menu["board"],
         "--config", str(BUILD / "onerom.json"), "--base-firmware", args.base_firmware,
         "--plugin", "usb", "--plugin", f"file={args.plugin}",
         "--out", str(BUILD / "coco-grub.bin")],
        check=True,
    )

    for title, records in menus:
        print(f"  {title}")
        for i, record in enumerate(records, 1):
            if record[0] == "sub":
                print(f"    {i}  {record[2]:<{NAME_LEN}}  >  {menus[record[1]][0]}")
                continue
            _, socket_slot, cart_slot, flags, vector, start, name = record
            cart = "-" if cart_slot == 0xFF else str(cart_slot)
            needs = (("  64K" if flags & FLAG_64K else "") +
                     ("  becker" if flags & FLAG_BECKER else "") +
                     ("@FF49" if flags & FLAG_BECKER_DRAGON else ""))
            print(f"    {i}  {name:<{NAME_LEN}}  socket {socket_slot}  cts {cart}"
                  f"  reset ${vector:04X}  start ${start:04X}{needs}")

if __name__ == "__main__":
    main()
