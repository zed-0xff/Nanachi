#!/usr/bin/env python3
import argparse
import os
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fw_unscramble import crc32_words  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
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


def main():
    return 0


if __name__ == "__main__":
    sys.exit(main())
