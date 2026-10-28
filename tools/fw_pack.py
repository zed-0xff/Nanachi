#!/usr/bin/env python3
"""Builds firmware images in the container format of the stage 0 loader of the TJC / Nextion AiHmiT7 screen (the inverse of
tools/fw_unscramble.py), and the `TFWriter_AiHmiT7.bin.make` file that the loader runs from an SD card.

  fw_pack.py sdboot --stock app_10000_plain.bin -o TFWriter_AiHmiT7.bin.make

`sdboot` makes an image that does not change anything on the screen: a few bytes of code (tools/sdboot.S) copy the stock firmware into RAM
at address 0 and start it, as the loader does with the image in the flash. Put the file in the root of a FAT formatted SD card, power
the screen up with the card inserted; remove the card and the screen boots from its flash as before. The flash is not touched. It is the
base for patched firmware: patch the plain stock image (`--stock`) and the patched copy runs.

What the loader does with the file (loader.c `sub_20002F38`): reads up to 0x60000 bytes to RAM 0x80000, checks `length < 0xC0000` and the two
CRCs (`tools/fw_unscramble.py` has the format), unscrambles, sets VTOR = 0x80000 and MSP = dword 0, calls the reset vector (dword 1). The
code here runs at 0x80000, so everything in it is position independent or uses absolute 0x80000 addresses.
"""
import argparse
import os
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fw_unscramble import crc32_words  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SD_BASE = 0x80000            # where the loader puts the file
PAYLOAD_AT = 0x1000          # the stock image inside the file
MAX_LEN = 0xC0000


def pack(image, key=0, field_460=0x9F):
    """image: the whole image as it runs in RAM (vector table first; 0x1C8..0x268 hold the header fields), a multiple of 4 bytes
    and at least 0x800 long. key: the XOR key (0 leaves everything plain). Returns the file for the loader."""
    if len(image) < 0x800 or len(image) % 4 or len(image) >= MAX_LEN:
        raise ValueError("image must be a multiple of 4 bytes, 0x800 .. 0xC0000")
    img = bytearray(image)
    length = len(img)
    struct.pack_into("<I", img, 460, field_460)
    struct.pack_into("<I", img, 464, length)
    struct.pack_into("<I", img, 472, (key ^ length) & 0xFFFFFFFF)
    for lo, hi in ((0, 0x1C8), (616, 0x800), (0x800, length)):          # the same scrambling is its own inverse
        for o in range(lo, hi, 4):
            struct.pack_into("<I", img, o, struct.unpack_from("<I", img, o)[0] ^ key)
    crc = crc32_words(bytes(img[0:0x1C8]))
    crc = crc32_words(bytes(img[616:0x800]), crc)
    crc = crc32_words(bytes(img[0x800:length]), crc)
    struct.pack_into("<I", img, 468, crc)
    struct.pack_into("<I", img, 456, crc32_words(bytes(img[460:616])))
    return bytes(img)


def assemble(source, defines):
    """Thumb-2 source -> raw bytes of its .text (Apple / LLVM clang and pyelftools; no linker needed)."""
    from elftools.elf.elffile import ELFFile
    # Resolve source to absolute path relative to HERE (not cwd, which may differ)
    source = os.path.abspath(os.path.join(HERE, source))
    with tempfile.TemporaryDirectory() as d:
        obj = os.path.join(d, "o.o")
        # assembler-with-cpp (not plain "assembler"): runs the C preprocessor first, which is what actually applies
        # the -D defines below (PAYLOAD_SRC/PAYLOAD_LEN) - with plain "assembler" clang silently ignores them
        # ("argument unused during compilation"), leaving every =PAYLOAD_SRC/=PAYLOAD_LEN literal as 0.
        cmd = ["clang", "-target", "thumbv7m-none-eabi", "-c", "-x", "assembler-with-cpp", source, "-o", obj]
        cmd += [f"-D{k}={v}" for k, v in defines.items()]
        subprocess.run(cmd, check=True)
        with open(obj, "rb") as f:
            return ELFFile(f).get_section_by_name(".text").data()


def sdboot_image(stock, source=os.path.join(HERE, "sdboot.S")):
    """The SD file that starts `stock` (the plain stock image) from RAM."""
    if len(stock) % 4:
        stock = stock + b"\0" * (4 - len(stock) % 4)
    code = bytearray(assemble(source, {"PAYLOAD_SRC": SD_BASE + PAYLOAD_AT, "PAYLOAD_LEN": len(stock)}))
    if len(code) > 0x1C8:
        raise ValueError(f"the start code is {len(code)} bytes, the vector table and the code must fit in the first 0x1C8")
    # sdboot.S is assembled standalone (no linker, see assemble()), so `.word entry+1` and the 46 `.word halt+1`
    # fillers bake in section-relative offsets (e.g. 0xC5), not the addresses they'll actually run at once the
    # loader puts this code at SD_BASE. The loader's own vector-table jump (sub_20001DE0 in loader.c) uses the
    # stored word as an absolute address with no base added - that's correct for the flash image (linked at 0,
    # so its own vector table already holds absolute addresses) but wrong here, and silently jumps into garbage
    # at the low, unmapped offset instead of `entry`. Patch every vector-table code-pointer word (everything
    # after the initial SP word, up to where `halt:` sits at offset 0xC0) to add SD_BASE back in.
    for off in range(4, 0xC0, 4):
        struct.pack_into("<I", code, off, (struct.unpack_from("<I", code, off)[0] + SD_BASE) & 0xFFFFFFFF)
    image = bytearray(PAYLOAD_AT + len(stock))
    image[:len(code)] = code
    image[PAYLOAD_AT:] = stock
    return pack(bytes(image))


def sdboot_new_image(stock, source=os.path.join(HERE, "sdboot_new.S")):
    """The SD file that lists bootable files and allows selection."""
    if len(stock) % 4:
        stock = stock + b"\0" * (4 - len(stock) % 4)
    code = bytearray(assemble(source, {"PAYLOAD_SRC": SD_BASE + PAYLOAD_AT, "PAYLOAD_LEN": len(stock)}))
    if len(code) > 0x1C8:
        raise ValueError(f"the start code is {len(code)} bytes, the vector table and the code must fit in the first 0x1C8")
    # Patch vector-table code pointers to use absolute addresses
    for off in range(4, 0xC0, 4):
        struct.pack_into("<I", code, off, (struct.unpack_from("<I", code, off)[0] + SD_BASE) & 0xFFFFFFFF)
    image = bytearray(PAYLOAD_AT + len(stock))
    image[:len(code)] = code
    image[PAYLOAD_AT:] = stock
    return pack(bytes(image))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sdboot", help="build the SD card file that runs the stock firmware from RAM")
    s.add_argument("--stock", required=True, help="the plain (unscrambled) stock image, e.g. app_10000_plain.bin")
    s.add_argument("-o", "--output", default="TFWriter_AiHmiT7.bin.make")
    s.add_argument("--source", default="sdboot.S")
    a = p.parse_args()
    out = sdboot_image(open(a.stock, "rb").read(), source=a.source)
    open(a.output, "wb").write(out)
    print(f"{a.output}: {len(out)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
