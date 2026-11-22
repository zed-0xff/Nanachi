# Stage1 bootloader build.
#
# Wraps build.py (the single build entry point): gcc -> elf -> objcopy -> bin ->
# pad -> fw_pack.pack() -> TFWriter_AiHmiT7.bin.make. Keep it thin; build.py does
# the CRC verify.

CC       = arm-none-eabi-gcc
OBJCOPY  = arm-none-eabi-objcopy

SOURCE   = stage1.S
# The cmd.S include tree: stage1.S does `.include "cmd.S"`, which `.include`s the three
# theme files. gcc follows .include but make does not, so list them here explicitly or
# edits to them are not seen as a reason to rebuild. (Not a *.S wildcard: that would also
# match the unrelated stage1_helloworld.S / stage1_minimal.S experiments.)
BLOB_SRCS = cmd.S cmd_peek.S cmd_poke.S cmd_fun.S

ELF      = stage1_loader.elf
OUTPUT   = TFWriter_AiHmiT7.bin.make

PY       = python3
BUILD    = $(PY) build.py

all: $(OUTPUT)

# build.py compiles, patches, packs, verifies, and writes OUTPUT (default repo-root image).
$(OUTPUT): $(SOURCE) $(BLOB_SRCS) linker.ld build.py patch1.S patch2.S
	$(BUILD) -o $@ -s $(SOURCE)

# Convenience: rebuild the ELF only (objdump / gdb).
elf: $(ELF)
$(ELF): $(SOURCE) $(BLOB_SRCS) linker.ld
	$(CC) -mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16 -O2 \
	      -ffunction-sections -fdata-sections -nostdlib -nostartfiles -nodefaultlibs \
	      -Wall -Wextra -I. -DSKIP_MITMY_POLL $(SOURCE) -T linker.ld -o $@

# Unscramble + dump the image to confirm it round-trips and entry == bx lr.
check: $(OUTPUT)
	$(PY) ../tools/fw_unscramble.py $(OUTPUT) /tmp/_stage1_plain.bin
	$(CC) $(OBJCOPY) -O binary $(ELF) -o /tmp/_stage1.elf.bin || true
	$(OBJCOPY) -O binary $(ELF) /tmp/_stage1.elf.bin
	xxd -l 16 /tmp/_stage1_plain.bin

# Device test: run test_device.sh (peek/poke/fun/fur) against a device that is
# already running this image. The script does all the work and needs PANEL_PORT.
test: $(ELF)
	bash test_device.sh

clean:
	rm -f $(ELF) $(OUTPUT) stage1_loader.bin stage1_loader.padded.bin

.PHONY: all elf check test clean
