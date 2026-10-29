# Stage0 bootloader

Minimal ARM stage1 bootloader for the SoVol SV08MAX TFT screen (TJC4827X243, AiHmiT7,
STM32 @ 200 MHz). It runs before the stock firmware, beeps the board buzzer once via
direct GPIO + timer hardware (bypassing the TJC interpreter), then hangs until a power
 cycle. This is the "does it beep at boot?" proof-of-concept loader — no twfile, no UART
 interpreter traffic, no JPEG/logo draw.

## How it runs

The stage-0 loader (`loader.c` `sub_20002F38` in the stock firmware) reads the SD file into
RAM `0x80000`, sets `VTOR=0x80000`, takes `MSP` from vector dword 0, and jumps to the reset
vector (dword 1). Because the image runs at `0x80000`, the vector table already holds those
absolute addresses.

The container is an XOR key plus two CRCs (`fw_pack.pack` / `fw_unscramble`); the length
must be `≥0x800`, a multiple of 4, and `< 0xC0000`. `build.py` enforces all of that.

## Toolchain

`arm-none-eabi-gcc` / `arm-none-eabi-objcopy` (Cortex-M4, thumb). The build uses pure
assembly deliberately: a C entry cannot link here because `-nodefaultlibs` drops newlib's
`stdint.h`.
