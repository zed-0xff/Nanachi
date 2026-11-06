#!/usr/bin/env python3
"""
Stage0 bootloader build (two-pass, because the loader patch encodes an address
that only exists after the 1st pass).

Pass 1:
    stage1.S -- arm-none-eabi-gcc --> stage1_loader.elf
    nm(elf) -> addresses of entry_trampoline and patch_blob

Pass 2 (the loader patch + the peek site):
    patch1.S -- as --> objcopy -O binary --> 24-byte site1  (ldr_call window)
    patch2.S (TRAMP marker text-substituted with the hex addr) -- as --> objcopy --> 8-byte site2
    _bl_word(0x2A1E, PEEK_BLOB_DST) -- hand-encoded 32-bit Thumb BL (T1), decoded back and
              asserted to land on 0x79D448 (the .peekblob copy in the safe gap) --> 4-byte site3
              (GAS can't emit this: an isolated non-linked `bl` stays a relocation placeholder)
    splice site1+site2+site3 into the image at the patch_blob offset

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
PEEK_SIZE = 4     # peek site: the stock parser's BL.W window at 0x2A1E
PEEK_SITE = 0x2A1E
PATCH_BLOB_SIZE = PATCH1_SIZE + PATCH2_SIZE + PEEK_SIZE
# The stock parser's original 4-byte word at 0x2A1E (BL get_String8, bytes 01 F0 7D FD). A control
# build splices this verbatim so 0x2A1E is byte-identical to pristine stock.
PEEK_ORIGINAL_WORD = 0xFD7DF001
# The 0x2A1E branch targets PEEK_BLOB_DST - the .peekblob blob's RUNTIME home, a fixed address in
# the safe gap that install_peek_blob copies the blob into at the stock hand-off (the image LMA
# is the source of that copy, not the BL target). This is a constant, not an ELF symbol: the blob
# must run where it survives the stock boot, and the stock boot (reset 0x348 ->
# init_table_runner 0x270) clobbers 0x080000..~0x077F3B0 (the image at 0x80000..0x82648 is inside
# it - an in-image blob dies before the first serial command, bench-confirmed) and clears bss
# 0x7620D0..0x79D438 (which is why the earlier 0x780000 relocation went silent on every
# 2-4-char command). The safe gap 0x79D438..0x7DF000 (above the bss top, below the stack floor
# 0x7DF000, the stock's SP = 0x800000) survives, and 0x2A1E reaches it directly: the 32-bit
# Thumb BL (T1) has a +/-16 MB (±0x1000000) PC-relative range, verified against the stock's own
# original word (0xFD7DF001 re-derives to 0x451D with the same encoder below).
PEEK_BLOB_DST = 0x79D448
# The safe gap the blob may occupy: 0x79D438..0x7DF000 (above the bss top, below the stock's
# stack floor 0x7DF000 - SP starts at 0x800000). The blob's runtime end must stay at or below
# PEEK_BLOB_END. The old 0x428 "cap" in cmd.S was a conservative design limit, not a memory
# wall; this asserts the real boundary so an over-large blob fails loudly instead of clobbering
# live stock state past the gap.
PEEK_BLOB_END = 0x7DF000

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


def _bl_word(pc, target):
    """Hand-assemble the 4-byte 32-bit Thumb BL (T1) at `pc` (a 32-bit insn => PC = pc+4) targeting
    `target`. GAS cannot emit this reliably: a `bl` assembled in isolation in a non-linked object
    stays a relocation placeholder (`ff f7 fe ff`) for every target, so the 32-bit BL is encoded
    directly. Field layout (verified against 7 trusted toolchain samples + the real stock word at
    0x2A1E):
        low halfword  (bits 15:0)  = 11110 S imm10[9:0]
        high halfword (bits 31:16) = 11 J1 1 J2 imm11[10:0]
        I1 = ~(J1^S), I2 = ~(J2^S);  field24 = S:I1:I2:imm10:imm11;  offset = SignExt24(field24)<<1
    The offset is always even, so `target - (pc+4)` must be even."""
    off = target - (pc + 4)
    if off & 1:
        sys.exit(f"error: BL target 0x{target:x} is odd (offset {off:#x} from 0x{pc + 4:x} not even)")
    f24 = (off >> 1) & 0xFFFFFF
    S     = (f24 >> 23) & 1
    I1    = (f24 >> 22) & 1
    I2    = (f24 >> 21) & 1
    imm10 = (f24 >> 11) & 0x3FF
    imm11 = f24 & 0x7FF
    J1 = (S ^ (1 - I1)) & 1
    J2 = (S ^ (1 - I2)) & 1
    lo = (0b11110 << 11) | (S << 10) | imm10
    hi = 0xD000 | (J1 << 13) | (J2 << 11) | imm11
    return (hi << 16) | lo


def _bl_word_target(word, pc):
    """Inverse of _bl_word: decode a 32-bit Thumb BL word at `pc` back to its target."""
    hi = (word >> 16) & 0xFFFF
    lo = word & 0xFFFF
    S     = (lo >> 10) & 1
    imm10 = lo & 0x3FF
    J1 = (hi >> 13) & 1
    J2 = (hi >> 11) & 1
    imm11 = hi & 0x7FF
    I1 = (~(J1 ^ S)) & 1
    I2 = (~(J2 ^ S)) & 1
    f = (S << 23) | (I1 << 22) | (I2 << 21) | (imm10 << 11) | imm11
    if f & (1 << 23):
        f -= (1 << 24)
    return pc + 4 + (f << 1)


def assemble_peek(original_word=None):
    """Return the 4-byte 32-bit Thumb BL that is spliced over the stock parser's original BL at
    0x2A1E, targeting PEEK_BLOB_DST (0x79D448, the .peekblob blob's runtime home in the safe gap -
    a constant, not an ELF symbol: install_peek_blob copies the blob's LMA range into the gap at
    the stock hand-off and the BL lands on that copy). The word is verified by decoding it back and
    asserting it lands exactly on the target.

    If `original_word` is given, splice that word verbatim instead (a control build: byte-identical
    to pristine stock at 0x2A1E, so any 1-4-char behavior seen is the stock's own, not the hook's)."""
    if original_word is not None:
        site3 = (original_word & 0xFFFFFFFF).to_bytes(PEEK_SIZE, "little")
        print(f"patch    -> peek  {PEEK_SIZE} B @ 0x{PEEK_SITE:x} (ORIGINAL word=0x{original_word:08x}, "
              f"control build = pristine stock)")
        return site3
    target = PEEK_BLOB_DST
    word = _bl_word(PEEK_SITE, target)
    got = _bl_word_target(word, PEEK_SITE)
    if got != target:
        sys.exit(f"error: peek BL word 0x{word:08x} decodes to 0x{got:x}, expected the gap copy "
                 f"0x{target:x} - the BL encode/decode is off")
    site3 = word.to_bytes(PEEK_SIZE, "little")
    print(f"patch    -> peek  {PEEK_SIZE} B @ 0x{PEEK_SITE:x} (target=0x{target:08x}, "
          f"word=0x{word:08x} -> 0x{got:x})")
    return site3


def assemble_patch(tmpdir, tramp_addr, original_word=None):
    """Pass 2: assemble the two loader sites and the peek site into one 36-byte blob (site1 24 B +
    site2 8 B + peek 4 B, in that order - the layout install_entry_hook / install_peek_blob expect
    in stage1.S's patch_blob)."""
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

    site3 = assemble_peek(original_word)

    print(f"patch    -> site1 {PATCH1_SIZE} B, site2 {PATCH2_SIZE} B (TRAMP=0x{tramp_addr:x})")
    return site1 + site2 + site3


def to_binary(syms, tramp_addr, original_word=None):
    """objcopy -> raw image, then splice the 36-byte patch blob (2 loader sites + the peek site)
    into patch_blob."""
    _check_tool("arm-none-eabi-objcopy")
    _run(["arm-none-eabi-objcopy", "-O", "binary", ELF, BIN])
    with open(BIN, "rb") as f:
        data = bytearray(f.read())

    base = elf_base(ELF)
    off = syms["patch_blob"] - base
    if not (0 <= off + PATCH_BLOB_SIZE <= len(data)):
        sys.exit(f"error: patch_blob at 0x{syms['patch_blob']:x} (offset 0x{off:x}) "
                 f"is outside the {len(data)}-byte image")
    data[off:off + PATCH_BLOB_SIZE] = assemble_patch(
        tempfile.mkdtemp(prefix="stage1_patch_"), tramp_addr, original_word)
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


def build(output, source=SOURCE, original_word=None):
    compile_source(source)
    syms = elf_symbols(ELF)
    # the 0x2A1E target is the .peekblob blob (PEEK_BLOB_DST, copied to the safe gap at the
    # stock hand-off); the image only has to export the entry trampoline and the patch blob.
    for name in ("entry_trampoline", "patch_blob"):
        if name not in syms:
            sys.exit(f"error: symbol {name} not found in {ELF}")
    # the .peekblob blob is word-copied to PEEK_BLOB_DST at the stock hand-off; its size is the
    # LMA range. It must be 4-byte-aligned (word copy) and end at or below PEEK_BLOB_END (the
    # safe gap's upper edge, the stock's stack floor) - a larger blob would clobber live stock
    # state past the gap.
    for _nm in ("__peekblob_lma", "__peekblob_end"):
        if _nm not in syms:
            sys.exit(f"error: symbol {_nm} not found in {ELF}")
    blob_size = syms["__peekblob_end"] - syms["__peekblob_lma"]
    if blob_size & 3:
        sys.exit(f"error: .peekblob size 0x{blob_size:x} is not 4-byte aligned (word copy)")
    if PEEK_BLOB_DST + blob_size > PEEK_BLOB_END:
        sys.exit(f"error: .peekblob end 0x{PEEK_BLOB_DST + blob_size:x} exceeds the safe gap "
                 f"end PEEK_BLOB_END=0x{PEEK_BLOB_END:x} (size 0x{blob_size:x})")
    print(f"  .peekblob: 0x{blob_size:x} bytes @ LMA 0x{syms['__peekblob_lma']:x} -> "
          f"runtime 0x{PEEK_BLOB_DST:x}..0x{PEEK_BLOB_DST + blob_size:x} (gap end "
          f"0x{PEEK_BLOB_END:x})")
    tramp = syms["entry_trampoline"] | 1  # Thumb bit for the blx
    # the 0x2A1E branch is a 32-bit Thumb BL (T1): offset = SignExt24(S:I1:I2:imm10:imm11) << 1,
    # so +/-0x1000000 (16 MB) of PC-relative reach from 0x2A22. PEEK_BLOB_DST (0x79D448) is
    # ~0x79A000 out, far inside, but assert it so a target change fails loudly. Skipped for a
    # control build (original_word set) where the site is not a branch to the blob.
    if original_word is None and abs(PEEK_BLOB_DST - (PEEK_SITE + 4)) > 0x1000000:
        sys.exit(f"error: PEEK_BLOB_DST=0x{PEEK_BLOB_DST:x} is outside the 32-bit BL reach "
                 f"from 0x{PEEK_SITE + 4:x} (+/-0x1000000)")
    # site2's 8-byte window is mov #hi / lsl #12 / add #lo / blx, all 16-bit: hi (bits
    # 12..23) must fit an 8-bit mov, lo (bits 0..11) an 8-bit add (this GAS emits no
    # 12-bit 16-bit ADD imm) - so bits 8..11 of TRAMP must be zero, which only
    # 0x1000-alignment guarantees. .align 12 on entry_trampoline makes lo = 1; assert both.
    if tramp >= 0x1000000 or (tramp & 0xFFF) > 0xFF:
        sys.exit(f"error: TRAMP=0x{tramp:x} out of range for the site2 8-byte window "
                 f"(need TRAMP < 0x1000000 and lo12 <= 0xFF; keep entry_trampoline "
                 f"0x1000-aligned via .align 12 in stage1.S)")
    data = to_binary(syms, tramp, original_word)
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
    ap.add_argument("--peek-original", action="store_true",
                    help=f"splice the stock's original word 0x{PEEK_ORIGINAL_WORD:08x} (BL get_String8) "
                         f"at 0x{PEEK_SITE:x} instead of the BL.W to the gap copy (PEEK_BLOB_DST): a "
                         f"control build byte-identical to pristine stock at that site")
    args = ap.parse_args()
    original_word = PEEK_ORIGINAL_WORD if args.peek_original else None
    build(args.output, args.source, original_word)
    return 0


if __name__ == "__main__":
    sys.exit(main())
