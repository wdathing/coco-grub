#!/usr/bin/env python3
# Copyright (C) 2026 William Athing
#
# MIT License

"""Fetch and build the third-party ROMs menu.json names, into roms/.

None of these are stored in this repository: cocodiag is GPL-3.0,
coco-forth-rom carries no licence, and Coco 32 and the Dragon 32's BASIC are
modified Tandy and Dragon Data ROMs.  Each is pinned - a git commit, or a
SHA-256 for a download - so a build is reproducible, and moving to a newer
one is a deliberate edit here.

- roms/coco32.rom, roms/coco32-cart.rom: Coco 32, the CoCo 3's BASIC modified
  for a 64K CoCo 2, from the Color Computer Archive's EPROM files.  Its 8000
  and A000 images make the socket ROM.  C000 and E000 make the patch code on
  the cartridge select; E000 stops short at $FEFE, below the CoCo's I/O, and
  is padded to the chip's 16K with $FF.
- roms/cocodiag.rom: varmfskii/cocodiag, an 8K diagnostics cartridge, built
  with lwasm as its own Makefile builds it.
- roms/forth.rom: hcgernhardtiii/coco-forth-rom, an 8K Forth replacing Color
  BASIC at $A000, built with asm6809 and laid out in the socket as its
  Makefile's "burnable" target does: 8K of zeros at $8000, then the Forth.
- roms/dragon32-coco.rom: the Dragon 32's 16K BASIC ROM, from the Color
  Computer Archive's XRoar ROMs, with patches/dragon32.asm laid over it so it
  runs on a CoCo 2.  The pinned SHA-256 is what keeps the patches' addresses
  pointing at the instructions they replace.

The Tandy ROMs, roms/coco2rom-from-FF70.bin and roms/disk11.rom, come from a
ROM dump and aren't fetched.  Nor is roms/dosplus5-becker.rom: DOSplus 5 with
the DW42 extender's Becker driver, build/DP50PSR-BCK.rom from
dragon_dosplus5_extender's "./build.py becker".
"""

import argparse
import hashlib
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ROMS = ROOT / "roms"
THIRD_PARTY = ROOT / "third_party"

COCO32_URL = ("https://colorcomputerarchive.com/repo/ROMs/"
              "Modified Coco 3 ROM for the 64K Coco 2/EPROM Files/")
COCO32_FILES = {
    "8000.BIN": "9377749d73ac41bec02ec36eeb15dd02386dbbc26e44014a0ffadecc0ddcdadd",
    "A000.BIN": "1d7c2fe1e323805f510a40ec4dc261f9b35a775e4ee44b4d8139714e4fa06866",
    "C000.BIN": "66aea106ab4461ce6ff7758d01ccd8bd6fedf7865c671042545edbb63aa0890d",
    "E000.BIN": "f44797dedacdea2241b293e71b5c2f59e2ae18e80a03f00c1fca08a49e255784",
}

COCODIAG_REPO = "https://github.com/varmfskii/cocodiag.git"
COCODIAG_COMMIT = "6bd3fce3c3c7771cffff7b62ab6cd1da37895d38"  # v1.2

FORTH_REPO = "https://github.com/hcgernhardtiii/coco-forth-rom.git"
FORTH_COMMIT = "95d62db812360d98ec3fbc67fe523fa7ca55ee77"

DRAGON32_URL = "https://colorcomputerarchive.com/repo/ROMs/XRoar/Dragon/BASIC_OS/d32.rom"
DRAGON32_SHA256 = "fc0e900bfec6b52f0f80ba1e65a4712808d2a411b5b00496639ef1a2152351f1"
DRAGON32_BASE = 0x8000

ROM_8K = 8192
ROM_16K = 16384


def fail(message):
    sys.exit(f"fetch.py: {message}")


def checkout(repo, commit, name):
    """Clones repo into third_party/name if it isn't there, and checks out commit."""
    path = THIRD_PARTY / name
    if not path.is_dir():
        THIRD_PARTY.mkdir(exist_ok=True)
        subprocess.run(["git", "clone", "-q", repo, str(path)], check=True)
    if subprocess.run(["git", "-C", str(path), "cat-file", "-e", commit + "^{commit}"],
                      capture_output=True).returncode != 0:
        subprocess.run(["git", "-C", str(path), "fetch", "-q", "origin"], check=True)
    subprocess.run(["git", "-C", str(path), "checkout", "-q", "--detach", commit], check=True)
    return path


def sized(data, size, what):
    if len(data) != size:
        fail(f"{what} is {len(data)} bytes, not {size}")
    return data


def coco32():
    images = {}
    for name, sha256 in COCO32_FILES.items():
        url = COCO32_URL + urllib.parse.quote(name)
        with urllib.request.urlopen(urllib.parse.quote(url, safe=":/%")) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != sha256:
            fail(f"Coco 32 {name} doesn't match its pinned SHA-256")
        images[name] = data
    socket = images["8000.BIN"] + images["A000.BIN"]
    cart = images["C000.BIN"] + images["E000.BIN"]
    (ROMS / "coco32.rom").write_bytes(sized(socket, ROM_16K, "Coco 32's socket ROM"))
    (ROMS / "coco32-cart.rom").write_bytes(cart + b"\xFF" * (ROM_16K - len(cart)))


def cocodiag():
    path = checkout(COCODIAG_REPO, COCODIAG_COMMIT, "cocodiag")
    out = ROMS / "cocodiag.rom"
    # Its Makefile's two steps: the CRC table the ROM test includes, then the
    # cartridge.
    subprocess.run([sys.executable, "-I", "gencrctab.py", "8005", "crctab.bin"],
                   cwd=path, check=True)
    subprocess.run(["lwasm", "-Iasm_inc", f"-o{out}", "-fraw", "ziadiag.asm"],
                   cwd=path, check=True)
    sized(out.read_bytes(), ROM_8K, "cocodiag.rom")


def forth():
    asm6809 = shutil.which("asm6809")
    if asm6809 is None:
        print("fetch.py: asm6809 not found, skipping Forth", file=sys.stderr)
        return
    path = checkout(FORTH_REPO, FORTH_COMMIT, "coco-forth-rom")
    main_rom = path / "main.rom"
    subprocess.run([asm6809, "main.6809", "-o", str(main_rom)], cwd=path, check=True)
    data = sized(main_rom.read_bytes(), ROM_8K, "Forth's main.rom")
    (ROMS / "forth.rom").write_bytes(bytes(ROM_8K) + data)


def decb_blocks(data):
    """The (address, bytes) blocks of a DECB binary, lwasm's --format=decb."""
    blocks = []
    i = 0
    while data[i] == 0x00:
        length = int.from_bytes(data[i + 1:i + 3], "big")
        address = int.from_bytes(data[i + 3:i + 5], "big")
        blocks.append((address, data[i + 5:i + 5 + length]))
        i += 5 + length
    if data[i] != 0xFF:
        fail(f"DECB binary has a block type ${data[i]:02X} at offset {i}")
    return blocks


def dragon32():
    with urllib.request.urlopen(DRAGON32_URL) as response:
        rom = bytearray(response.read())
    if hashlib.sha256(rom).hexdigest() != DRAGON32_SHA256:
        fail("the Dragon 32's d32.rom doesn't match its pinned SHA-256")
    patch = ROMS / "dragon32-patch.bin"
    subprocess.run(["lwasm", "--format=decb", f"-o{patch}", str(ROOT / "patches" / "dragon32.asm")],
                   check=True)
    for address, block in decb_blocks(patch.read_bytes()):
        offset = address - DRAGON32_BASE
        if not 0 <= offset <= len(rom) - len(block):
            fail(f"a Dragon 32 patch at ${address:04X} lands outside the ROM")
        rom[offset:offset + len(block)] = block
    patch.unlink()
    (ROMS / "dragon32-coco.rom").write_bytes(sized(bytes(rom), ROM_16K, "the patched Dragon 32 ROM"))


SOURCES = {"coco32": coco32, "cocodiag": cocodiag, "forth": forth, "dragon32": dragon32}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("sources", nargs="*", choices=[[]] + list(SOURCES),
                        help="what to fetch; all of them when none are named")
    args = parser.parse_args()
    ROMS.mkdir(exist_ok=True)
    for name in args.sources or SOURCES:
        SOURCES[name]()


if __name__ == "__main__":
    main()
