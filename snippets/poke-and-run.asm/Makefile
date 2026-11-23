# Makefile — build the poke-and-run buzz blob (assembly) and drive the panel.
#
# Targets:
#   make          build buzz_blob.bin (gitignored; run.sh needs it)
#   make run      build + poke the blob into SDRAM 0x650000 and blx it (run.sh)
#   make verify   read back the TIM5/SYS registers and print the fingerprint (verify.sh)
#   make clean    remove build artifacts
#
# Env for run/verify: PANEL_PORT (required) — see ../common/common.sh.

CC      := arm-none-eabi-gcc
OBJCOPY := arm-none-eabi-objcopy
CPU     := -mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16

all: buzz_blob.bin

buzz.o: buzz_blob.S
	$(CC) $(CPU) -O2 -x assembler -c buzz_blob.S -o buzz.o

buzz_blob.elf: buzz.o buzz_blob.ld
	$(CC) $(CPU) -nostdlib -nodefaultlibs -T buzz_blob.ld buzz.o -o buzz_blob.elf

buzz_blob.bin: buzz_blob.elf
	$(OBJCOPY) -O binary buzz_blob.elf buzz_blob.bin

run: buzz_blob.bin
	sh run.sh

verify:
	sh verify.sh

clean:
	rm -f buzz.o buzz_blob.elf buzz_blob.bin

.PHONY: all run verify clean
