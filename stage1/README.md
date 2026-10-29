# Stage1 bootloader

Minimal ARM stage1 loader for the SoVol SV08MAX TFT screen (TJC4827X243, AiHmiT7, Gree Edgeless GM6721-family
dual Cortex-M4 @ 200 MHz, not an STM32). It runs from the SD card before the stock firmware, plays a short
"ta-daa" on the board buzzer by driving IO7 (GPIOI pin 3, TIM5_CH4 PWM) directly through the SYS / GPIO / TIM5
registers (bypassing the TJC interpreter), then returns to the stage-0 loader, which goes on and boots the stock
firmware as usual. It is the "does custom code run at boot?" proof of concept: no twfile, no UART interpreter
traffic, no JPEG/logo draw.

Works on the real screen. The register sequence and what is still unverified are described in the header comment of
`stage1.S`.

## How the loader runs the image

The stage-0 loader (`ldr_main` @0x20002F38 in the IDB) looks for `TFWriter_AiHmiT7.bin.make` on the SD card, reads it to
RAM at 0x80000, checks the container (below) and unscrambles it in place. Then `ldr_exec` / `ldr_exec_`
(@0x200015A4 / @0x20001DE0):

1. copy the first 0x800 bytes to the load address, set `VTOR` = load address;
2. `msr msp, [image + 0]`: **word 0 of the image becomes the stack pointer**;
3. `blx [image + 4]`: **word 1 is the entry address** (Thumb bit set);
4. when the entry returns, `pop {r4-r6,pc}` runs **on the new stack**, then `ldr_exec` pops its own frame and
   `ldr_main` continues with the normal firmware boot.

Only those two words are read. The rest of a vector table matters only for exceptions (interrupts are masked by the
loader), so the image keeps just the 16 system vector slots.

Consequences for the image (all enforced or documented in `stage1.S` / `linker.ld`):

* **Word 0 must be `0x20000648`**, not the loader's initial SP `0x20000680`. It is the loader's real SP at the `blx`
  (0x680 - 16 `ldr_main` - 24 `ldr_exec` - 16 `ldr_exec_`). With any other value the `bx lr` return pops garbage and the
  board hangs. The stack below it is free, so the image may `push`/`pop` a little (it does, for r4/r5).
* **Code, vectors and the literal pool must end below `0x1C8`.** `fw_pack.pack()` writes the container header (CRC32s,
  length) into image offsets `0x1C8..0x1DB` and the loader owns `0x1C8..0x267`. Anything of yours there is overwritten:
  an earlier version lost its timer base address that way. `linker.ld` has an `ASSERT` for it.
* **Registers:** r4-r11 belong to the loader. The code uses r0-r3, and r4/r5 only between a `push` and `pop`.
* **Timing:** the image runs from SDRAM, where instruction fetches are slow. Do not use a delay loop calibrated for
  200 MHz (it ran several times too long). Note lengths are measured with the timer itself, by counting `TIM5_CNT`
  wrap-arounds (one per PWM period).

The image runs at 0x80000 (linked there, `linker.ld`), so the absolute addresses in its vector words are correct as is.

## Container

The file is the image wrapped in the loader's container format (an XOR key plus two CRCs; `tools/fw_pack.py`
`pack()` / `tools/fw_unscramble.py`). The length must be >= 0x800, a multiple of 4 and < 0xC0000; `build.py` pads and
verifies the CRCs.

## Melody

The tune is the `melody` table at the end of `stage1.S`: one `note <Hz>, <ms>` or `rest <ms>` line per note, a zero word at
the end. The default is C6 110 ms, 40 ms rest, G6 520 ms. A piezo buzzer is loudest around 2-4 kHz, so keep the notes
high. Each note stops the timer and zeroes the counter before loading its `ARR` / `CCR4`, so a shorter period cannot leave
the counter above `ARR`. The whole image has to stay below `0x1C8` bytes (currently `0x19C`).

## Build

Toolchain: `arm-none-eabi-gcc` / `arm-none-eabi-objcopy` (Cortex-M4, thumb). The source is pure assembly on purpose: a C
entry cannot link here because `-nodefaultlibs` drops newlib's `stdint.h`. This assembler's Thumb-16 mode has no
flag-setting immediates and no `.w` suffix, hence `sub` + `cmp` and a macro that loads full register addresses.

```
make elf                              # stage1_loader.elf only (objdump / gdb); fails if the image reaches 0x1C8
make                                  # build.py: gcc -> elf -> bin -> pad -> fw_pack.pack -> TFWriter_AiHmiT7.bin.make
python3 build.py -o out.make          # same, to a path of your choice
```

Copy the resulting `TFWriter_AiHmiT7.bin.make` to the root of a FAT-formatted SD card and power the screen up with the card
inserted. Remove the card and the screen boots from its flash as before; the flash is not touched.

## Unverified

* The timer clock in the stage-0 environment (the stock firmware assumes 200 MHz; the tone pitch and note lengths scale
  with it).
* The polarity (`CCER = 0x3333` is copied from the firmware) and the exact pin (IO7 = PI3 comes from the firmware's `beep`
  path and the BSP pin tables, not from a schematic).
