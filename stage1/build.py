#!/usr/bin/env python3
"""
Stage0 bootloader build (two-pass, because the loader patch encodes an address
that only exists after the 1st pass).

Pass 1:
    stage1.S -- arm-none-eabi-gcc --> stage1_loader.elf
    nm(elf) -> addresses of entry_trampoline and patch_blob

Pass 2 (the loader patch):
    patch1.S -- as --> objcopy -O binary --> 24-byte site1  (ldr_call window)
    patch2.S (TRAMP marker text-substituted with the hex addr) -- as --> objcopy --> 8-byte site2
    splice site1+site2 into the image at the patch_blob offset

Then:
    objcopy -O binary(elf) --> stage1_loader.bin (with the spliced blob)
    pad to >= 0x800, 4-byte aligned
    fw_pack.pack() --> TFWriter_AiHmiT7.bin.make
    fw_unscramble round-trip verify (both CRCs)

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
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(HERE, "..", "tools")
sys.path.insert(0, TOOLS)

import fw_pack  # noqa: E402
import fw_unscramble  # noqa: E402

SOURCE = os.path.join(HERE, "stage1.S")
LINKER = os.path.join(HERE, "linker.ld")
ELF = os.path.join(HERE, "stage1_loader.elf")
BIN = os.path.join(HERE, "stage1_loader.bin")
PATCH1 = os.path.join(HERE, "patch1.S")
PATCH2 = os.path.join(HERE, "patch2.S")
PATCH1_SIZE = 24  # site1 window 0x200015c4..0x200015db
PATCH2_SIZE = 8   # site2 window 0x20001df6..0x20001dfd
PATCH_BLOB_SIZE = PATCH1_SIZE + PATCH2_SIZE

ASFLAGS = ["-mcpu=cortex-m4", "-mthumb"]

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


def _run(cmd, **kw):
    res = subprocess.run(cmd, **kw)
    if res.returncode != 0:
        sys.exit(f"error: {' '.join(str(c) for c in cmd)} failed")
    return res


def compile_source(source):
    _check_tool("arm-none-eabi-gcc")
    _run(["arm-none-eabi-gcc", *CCFLAGS, source, "-T", LINKER, "-o", ELF])
    print(f"compiled -> {os.path.basename(ELF)}")


def elf_symbols(elf):
    """nm -> {symbol name: address} for the ELF."""
    _check_tool("arm-none-eabi-nm")
    out = _run(["arm-none-eabi-nm", elf], capture_output=True, text=True).stdout
    syms = {}
    for line in out.splitlines():
        # "addr type name" or, with -S, "addr size type name"
        parts = line.split()
        if len(parts) == 3:
            syms[parts[2]] = int(parts[0], 16)
        elif len(parts) >= 4:
            syms[parts[3]] = int(parts[0], 16)
    return syms


def elf_base(elf):
    """Lowest PT_LOAD VMA = where objcopy -O binary's output starts."""
    _check_tool("arm-none-eabi-readelf")
    out = _run(["arm-none-eabi-readelf", "-l", elf], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.split()
        # columns: Type Enflags Offset VirtAddr PhysAddr FileSiz AlgnSiz
        if len(parts) >= 4 and parts[0] == "LOAD":
            return int(parts[3], 16)
    sys.exit("error: no LOAD segment found in the ELF")


def assemble_patch(tmpdir, tramp_addr):
    """Pass 2: assemble both patch sites into raw byte blobs."""
    _check_tool("arm-none-eabi-as")
    _check_tool("arm-none-eabi-objcopy")

    o1 = os.path.join(tmpdir, "patch1.o")
    _run(["arm-none-eabi-as", *ASFLAGS, PATCH1, "-o", o1])
    b1 = os.path.join(tmpdir, "patch1.bin")
    _run(["arm-none-eabi-objcopy", "-O", "binary", o1, b1])
    with open(b1, "rb") as f:
        site1 = f.read()
    if len(site1) != PATCH1_SIZE:
        sys.exit(f"error: site1 assembled to {len(site1)} bytes, expected {PATCH1_SIZE}")

    # as has no cpp/-D/-defsym usable with :upper12: here, so the TRAMP marker is
    # text-substituted with the hex literal before assembling.
    with open(PATCH2) as f:
        src2_text = f.read().replace("TRAMP", f"0x{tramp_addr:08x}")
    src2 = os.path.join(tmpdir, "patch2.S")
    with open(src2, "w") as f:
        f.write(src2_text)
    o2 = os.path.join(tmpdir, "patch2.o")
    _run(["arm-none-eabi-as", *ASFLAGS, src2, "-o", o2])
    b2 = os.path.join(tmpdir, "patch2.bin")
    _run(["arm-none-eabi-objcopy", "-O", "binary", o2, b2])
    with open(b2, "rb") as f:
        site2 = f.read()
    if len(site2) != PATCH2_SIZE:
        sys.exit(f"error: site2 assembled to {len(site2)} bytes, expected {PATCH2_SIZE}")

    print(f"patch    -> site1 {PATCH1_SIZE} B, site2 {PATCH2_SIZE} B (TRAMP=0x{tramp_addr:x})")
    return site1 + site2


def to_binary(syms, tramp_addr):
    """objcopy -> raw image, then splice the 32-byte loader patch into patch_blob."""
    _check_tool("arm-none-eabi-objcopy")
    _run(["arm-none-eabi-objcopy", "-O", "binary", ELF, BIN])
    with open(BIN, "rb") as f:
        data = bytearray(f.read())

    base = elf_base(ELF)
    off = syms["patch_blob"] - base
    if not (0 <= off + PATCH_BLOB_SIZE <= len(data)):
        sys.exit(f"error: patch_blob at 0x{syms['patch_blob']:x} (offset 0x{off:x}) "
                 f"is outside the {len(data)}-byte image")
    data[off:off + PATCH_BLOB_SIZE] = assemble_patch(tempfile.mkdtemp(prefix="stage1_patch_"), tramp_addr)
    with open(BIN, "wb") as f:
        f.write(data)
    print(f"binary   -> {os.path.basename(BIN)} ({len(data)} bytes, patch spliced at 0x{off:x})")
    return bytes(data)


def padded_bin(data):
    """pack() needs >= 0x800 bytes, a multiple of 4, and < 0xC0000. Pad trailing
    zeros; execution starts at the vector table at 0x80000, so padding after the
    code is harmless."""
    data = bytearray(data)
    target = max(len(data), 0x800)
    target = (target + 3) & ~3
    if target >= fw_pack.MAX_LEN:
        sys.exit(f"error: image {target} bytes exceeds loader cap 0x{fw_pack.MAX_LEN:x}")
    data += b"\x00" * (target - len(data))
    with open(os.path.join(HERE, "stage1_loader.padded.bin"), "wb") as f:
        f.write(data)
    return bytes(data)


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
    syms = elf_symbols(ELF)
    for name in ("entry_trampoline", "patch_blob"):
        if name not in syms:
            sys.exit(f"error: symbol {name} not found in {ELF}")
    tramp = syms["entry_trampoline"] | 1  # Thumb bit for the blx
    # site2's 8-byte window is mov #hi / lsl #12 / add #lo / blx, all 16-bit: hi (bits
    # 12..23) must fit an 8-bit mov, lo (bits 0..11) an 8-bit add (this GAS emits no
    # 12-bit 16-bit ADD imm) - so bits 8..11 of TRAMP must be zero, which only
    # 0x1000-alignment guarantees. .align 12 on entry_trampoline makes lo = 1; assert both.
    if tramp >= 0x1000000 or (tramp & 0xFFF) > 0xFF:
        sys.exit(f"error: TRAMP=0x{tramp:x} out of range for the site2 8-byte window "
                 f"(need TRAMP < 0x1000000 and lo12 <= 0xFF; keep entry_trampoline "
                 f"0x1000-aligned via .align 12 in stage1.S)")
    data = to_binary(syms, tramp)
    data = padded_bin(data)
    packed = fw_pack.pack(data)
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
