# Stage1 bootloader build.
#
# Wraps build.py (the single build entry point): gcc -> elf -> objcopy -> bin ->
# pad -> fw_pack.pack() -> TFWriter_AiHmiT7.bin.make. Keep it thin; build.py does
# the CRC verify.

CC       = arm-none-eabi-gcc
OBJCOPY  = arm-none-eabi-objcopy

SOURCE   = minimal_stage1.S
ELF      = stage1_loader.elf
OUTPUT   = TFWriter_AiHmiT7.bin.make

PY       = python3
BUILD    = $(PY) build.py

all: $(OUTPUT)

# build.py compiles, packs, verifies, and writes OUTPUT (default repo-root image).
$(OUTPUT): $(SOURCE) linker.ld build.py
	$(BUILD) -o $@ -s $(SOURCE)

# Convenience: rebuild the ELF only (objdump / gdb).
elf: $(ELF)
$(ELF): $(SOURCE) linker.ld
	$(CC) -mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16 -O2 \
	      -ffunction-sections -fdata-sections -nostdlib -nostartfiles -nodefaultlibs \
	      -Wall -Wextra -I. -DSKIP_MITMY_POLL $(SOURCE) -T linker.ld -o $@

# Unscramble + dump the image to confirm it round-trips and entry == bx lr.
check: $(OUTPUT)
	$(PY) ../tools/fw_unscramble.py $(OUTPUT) /tmp/_stage1_plain.bin
	$(CC) $(OBJCOPY) -O binary $(ELF) -o /tmp/_stage1.elf.bin || true
	$(OBJCOPY) -O binary $(ELF) /tmp/_stage1.elf.bin
	xxd -l 16 /tmp/_stage1_plain.bin

clean:
	rm -f $(ELF) $(OUTPUT) stage1_loader.bin stage1_loader.padded.bin

.PHONY: all elf check clean
