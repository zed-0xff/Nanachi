#!/usr/bin/env python3
"""
Stage0 bootloader build.

Real build pipeline (this replaces the old stub that copied a raw .bin straight
into TFWriter_AiHmiT7.bin.make, which the stage 0 loader would not run):

    stage1.S -- arm-none-eabi-gcc --> stage1_loader.elf
                 -- arm-none-eabi-objcopy --> stage1_loader.bin
                 -- pad to >= 0x800, 4-byte aligned --> stage1_loader.padded.bin
                 -- fw_pack.pack()            --> TFWriter_AiHmiT7.bin.make

The image is wrapped in the loader's container format (XOR key + the two CRCs),
so `fw_unscramble.py` round-trips it and the loader accepts it. It runs at
0x80000, where the loader puts the file (loader.c sub_20002F38: copy to RAM,
VTOR=0x80000, MSP=*0, jump to the reset vector).

`stage1.S` is pure assembly on purpose: a C entry cannot link here
because `-nodefaultlibs` drops newlib's `stdint.h`, so the working start code is
hand-written ARM assembly (same reason `tools/sdboot.S` is asm).

This file is the single stage1 build entry point.
"""
import argparse
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(HERE, "..", "tools")
sys.path.insert(0, TOOLS)

import fw_pack  # noqa: E402
import fw_unscramble  # noqa: E402

SOURCE = os.path.join(HERE, "stage1.S")
LINKER = os.path.join(HERE, "linker.ld")
ELF = os.path.join(HERE, "stage1_loader.elf")
BIN = os.path.join(HERE, "stage1_loader.bin")
LOAD_BASE = 0x80000

# install_entry_hook's loader patch (see stage1.S's own header comment on it) is fully static now -
# entry_trampoline's address is computed and written to TRAMP_LIT_SITE entirely at runtime, by
# stage1's own normal `ldr r0, =entry_trampoline`, so no build-time byte-patching of a blob is
# needed here at all anymore (unlike the old, now-abandoned 24-byte version of this patch).

CCFLAGS = [
    "-mcpu=cortex-m4", "-mthumb", "-mfloat-abi=hard", "-mfpu=fpv4-sp-d16",
    "-O2", "-ffunction-sections", "-fdata-sections",
    "-nostdlib", "-nostartfiles", "-nodefaultlibs",
    "-Wall", "-Wextra", "-I.",
    "-DSKIP_MITMY_POLL",
]


def _check_tool(name):
    found = subprocess.run([name, "--version"], capture_output=True)
    if found.returncode != 0:
        sys.exit(f"error: {name} not found or not runnable (install arm-none-eabi-{name})")


def compile_source(source):
    _check_tool("arm-none-eabi-gcc")
    cmd = ["arm-none-eabi-gcc", *CCFLAGS, source, "-T", LINKER, "-o", ELF]
    res = subprocess.run(cmd)
    if res.returncode != 0:
        sys.exit(f"error: arm-none-eabi-gcc failed to build {os.path.basename(source)}")
    print(f"compiled -> {os.path.basename(ELF)}")


def to_binary():
    _check_tool("arm-none-eabi-objcopy")
    res = subprocess.run(["arm-none-eabi-objcopy", "-O", "binary", ELF, BIN])
    if res.returncode != 0:
        sys.exit(f"error: objcopy failed")
    print(f"binary   -> {os.path.basename(BIN)} ({os.path.getsize(BIN)} bytes)")


def padded_bin():
    """pack() needs >= 0x800 bytes, a multiple of 4, and < 0xC0000. Pad trailing
    zeros; execution starts at the vector table at 0x80000, so padding after the
    code is harmless."""
    with open(BIN, "rb") as f:
        data = bytearray(f.read())
    target = max(len(data), 0x800)
    target = (target + 3) & ~0x3
    if target >= fw_pack.MAX_LEN:
        sys.exit(f"error: image {target} bytes exceeds loader cap 0x{fw_pack.MAX_LEN:x}")
    data += b"\x00" * (target - len(data))
    with open(os.path.join(HERE, "stage1_loader.padded.bin"), "wb") as f:
        f.write(data)
    return bytes(data)


def pack_image(data):
    packed = fw_pack.pack(data)
    return packed


def verify(packed):
    plain, info = fw_unscramble.unscramble(packed)
    ok = info["header_crc_ok"] and info["image_crc_ok"]
    print(f"verify: header_crc_ok={info['header_crc_ok']} image_crc_ok={info['image_crc_ok']} "
          f"key=0x{info['key']:x} length=0x{info['length']:x}")
    if not ok:
        sys.exit("error: produced image fails the loader CRC checks")
    return info


def build(output, source=SOURCE):
    compile_source(source)
    to_binary()
    data = padded_bin()
    packed = pack_image(data)
    with open(output, "wb") as f:
        f.write(packed)
    verify(packed)
    # Pure intermediates: drop them, keep only the .elf (objdump/gdb) and the
    # final container.
    for _gone in (BIN, os.path.join(HERE, "stage1_loader.padded.bin")):
        try:
            os.remove(_gone)
        except OSError:
            pass
    print(f"wrote {output}: {len(packed)} bytes (stage1 bootloader, loader-readable)")


def main():
    ap = argparse.ArgumentParser(description="Build the stage1 bootloader image (TFWriter_AiHmiT7.bin.make)")
    ap.add_argument("-o", "--output", default=os.path.join(HERE, "..", "TFWriter_AiHmiT7.bin.make"),
                    help="output path (default: Nanachi/TFWriter_AiHmiT7.bin.make)")
    ap.add_argument("-s", "--source", default=SOURCE,
                    help="assembly source to build (default: stage1.S)")
    args = ap.parse_args()
    build(args.output, args.source)
    return 0


if __name__ == "__main__":
    sys.exit(main())
