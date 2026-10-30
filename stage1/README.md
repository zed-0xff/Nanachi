# Stage1 bootloader

Minimal ARM stage1 loader for the SoVol SV08MAX TFT screen (TJC4827X243_011C, AiHmiT7, Gree Edgeless GM6721-family
dual Cortex-M4 @ 200 MHz, not an STM32). It runs from the SD card before the stock firmware: lights the panel's
backlight, draws "HELLO WORLD" into a real framebuffer on top of a solid-colour fill by driving VOUT (the RGB/TTL
LCD timing controller) directly, plays a short "ta-daa" on the board buzzer (TIM5 PWM on GPIOI pin 3), then returns
to the stage-0 loader, which goes on and boots the stock firmware as usual. All of it drives real SoC peripherals
directly through their registers (SYS / GPIO / TIM5 / TIM8 / VOUT / PLLSAI) - no twfile, no UART interpreter
traffic, no hooking into the stock app firmware's own code or addresses (deliberately: a from-scratch bring-up is
not tied to one specific firmware build the way patching the stock binary in place would be).

Confirmed working on the real screen: the buzzer tune, the backlight, a solid colour fill of the whole panel via
VOUT's background colour, a full framebuffer/layer (an actual addressable buffer in SDRAM, not just VOUT's flat
background-colour register), and legible, correctly-oriented text drawn into that framebuffer with a small
hand-rolled bitmap font. Getting each of these right took several real hardware iterations apiece - each wrong
assumption produced a different, specific visible symptom (nothing at all -> stable PLL tone but uniform grey ->
still grey after fixing the PLL divider -> correct colour after fixing a pin-mode register; then, for the
framebuffer, uniform grey again -> a cleanly bounded black/grey box once window-size arithmetic was fixed -> solid
colour once the framebuffer's address was corrected for the bus master that actually reads it; then, for text
specifically, legible but rotated 180 degrees until the pixel-addressing formula was flipped to match how this
panel's glass is actually scanned). See the project memory `vout-panel-bringup` for the full blow-by-blow if a
similar "it should work but doesn't" bring-up bug shows up again. The header comment of `stage1.S` has the
register-level sources for everything.

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
  board hangs. The stack below it is free, so the image may `push`/`pop` a little (it does, for r4/r5/r6).
* **The container-header zone, image offsets `0x1C8..0x267`, gets overwritten** by `fw_pack.pack()` with CRC32s and
  the length - anything of yours there is silently corrupted (an earlier version lost its timer base address that
  way). This used to cap the whole image at that size; `linker.ld` now places the vector table at offset 0 and all
  real code/data at file offset `0x800` (the container's own minimum-image-size requirement), so the header zone is
  pure padding and there is no practical size limit any more.
* **Registers:** r4-r11 belong to the loader. The code uses r0-r3 freely, and r4-r11 (and r12, which nothing outside
  this image cares about and is never saved) only between a matching `push`/`pop` pair - `r6` currently spans the
  whole function (it carries the "did PLLSAI really lock" flag used to pick which melody plays), and `draw_text`
  pushes/pops `r3`+`r4-r11`+`lr` as one block around itself and whatever `draw_glyph` does inside it.
* **Timing:** the image runs from SDRAM, where instruction fetches are slow and unpredictable. Do not use a delay
  loop calibrated for 200 MHz (an earlier version did, and ran several times too long). Both the buzzer note lengths
  and the PLLSAI-stable wait are measured/bounded by polling a peripheral's own counter or status bit, not by
  counting instructions.

The image runs at 0x80000 (linked there, `linker.ld`), so the absolute addresses in its vector words are correct as is.

## Container

The file is the image wrapped in the loader's container format (an XOR key plus two CRCs; `tools/fw_pack.py`
`pack()` / `tools/fw_unscramble.py`). The length must be >= 0x800, a multiple of 4 and < 0xC0000; `build.py` pads and
verifies the CRCs.

## Panel (VOUT)

Flashes the whole panel a solid colour (`VOUT_BCCR`, currently red - no framebuffer/layer yet, just the background
colour, which this VOUT IP shows directly with zero active layers). Confirmed-correct register sequence, in order:

1. Oscillators + reference select: enable HIRC/LIRC, enable HOSC/LOSC (their enable bit is active-low, opposite
   polarity from HIRC/LIRC), then select HOSC as this PLL cluster's reference (`REFCLK_SRC_CTRL`).
2. PLLSAI (VOUT's dedicated pixel-clock PLL, separate from the main system PLL): enable, wait for `CMUST` bit 7,
   *then* overwrite its divider register (`PLLSAI_CTRL2 = 0xAC020207`) - enabling before setting the dividers, and
   using this exact constant rather than the vendor HAL's generic default, both matter (see `vout-panel-bringup`
   project memory for why).
3. `CLKSRC[3]` VOUT_DIV divider, port E (all 16 pins, RGB565 data) and port F (pins 0-4: HSYNC/VSYNC/DE/PCLK) pin
   mode + alternate-function registers. Port E's pin-mode value must be `0x55555555` (alternate function on every
   pin) - `0xFFFFFFFF` looks like "all bits set, must be right" but is actually analog mode for every pin, i.e. all
   16 data lines disconnected from VOUT. That one bug alone produced a uniform grey screen no matter what colour or
   clock settings were otherwise correct.
4. The timing registers themselves (SSCR/BPCR/AWCR/TWCR, formulas from this panel's `g_scr_infos[0]` entry) and
   `BCCR` (background colour) + `GCR` (enable).

## Framebuffer / layer 0

A real, addressable framebuffer in SDRAM, shown through VOUT's layer 0 (not just the flat `BCCR` background colour
above) - register map and formulas from the vendor HAL (`VOUT_Layer_TypeDef` + `VOUT_LAYER(base,n)` in
`ext/SoC/BPI-EAI80-bsp` `gm_ll_vout.h`, cross-checked against this firmware's own `sub_21D9C`). Two bugs here, found
the same way as the background-colour ones - by watching what a wrong assumption actually looks like on hardware:

* The window "stop" value (`WHPCR`/`WVPCR`'s high halves) is the panel width/height itself (480/272), not width-1/
  height-1 as a generic LTDC-style analogy would suggest. This firmware's own `dword_762118 = 0x011001E0` (packed
  width/height) is used as-is, with no "-1" anywhere.
* **`CFBAR` (the framebuffer address) needs SDRAM's native bus address, not the address the CPU itself uses to read
  and write the same bytes.** VOUT fetches the framebuffer as an independent AHB bus master; the CPU's own code/data
  addresses (this image at `0x80000`, a test framebuffer at `0x200000`, etc.) go through boot-time address
  remapping that VOUT's raw hardware register does not share. The BSP's `SDRAM_BASE` (`soc_gm6721x.h`:
  `FMC_BASE + 0x60000000 = 0xC0000000`) is the address VOUT actually needs: `CFBAR = SDRAM_BASE + <the CPU-side
  address the buffer was filled at>`. Confirmed by a differential test: a small window (so a wrong address would
  show as an isolated wrong-coloured box rather than breaking the whole screen the way the background-colour bugs
  did) showed a clean black/grey box at the plain CPU-side address, and solid colour once `SDRAM_BASE` was added.
  **Any other DMA-capable peripheral on this SoC (e.g. the IMP blitter) almost certainly needs the same adjustment**
  for a buffer the CPU allocated at a low address - check this before repeating the same debugging loop.

## Text

A small hand-rolled 5x7 bitmap font (`glyph_H`/`glyph_E`/... in `stage1.S`, not a real font file - no licensing
question, and only as many letters as "HELLO WORLD" needs; anything else falls back to a blank glyph), scaled up
6x and blitted into the framebuffer by `draw_text`/`draw_glyph`, drawn on top of the solid-colour fill from a real
hardware test showed the text legible but **rotated 180 degrees**. VOUT has no hardware mirror/flip bit (checked:
neither `VOUT_Device_T` nor the per-layer struct has one - this IP is a plain timing controller, not a blitter), so
this panel's glass is simply scanned starting from the opposite corner than a plain top-left-origin framebuffer
assumes, and whatever draws into it has to pre-compensate - this is a property of the panel, not a bug specific to
this test. Fix: address pixels as a backward offset from the *last* pixel instead of a forward offset from the
first - `FB_BOTTOM_RIGHT = FB_BASE + (HEIGHT-1)*PITCH + (WIDTH-1)*BPP`, then
`address(x,y) = FB_BOTTOM_RIGHT - y*PITCH - x*BPP`. Only `draw_glyph`'s per-pixel addressing needed this; the solid
fill doesn't care about direction, and the character-advance direction in `draw_text` didn't need to change either
(the same formula already compensates for both axes consistently).

## Backlight

A separate PWM, TIM8 channel 2 on GPIOC pin 9 (AF5) - VOUT can be producing a perfect signal while the panel stays
dark if this isn't also brought up, since the backlight LED has its own independent enable. `TIM8_BDTR` bit 15 (MOE,
Main Output Enable) matters here specifically because TIM8 is an "advanced" timer (break/dead-time unit); without it
the channel output stays off regardless of the rest of the PWM setup. The duty cycle is inverted (`CCER`'s polarity
bit): a *small* `TIM8_CCR2` is *bright*, not a large one.

## Melody

The tune is the `melody` table near the end of `stage1.S`: one `note <Hz>, <ms>` or `rest <ms>` line per note, a zero
word at the end. The default is C6 110 ms, 40 ms rest, G6 520 ms. A piezo buzzer is loudest around 2-4 kHz, so keep
the notes high. Each note stops the timer and zeroes the counter before loading its `ARR` / `CCR4`, so a shorter
period cannot leave the counter above `ARR`.

A second table, `melody_pllsai_timeout`, plays instead if PLLSAI never reported stable (three identical low beeps -
unmistakably different by ear from "ta-daa", a cheap audible yes/no with no UART involved). Useful as a template for
further "which branch did it take" diagnostics without adding real logging.

## Build

Toolchain: `arm-none-eabi-gcc` / `arm-none-eabi-objcopy` (Cortex-M4, thumb). The source is pure assembly on purpose: a C
entry cannot link here because `-nodefaultlibs` drops newlib's `stdint.h`.

`.syntax unified` is required (set near the top of `stage1.S`, before the first `.section`) once the code goes
beyond low registers (r0-r7) and simple immediates - without it, GNU `as` defaults to legacy "divided" Thumb syntax,
which is *stricter* than real Thumb-1 hardware: it rejects r8-r12 outright and most non-trivial immediate forms
("lo register required", "instruction not supported in Thumb16 mode") instead of picking a wider Thumb-2 encoding,
even though this CPU fully supports Thumb-2. The buzzer/VOUT code happened to only ever need low registers and
simple forms, so this didn't surface until `draw_text`/`draw_glyph` needed r8-r12 for the text cursor and pixel math.

Long, straight-line functions also need periodic literal-pool flushes (`b 1f` / `.ltorg` / `1:`, several already in
`stage1.S`): without them, GNU `as` puts every `ldr rX, =value` literal in one pool at the end of the function, and
once a function is long enough the earliest such loads fall outside the 16-bit `ldr`'s +/-1020-byte reach
("invalid offset, value too big"). The `b`+`.ltorg`+label pattern dumps the pool without falling through into it as
data - add another one if this error reappears after adding more code.

```
make elf                              # stage1_loader.elf only (objdump / gdb); fails if the image reaches 0x1C8
make                                  # build.py: gcc -> elf -> bin -> pad -> fw_pack.pack -> TFWriter_AiHmiT7.bin.make
python3 build.py -o out.make          # same, to a path of your choice
```

Copy the resulting `TFWriter_AiHmiT7.bin.make` to the root of a FAT-formatted SD card and power the screen up with the card
inserted. Remove the card and the screen boots from its flash as before; the flash is not touched.

## Unverified

* The timer clock in the stage-0 environment (the stock firmware assumes 200 MHz; the tone pitch and note lengths scale
  with it) - the buzzer tone sounds right, but this hasn't been measured with a scope.
* The buzzer's polarity (`CCER = 0x3333` is copied from the firmware) and exact pin (IO7 = PI3 comes from the
  firmware's `beep` path and the BSP pin tables, not from a schematic).
* The panel colour fill is confirmed visually (plain red, a full-screen framebuffer fill, and legible text, all shown
  correctly) but not measured for exact timing margins - it is plausible this works with some slack in the
  HSYNC/VSYNC/porch values rather than needing them exact.
* The touch controller (software I2C, see the `touch-hardware-i2c` project memory) has not been wired into `stage1.S`
  at all yet.
* The font only covers the letters "HELLO WORLD" needs (H, E, L, O, W, R, D, space); anything else renders blank.
  Fine for more test strings made of those letters, not a general-purpose font yet.
