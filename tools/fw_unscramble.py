#!/usr/bin/env python3
"""Unscrambles a firmware image of the TJC / Nextion loader (the `.make` update files and the images in the screen's flash).

  fw_unscramble.py dump.bin out.bin --offset 0x10000     # an image inside a flash dump
  fw_unscramble.py TFWriter.bin.make out.bin             # a file

Format, as the stage 0 loader of the AiHmiT7 screen checks it (`sub_20001498` / `sub_2000138C`):

  0x000..0x1C8   vector table / code, XORed with K
  0x1C8..0x268   header fields, plain: dword 114 = CRC of 460..616, 116 = length, 117 = CRC of the image, 118 = key part
  0x268..0x800   XORed with K
  0x800..length  XORed with K
  K = dword[118] ^ dword[116]

The CRC is the hardware one of the chip: polynomial 0x04C11DB7, initial value 0xFFFFFFFF, 32 bit words, MSB first, no
reflection, no final xor (the STM32 CRC unit). The CRC of the image covers the scrambled bytes 0..0x1C8, 0x268..0x800
and 0x800..length. The image runs at address 0 with the vector table in front.
"""
import argparse
import struct
import sys


def crc32_words(data, crc=0xFFFFFFFF):
    for i in range(0, len(data) - 3, 4):
        crc ^= struct.unpack_from("<I", data, i)[0]
        for _ in range(32):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc


def unscramble(blob):
    """-> (plain image, dict of the header fields and of the two CRC checks)"""
    if len(blob) < 0x800:
        raise ValueError("shorter than the 0x800 byte header")
    word = lambda o: struct.unpack_from("<I", blob, o)[0]
    length = word(464)
    if length < 0x800 or length > len(blob):
        raise ValueError(f"length field {length:#x} does not fit the file")
    key = word(472) ^ length
    img = bytearray(blob[:length])
    info = {"length": length, "key": key,
            "header_crc_ok": crc32_words(bytes(img[460:616])) == word(456),
            "image_crc_ok": crc32_words(bytes(img[0x800:length]),
                                        crc32_words(bytes(img[616:0x800]), crc32_words(bytes(img[0:0x1C8])))) == word(468)}
    for lo, hi in ((0, 0x1C8), (616, 0x800), (0x800, length - length % 4)):
        for o in range(lo, hi, 4):
            struct.pack_into("<I", img, o, struct.unpack_from("<I", img, o)[0] ^ key)
    return bytes(img), info


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--offset", type=lambda v: int(v, 0), default=0, help="start of the image in the input file")
    a = p.parse_args()
    img, info = unscramble(open(a.input, "rb").read()[a.offset:])
    print(f"length {info['length']:#x}, key {info['key']:#x}, header crc {'ok' if info['header_crc_ok'] else 'BAD'}, "
          f"image crc {'ok' if info['image_crc_ok'] else 'BAD'}")
    open(a.output, "wb").write(img)
    return 0 if info["header_crc_ok"] and info["image_crc_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
