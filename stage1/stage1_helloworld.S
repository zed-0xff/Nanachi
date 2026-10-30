/*
 * stage1 diagnostic loader: flashes the panel white and plays a short "ta-daa" on the board buzzer on
 * entry, then returns to the stage-0 loader.
 *
 * Entry path: the loader runs this image via ldr_exec's `BLX struct[4]`
 * (struct[4] = this entry). The return address from that BLX sits in LR, so a
 * single `bx lr` hands control straight back to the loader — no stack access,
 * no reset-vector stack frame. `bx` (not `mov pc`) is used because BLX sets the
 * Thumb bit in LR and `bx` clears it; `mov pc, lr` would leave it set and jump
 * to the wrong state.
 *
 * A vector table (MSP + reset slot) is still emitted so the image is a valid
 * vector-table image the loader can VTOR to and read SP from
 * (linker.ld pulls (.vector_table) to the front of .text). Pure assembly.
 *
 * ==========================================================================
 *  Hardware (reverse-engineered from the stock firmware, not from a datasheet)
 * --------------------------------------------------------------------------
 *  The SoC is a Gree Edgeless GM6721-family dual Cortex-M4 (not an STM32); the
 *  register layouts below come from the BSP in ext/SoC/BPI-EAI80-bsp and were
 *  checked against the firmware's own `beep` command (cmd_beep @0x21614,
 *  cfgpio_apply @0x216a8, TIM5 setup @0x1FA40 in the IDB).
 *
 *  `beep` drives extended IO 7 (sysvars pio7/pwm7) as a PWM output:
 *    IO7 = GPIOI pin 3 = TIM5_CH4 (alternate function 5).
 *  This file repeats what the firmware does for that command:
 *    1. enable the GPIO and TIM5 clocks (SYS ENABLECLK0 / ENABLECLK2)
 *    2. pulse the TIM5 software reset (SYS IPSWRST[2] bit 20, active low)
 *    3. pin PI3: IOMODE[8] = 1 (alternate function), IOAFR[16] nibble 3 = 5,
 *       pull-up / pull-down / open-drain cleared, GPIOI.OMCR bit 3
 *    4. TIM5: PSC = 99 (200 MHz / 100 = 2 MHz), CCMR1 = CCMR2 = 0x7070 (PWM), CCER = 0x3333
 *    5. for every note of the `melody` table: ARR = 2 MHz / tone, CCR4 = ARR / 2, CR1 = 1, then wait for the
 *       note's length by counting TIM5 periods (CNT wrap-arounds); finally stop the timer
 *
 *  NOT verified on hardware: the 200 MHz timer clock in the stage-0 environment
 *  (the firmware assumes it; the beep length scales with the real timer clock) and the polarity
 *  (CCER = 0x3333 is copied from the firmware). The firmware's default tone is 2760 Hz / 50 %.
 *
 *  The length is measured with the timer itself, not with a delay loop: the image runs from SDRAM where
 *  instruction fetches are slow, and a loop calibrated for 200 MHz took several times too long.
 *
 *  Toolchain note: this assembler's Thumb-16 mode does not accept flag-setting
 *  immediates (SUBS / ADDS), so the wait loop uses `sub` + `cmp` instead.
 *
 * --------------------------------------------------------------------------
 *  Panel (VOUT, the RGB/TTL LCD timing controller at 0x40026000)
 * --------------------------------------------------------------------------
 *  `porting.md` flagged the panel interface as the single biggest unidentified driver. The stock
 *  firmware's own `init_lcd` (@0x13340 in the IDB) answers it for this exact unit: this screen is the
 *  generic-RGB-panel branch (model code 0x431 in `g_scr_info.field_14`, panel entry `g_scr_infos[0]`,
 *  width=480 height=272), driven by the VOUT peripheral, not a serial/SPI smart panel (that's a different
 *  branch of the same function, for a different model code).
 *
 *  Register formulas below are read directly off `sub_F0AC` (@0xF0AC), which programs VOUT_SSCR/BPCR/
 *  AWCR/TWCR/GCR/BCCR from a `ScrInfo` timing struct - confirmed, not guessed:
 *    SSCR = (HSW-1)<<16 | (HFP-1)
 *    BPCR = (HSW+HBP-1)<<16 | (HFP+VSW-1)
 *    AWCR = (W-1+HBP+HSW)<<16 | (H-1+VSW+HFP)
 *    TWCR = (HSW+HBP+W+VFP-1)<<16 | (HFP+VSW+H+VBP-1)
 *    GCR  bit 0 = enable (the rest of GCR comes from per-panel flags that are 0 for this unit)
 *    BCCR = background colour, byte0/1/2 (channel order not identified - set all three the same to avoid
 *           the question for a plain white test)
 *  Pin / clock setup is read off the same function's generic-panel branch: VOUT clock+reset is
 *  ENABLECLK0/IP_RST_CTRL1 bit 19 (`SYS_IP_SW_RESET_VOUT_POS` in the BSP; the enable-register bit position
 *  is assumed to mirror it, as it does for every other peripheral seen so far, e.g. TIM5).
 *
 *  That ENABLECLK0 bit is only the AHB/APB bus clock, though - VOUT also needs a pixel ("dot") clock, which
 *  this file did not configure in its first version (likely why an earlier test showed no white flash even
 *  though the buzzer, proof the image ran, still worked). The vendor HAL spells this out
 *  (ext/SoC/BPI-EAI80-bsp KelisSDK/.../driver/clock/gm_hal_clock.c, PERIPHERAL_VOUT_MASK case): VOUT's pixel
 *  clock comes from a dedicated PLL, PLLSAI (SYS_BASE+0x198/0x19C), not the main system PLL, and must be
 *  enabled and stable before the CLKSRC[3] VOUT_DIV divider (bits [12:8], SYS_BASE+0xA0) has any effect -
 *  this is also where the firmware's own `init_lcd` case 0x431 (our panel) writes divider value 0x15 (21),
 *  now matched here. The HAL only touches the *shared* PLL-reference-clock mux
 *  (SYS_BASE+0x90, SYS_PLLREF_SEL) when no PLL at all is stable yet; since this image always runs after a
 *  full system boot (stage-0 loader, SDRAM already up), some PLL is already stable and that shared mux is
 *  deliberately left alone here - rewriting it could disturb the main system clock the CPU itself depends
 *  on, for no benefit (PLLSAI can lock onto whatever reference is already selected).
 *
 *  CORRECTION, found after a real hardware test showed a PLLSAI-stable tone ("ta-daa") but a grey/garbled
 *  panel instead of a colour: this file's first version left PLLSAI's divider register (PLLSAI[1],
 *  SYS_BASE+0x19C: DIVP/DIVQ/DIVR/DIVN) untouched, trusting the vendor HAL's own comment that it holds sane
 *  power-on defaults and "should not [be] modif[ied]" - that generic HAL path (`HAL_CLOCK_PLLSAIcmd()`,
 *  which only sets PLLSAI[0]'s VCO/CPC bits before enabling) is not what this firmware actually runs.
 *  The real boot path is `sub_27630` (IDB 0x27630, called once from `init_2D850` before `main`): it enables
 *  PLLSAI[0] with no VCO/CPC write at all (`PLLSAI_CTRL1 |= 1`), waits for the same CMUST stable bit, and
 *  only *then* overwrites the whole divider register: `PLLSAI_CTRL2 = 0xAC020207` (DIVN=0xAC, DIVR=2, DIVQ=2,
 *  DIVP=7 - DIVQ/DIVR differ from the HAL's documented "default value" comment, which is why leaving the
 *  register alone locked PLLSAI at the wrong frequency: a real lock, confirmed stable, just on the wrong
 *  clock, which a static colour fill cannot distinguish from "no clock" by itself). This file now copies
 *  that exact sequence and constant instead of the generic HAL path. Pinmux: port E
 *  (`IO_MOD_REG5`/`AF_SEL_REG9`/`AF_SEL_REG10`), all 16 pins -> AF2 (the panel's 16 RGB565 data lines);
 *  port F (`IO_MOD_REG6`/`AF_SEL_REG11`) pins 0-4 only -> AF2 (HSYNC/VSYNC/DE/PCLK + one more); pins 5-6 of
 *  port F are left alone on purpose - those are the touch RST/INT pins (see project memory
 *  `touch-hardware-i2c`), and this firmware function never touches them.
 *
 *  What this file does NOT attempt yet: an actual framebuffer / text. `init_lcd` also programs a
 *  per-layer block (window position, pixel format, buffer address) via `sub_21D9C` (@0x21D9C), but the
 *  decompiled field types there are too mushy to trust blindly (the IDB's `S2C` struct is untyped bytes,
 *  and the arithmetic reads oddly) - wiring it up wrong risks a silent blank screen with nothing to tell
 *  us why. This step only proves the timing/clock/pinmux above by flashing the whole panel one solid
 *  colour (VOUT's background colour, no active layer needed). Once that is confirmed on hardware, the
 *  next step is a layer with a solid-colour framebuffer (simpler than text), then real glyphs.
 *
 *  NOT verified on hardware. The flash will only be visible briefly: the stock firmware's own `init_lcd`
 *  reprograms all of this from scratch a moment later during its own normal boot.
 * ========================================================================== */

/* ==========================================================================
 *  Register map
 * ========================================================================== */

/* ---- SYS block (0x40000000): clocks, resets and pin multiplexing ----
 * Offsets are given from SYS_BASE. Names in brackets are the BSP names (soc_gm6721x.h, Sys_Device_T)
 * and, in brackets after them, the names used in the IDB. */
.equ SYS_BASE,        0x40000000
.equ SYS_IPSWRST2,    0x78                 @ IPSWRST[2] (IP_RST_CTRL3): software reset of peripherals; bit 20 = TIM5,
                                           @   0 = held in reset, 1 = running (the firmware pulses it 0 -> 1)
.equ SYS_ENCLK0,      0x80                 @ ENABLECLK[0] (CLK_EN_CTRL1): bit 1 = GPIO clock
.equ SYS_ENCLK2,      0x88                 @ ENABLECLK[2] (CLK_EN_CTRL3): bit 20 = TIM5 clock
.equ SYS_IOODC4,      0x248                @ IOODC[4] (IO_OD_REG5): open-drain enable, 1 bit per pin;
                                           @   register n covers ports 2n and 2n+1 (n = 4: port I in bits 0..15,
                                           @   port J in bits 16..31)
.equ SYS_IOPULLUP4,   0x278                @ IOPULLUP[4] (IO_PU_REG5): pull-up enable, same layout as IOODC
.equ SYS_IOPULLDOWN4, 0x290                @ IOPULLDOWN[4] (IO_PD_REG5): pull-down enable, same layout as IOODC
.equ SYS_IOMODE8,     0x2E4                @ IOMODE[8] (IO_MOD_REG9): one 32-bit register per port (8 = port I),
                                           @   2 bits per pin: 0 = GPIO, 1 = alternate function, 3 = analog
.equ SYS_IOAFR16,     0x330                @ IOAFR[16] (AF_SEL_REG17): alternate-function number, 4 bits per pin,
                                           @   two registers per port (16 = port I pins 0..7, 17 = pins 8..15)

.equ SYS_IPSWRST1,    0x70                 @ IPSWRST[1] (IP_RST_CTRL1): bit 19 = VOUT (SYS_IP_SW_RESET_VOUT_POS
                                           @   in the BSP), bit 1 = GPIO
.equ SYS_IOMODE4,     0x2D4                @ IOMODE[4] (IO_MOD_REG5) = port E
.equ SYS_IOMODE5,     0x2D8                @ IOMODE[5] (IO_MOD_REG6) = port F
.equ SYS_IOAFR9,      0x310                @ IOAFR[9]  (AF_SEL_REG9)  = port E pins 0..7
.equ SYS_IOAFR10,     0x314                @ IOAFR[10] (AF_SEL_REG10) = port E pins 8..15
.equ SYS_IOAFR11,     0x318                @ IOAFR[11] (AF_SEL_REG11) = port F pins 0..7
.equ SYS_IOPU_EF,     0x270                @ IOPULLUP pair register for ports E (bits 0..15) and F (bits 16..31)
.equ SYS_IOPD_EF,     0x288                @ IOPULLDOWN, same pairing as IOPU_EF

.equ ENCLK0_GPIO,     (1 << 1)             @ GPIO block clock (probably already on, set again to be sure)
.equ ENCLK0_VOUT,     (1 << 19)            @ VOUT (panel timing controller) bus clock
.equ ENCLK2_TIM5,     (1 << 20)            @ TIM5 clock
.equ IPSWRST1_VOUT,   (1 << 19)            @ VOUT reset bit
.equ IPSWRST2_TIM5,   (1 << 20)            @ TIM5 reset bit

/* ---- VOUT pixel clock: oscillators, reference select, PLLSAI, CLKSRC[3] divider (see the header comment) ----
 * sub_27630 (IDB 0x27630) switches this whole PLL cluster's reference to HOSC (the external crystal) before
 * enabling PLLSAI; skipping that let PLLSAI lock onto whatever reference it already had (almost certainly
 * HIRC, the imprecise internal RC oscillator) - a real, stable lock, just on the wrong clock, which is
 * indistinguishable from "no clock" by a solid colour fill but fatal for a panel's timing. */
.equ SYS_HIRC_CTRL,    0x170
.equ SYS_LIRC_CTRL,    0x174
.equ SYS_HOSC_CTRL,    0x178
.equ SYS_LOSC_CTRL,    0x17C
.equ SYS_REFCLK_SRC,   0x1A0
.equ SYS_PLLSAI0,   0x198                  @ PLLSAI[0] (PLLSAI_CTRL1): bit0 = EN
.equ SYS_PLLSAI1,   0x19C                  @ PLLSAI[1] (PLLSAI_CTRL2): DIVP/DIVQ/DIVR/DIVN, one byte each
.equ SYS_CMUST,     0x1A4                  @ CMU clock status: bit 0 = HIRC, bit 1 = LIRC, bit 7 = PLLSAI stable
.equ SYS_CLKSRC3,   0xA0                   @ CLKSRC[3]: bits [12:8] = VOUT_DIV
.equ CMUST_HIRC_STABLE,   1
.equ CMUST_LIRC_STABLE,   (1 << 1)
.equ PLLSAI_EN,           1
.equ CMUST_PLLSAI_STABLE, (1 << 7)
.equ REFCLK_SRC_MASK, 0x0F03               @ sub_27630's own mask (~0xFFFFF0FC), the field REFCLK_SRC_VAL sits in
.equ REFCLK_SRC_VAL,  0x400                @ sub_27630's exact value: select HOSC as this PLL cluster's reference
.equ PLLSAI_DIV_VAL, 0xAC020207            @ sub_27630's exact value: DIVN=0xAC, DIVR=2, DIVQ=2, DIVP=7 -
                                           @   written only AFTER the stable wait, full overwrite, no read-modify-write
.equ VOUT_DIV_MASK,  (0x1F << 8)
.equ VOUT_DIV_VAL,   (0x15 << 8)           @ 21: the firmware's init_lcd case 0x431 (this panel) value
.equ PLLSAI_WAIT_TIMEOUT, 3000000          @ safety: give up waiting for PLLSAI stable after this many polls
.equ OSC_WAIT_TIMEOUT,    3000000          @ same safety bound, for the HIRC/LIRC stable waits below

/* ---- panel (VOUT, 0x40026000): timing for this unit's 480x272 panel (g_scr_infos[0] in the IDB) ---- */
.equ VOUT_BASE,  0x40026000
.equ VOUT_SSCR,  0x00                      @ (HSW-1)<<16 | (HFP-1)
.equ VOUT_BPCR,  0x04                      @ (HSW+HBP-1)<<16 | (HFP+VSW-1)
.equ VOUT_AWCR,  0x08                      @ (W-1+HBP+HSW)<<16 | (H-1+VSW+HFP)
.equ VOUT_TWCR,  0x0C                      @ (HSW+HBP+W+VFP-1)<<16 | (HFP+VSW+H+VBP-1)
.equ VOUT_GCR,   0x10                      @ bit 0 = enable
.equ VOUT_BCCR,  0x18                      @ background colour (no active layer needed to show it)

/* ---- VOUT layer 0: framebuffer ("Step B", confirmed working after the background-colour-only test) ----
 * Register map from the vendor HAL, not this firmware's decompile (ext/SoC/BPI-EAI80-bsp KelisSDK/.../
 * driver/vout/gm_ll_vout.h: VOUT_Layer_TypeDef + the VOUT_LAYER(base,n) = base + 0x30 + 0x30*n macro, and
 * gm_hal_vout.c's VOUT_SetConfig for the exact WHPCR/WVPCR/CFBLR formulas) - this firmware's own per-layer
 * code (sub_21D9C) was judged too ambiguous to trust (see stage1's header comment history); the vendor HAL
 * is the same STM32-LTDC-shaped register set already confirmed correct for SSCR/BPCR/AWCR/TWCR/GCR/BCCR, so
 * it is trusted here too. */
.equ VOUT_L0_CR,     0x30                  @ bit 0 = LEN (layer enable)
.equ VOUT_L0_WHPCR,  0x34                  @ (window start + AHBP + 1) | (window stop + AHBP) << 16
.equ VOUT_L0_WVPCR,  0x38                  @ (window start + AVBP + 1) | (window stop + AVBP) << 16
.equ VOUT_L0_PFCR,   0x40                  @ pixel format: 2 = RGB565
.equ VOUT_L0_CACR,   0x44                  @ constant alpha, 0..255
.equ VOUT_L0_DCCR,   0x48                  @ default colour (shown where this layer is transparent/outside its window)
.equ VOUT_L0_CFBAR,  0x50                  @ framebuffer address
.equ VOUT_L0_CFBLR,  0x54                  @ (buffer stride in bytes) << 16 | (window width - 1) * bytes/pixel
.equ VOUT_L0_CFBLNR, 0x58                  @ number of lines

.equ VOUT_AHBP, (PANEL_HSW + PANEL_HBP - 1)        @ accumulated horizontal back porch: BPCR's own high half
.equ VOUT_AVBP, (PANEL_HFP + PANEL_VSW - 1)        @ accumulated vertical back porch: BPCR's own low half
.equ VOUT_PF_RGB565, 2

/* ---- text: a hand-drawn 5x7 bitmap font, scaled up and blitted straight into the framebuffer ----
 * Not from any real font file (no license question, and only as many letters as "HELLO WORLD" needs) - each
 * glyph is 7 bytes, one per row, the row's pixels packed into bits [4:0] (bit 4 = leftmost column). Unknown
 * characters (anything not in the small dispatch table in draw_glyph) fall back to glyph_SP (blank), so this
 * is safe to feed any ASCII text, it just won't render letters outside this set. */
.equ GLYPH_W, 5
.equ GLYPH_H, 7
.equ TEXT_SCALE,   6                       @ each font pixel becomes a TEXT_SCALE x TEXT_SCALE block on screen
.equ TEXT_X0,      40
.equ TEXT_Y0,      100
.equ TEXT_COLOR,   0x0000                  @ black, on top of the green test fill
.equ CHAR_ADVANCE, ((GLYPH_W + 1) * TEXT_SCALE)    @ glyph width plus one font-pixel of gap, both scaled

.equ FB_BASE,   0x200000                   @ 2 MiB into SDRAM (address 0 = this image's own memory space, see
                                           @   the boot-contract comment above) - far past this image's own
                                           @   code/data (loaded at 0x80000) and well inside any plausible
                                           @   SDRAM size for this unit (the app firmware's own SP, 0x800000,
                                           @   implies at least 8 MiB). This is the address the CPU itself uses.
@ VOUT reads its framebuffer as a separate AHB bus master, not through whatever address-remap circuitry makes
@ SDRAM appear at low addresses for the CPU's own code/data fetches. The BSP (soc_gm6721x.h) gives SDRAM's own
@ native controller address: `SDRAM_BASE = FMC_BASE + 0x60000000 = 0xC0000000`. A hardware test confirmed
@ this split: shrinking the layer to a small corner window (so a wrong CFBAR would be obvious, rather than
@ just making the whole screen grey like the full-size attempt did) showed a cleanly separated black/greyish
@ box, not the background colour - proof the layer mechanism and window sizing both work, but CFBAR = FB_BASE
@ (the CPU-side address) was reading something other than what the CPU had just written there. CFBAR must be
@ SDRAM_BASE + FB_BASE instead; the CPU-side fill loop still uses the plain FB_BASE address, unchanged.
.equ SDRAM_BASE, 0xC0000000
.equ FB_CFBAR_VAL, (SDRAM_BASE + FB_BASE)
.equ FB_WIDTH,  PANEL_WIDTH
.equ FB_HEIGHT, PANEL_HEIGHT
.equ FB_BPP,    2                          @ RGB565: 2 bytes/pixel
.equ FB_PITCH,  (FB_WIDTH * FB_BPP)
.equ FB_WORDS,  (FB_WIDTH * FB_HEIGHT / 2) @ 32-bit stores, 2 pixels per word (FB_WIDTH is even)

@ A real hardware test showed "HELLO WORLD" legible but rotated 180 degrees: this panel's glass is scanned
@ starting from the opposite corner from what a plain top-left-origin framebuffer assumes. None of VOUT's own
@ registers (checked: VOUT_Device_T and the per-layer struct, neither has a flip/mirror bit - this IP is a
@ plain timing controller, not a blitter) offer a hardware fix, so whatever draws into this framebuffer has to
@ pre-compensate, the same way the real firmware's own renderer must. FB_BOTTOM_RIGHT is the address of the
@ last pixel; draw_glyph (the only thing here that draws position-sensitive content - the solid fill doesn't
@ care about direction) addresses pixels as offsets *backward* from it instead of forward from FB_BASE.
.equ FB_BOTTOM_RIGHT, (FB_BASE + (FB_HEIGHT - 1) * FB_PITCH + (FB_WIDTH - 1) * FB_BPP)
.equ FB_FILL_PIXEL, 0x07E0                 @ RGB565 green: R=0, G=0x3F, B=0 - chosen to differ from the red BCCR test
.equ FB_FILL_WORD,  ((FB_FILL_PIXEL << 16) | FB_FILL_PIXEL)

@ CORRECTED after a real hardware test showed grey again with the layer enabled: re-reading sub_21D9C (IDB
@ 0x21D9C, the firmware's real per-layer setup, now that the vendor HAL gave real field names to check it
@ against) shows the "window stop" field (p2C->word4, what the vendor HAL calls windowX1) is literally the
@ panel WIDTH (480) for a full-screen layer, not width-1 (479) - `dword_762118 = 0x11001E0` (width=0x1E0=480
@ in the low half, height=0x110=272 in the high half) is copied into both p2C->word4 and p2C->field_20
@ (height's counterpart) directly, no "-1". Using width-1 made CFBLR's line-length field 2 bytes short of the
@ pitch field for no reason, which skews every line's start by those 2 bytes relative to the one before it -
@ accumulated over 272 lines that is enough to turn a solid colour into visual noise.
@
@ A 40x40 diagnostic window (kept full-screen buffer fill, small *window* only) confirmed the real remaining
@ bug: the box showed as a clean black/grey square, separate from the red background - proof the window-size
@ arithmetic and layer-enable mechanism both worked, while CFBAR itself pointed at the wrong thing (fixed
@ above: VOUT needs SDRAM_BASE + FB_BASE, not the CPU-side FB_BASE address alone). With that CFBAR fix the
@ same small window showed solid green as expected, so this is back to the real full-screen size.
.equ VOUT_L0_WHPCR_VAL, ((0 + VOUT_AHBP + 1) | ((FB_WIDTH  + VOUT_AHBP) << 16))
.equ VOUT_L0_WVPCR_VAL, ((0 + VOUT_AVBP + 1) | ((FB_HEIGHT + VOUT_AVBP) << 16))
.equ VOUT_L0_CFBLR_VAL, ((FB_PITCH << 16) | (FB_WIDTH * FB_BPP))

.equ PANEL_WIDTH,  480
.equ PANEL_HEIGHT, 272
.equ PANEL_HSW,  10
.equ PANEL_HFP,  4
.equ PANEL_HBP,  33
.equ PANEL_VSW,  6
.equ PANEL_VFP,  3
.equ PANEL_VBP,  4

.equ VOUT_SSCR_VAL, (((PANEL_HSW  - 1)                              << 16) | (PANEL_HFP - 1))
.equ VOUT_BPCR_VAL, (((PANEL_HSW  + PANEL_HBP - 1)                  << 16) | (PANEL_HFP + PANEL_VSW - 1))
.equ VOUT_AWCR_VAL, (((PANEL_WIDTH  - 1 + PANEL_HBP + PANEL_HSW)    << 16) | (PANEL_HEIGHT - 1 + PANEL_VSW + PANEL_HFP))
.equ VOUT_TWCR_VAL, (((PANEL_HSW + PANEL_HBP + PANEL_WIDTH + PANEL_VFP - 1) << 16) | (PANEL_HFP + PANEL_VSW + PANEL_HEIGHT + PANEL_VBP - 1))
@ Diagnostic: pure red instead of white, to tell apart "BCCR works, backlight is just dim" (expect to see red)
@ from "BCCR isn't what's actually visible" (expect the same grey/other colour regardless of this value).
@ BCCR fields are BCRED (bits 23:16) / BCGREEN (8:15) / BCBLUE (0:7) per the BSP (gm_ll_vout.h) - channel
@ order confirmed, not guessed, unlike the "all three bytes 0xFF" white test this replaces.
.equ VOUT_BCCR_WHITE, 0x00FF0000           @ red only (BCRED = 0xFF, BCGREEN = BCBLUE = 0)

/* ---- backlight: GPIOC pin 9 = TIM8_CH2 (AF5), a separate PWM from the buzzer's TIM5 ----
 * VOUT drives the panel's RGB/sync signals, but the panel's LED backlight is a second, independent piece of
 * hardware with its own enable: the firmware's `backlight_init` (IDB 0x1BA4, called once from `main`) turns
 * it on with this exact register sequence - without it, VOUT can be producing a perfectly correct signal
 * while the panel stays dark, which looks identical to "nothing works" from outside. TIM8 is a bigger
 * ("advanced") timer than TIM5: it has complementary outputs and a break/dead-time unit, which is why it
 * needs one extra register (BDTR) that TIM5 does not.
 * Clock/reset: CLK_EN_CTRL3 (SYS_ENCLK2 below) / IP_RST_CTRL3 (SYS_IPSWRST2) bit 21 - the same two registers
 * already used for TIM5, different bit (`init_2D850` @0x1CF9E enables this once at boot, before
 * `backlight_init` runs; stage1 has to do it itself since it never calls that function).
 * Not replicated here: `backlight_init` also toggles a GPIOB pin and polls it for ~10 iterations as a
 * power-good check before deciding `g_backlight_ok`. Reading `set_dim` (IDB 0x1CD8) shows that flag only
 * changes a secondary GPIOB signal's drive sense: every path that turns the backlight on with a non-zero,
 * non-100% brightness still sets TIM8_CCR2 regardless, so that check is not required for this test. */
.equ SYS_IOMODE2,   0x2CC                  @ IOMODE[2] (IO_MOD_REG3) = port C
.equ SYS_IOAFR6,    0x304                  @ IOAFR port C pins 8..15 (AF_SEL_REG6)
.equ GPIOC_BASE,    0x40012000
.equ GPIOC_OBSR,    (GPIOC_BASE + 0x08)
.equ GPIOC_OMCR,    (GPIOC_BASE + 0x10)
.equ ENCLK2_TIM8,   (1 << 21)
.equ IPSWRST2_TIM8, (1 << 21)
.equ BL_PIN,            9
.equ BL_PIN_MASK,       (1 << BL_PIN)
.equ BL_IOMODE_MASK,    (3 << (2 * BL_PIN))               @ pin 9's 2 mode bits in IOMODE[2] (whole port in one register)
.equ BL_IOMODE_AF,      (1 << (2 * BL_PIN))
.equ BL_AFR_MASK,       (0xF << (4 * (BL_PIN - 8)))       @ AFR is split lo/hi (8 pins each); pin 9 is nibble 1 of the hi half
.equ BL_AFR_TIM8,       (5   << (4 * (BL_PIN - 8)))       @ AF5 = TIM8_CH2

.equ TIM8_BASE,   0x40007500
.equ TIM8_CR1,    0x00
.equ TIM8_CCMR1,  0x18                     @ channel 2's output-compare mode is bits [14:12] here
.equ TIM8_CCER,   0x20
.equ TIM8_PSC,    0x28
.equ TIM8_ARR,    0x2C
.equ TIM8_CCR2,   0x38
.equ TIM8_BDTR,   0x44                     @ bit 15 = MOE (Main Output Enable) - without it the advanced
                                           @   timer's channel outputs stay off regardless of CR1/CCER
@ backlight_init(3000): tier a1>500 -> PSC so the tick is 200MHz/8=25MHz, period = 25MHz/3000Hz
.equ BL_PSC_VAL,  7
.equ BL_PERIOD,   (25000000 / 3000)
.equ BL_ARR_VAL,  (BL_PERIOD - 1)
@ set_dim (IDB 0x1CD8): CCR2 = period * (100 - brightness) / 100 - CC2P (CCER bit 5) inverts the channel, so a
@ *small* CCR2 is *bright*, not a large one. BL_PERIOD/2 (50%, the firmware's literal post-init default) still
@ looked grey on hardware, so this picks the equivalent of ~95% brightness instead for a clearer test.
.equ BL_CCR2_VAL, (BL_PERIOD / 20)

/* ---- buzzer pin: IO7 = GPIOI pin 3 = TIM5_CH4 (AF5) ----
 * The firmware's cfgpio_apply(7, 3, 0) (extended IO 7, mode 3 = PWM) touches exactly these bits.
 * Note: port I is the lower half of its register pair in the pull/open-drain registers, so the pin number
 * is used directly as the bit (port J would be shifted by 16). */
.equ BUZZER_PIN,        3
.equ BUZZER_PIN_MASK,   (1 << BUZZER_PIN)                 @ bit of the pin in the pull / open-drain registers
.equ BUZZER_IOMODE_MASK, (3 << (2 * BUZZER_PIN))          @ the pin's 2 mode bits in IOMODE[8]
.equ BUZZER_IOMODE_AF,   (1 << (2 * BUZZER_PIN))          @ mode 1 = alternate function
.equ BUZZER_AFR_MASK,    (0xF << (4 * BUZZER_PIN))        @ the pin's 4 AF bits in IOAFR[16]
.equ BUZZER_AFR_TIM5,    (5   << (4 * BUZZER_PIN))        @ AF5 = TIM5_CH4 (BSP: GPIOI3_AF5_TIM5_CH4)
.equ GPIOI_OMCR,        0x40019010         @ GPIOI base 0x40019000 + 0x10 (output mode control: writing the pin's
                                           @   bit selects output mode; the firmware does this for the PWM pin too)

/* ---- TIM5 (0x40007400), STM32-like layout (BSP TIM_Device_T) ---- */
.equ TIM5_BASE,  0x40007400
.equ TIM_CR1,    0x00                      @ control 1: bit 0 = counter enable
.equ TIM_CCMR1,  0x18                      @ capture/compare mode 1: output compare modes of channels 1 and 2
.equ TIM_CCMR2,  0x1C                      @ capture/compare mode 2: output compare modes of channels 3 and 4
.equ TIM_CCER,   0x20                      @ capture/compare enable (4 bits per channel: enable, polarity, ...)
.equ TIM_PSC,    0x28                      @ prescaler: timer tick = clock / (PSC + 1)
.equ TIM_ARR,    0x2C                      @ auto-reload: period = ARR ticks
.equ TIM_CNT,    0x24                      @ counter: counts 0..ARR, then wraps to 0 (one wrap = one PWM period)
.equ TIM_CCR4,   0x40                      @ compare value of channel 4: pulse width in ticks

/* ---- timer setup shared by all notes ---- */
.equ TIM_PSC_VAL,   99                     @ 200 MHz / (99 + 1) = 2 MHz timer tick (the firmware's choice for 100 Hz..10 kHz)
.equ TIM_HZ,        2000000                @ timer tick rate after the prescaler
.equ WAIT_TIMEOUT,  30000000               @ safety: give up waiting for one note after this many loop iterations
                                           @   (only reached if the counter does not run)

/* ---- melody table ----
 * One entry per note, three words: periods, ARR, CCR4.
 *   periods = number of PWM periods the note lasts (= ms * Hz / 1000), counted from TIM5_CNT wrap-arounds
 *   ARR     = timer ticks per period (TIM_HZ / Hz)
 *   CCR4    = high time, half the period (50 % duty)
 * A single zero word ends the table. `rest` plays silence: CCR4 = 0 keeps the output at its idle level. */
.macro note hz, ms
    .word (\ms * \hz / 1000)
    .word (TIM_HZ / \hz)
    .word (TIM_HZ / \hz / 2)
.endm
.macro rest ms
    .word \ms                              @ 1 kHz filler period = 1 ms
    .word (TIM_HZ / 1000)
    .word 0
.endm

/* ==========================================================================
 *  Image
 * ========================================================================== */

@ Needed from here on (the text-drawing code uses r8-r12 and more varied immediate forms than anything
@ earlier in this file): without it, GNU as defaults to legacy "divided" Thumb syntax, which is actually
@ stricter than real Thumb-1 hardware - it refuses high registers and most immediate forms outright instead
@ of picking a wider Thumb-2 encoding, even though this CPU (-mcpu=cortex-m4) fully supports Thumb-2.
.syntax unified
.section .vector_table, "a"            @ explicit alloc flag: needed now that this is its own output section
                                        @ (linker.ld), not merged into .text, which gets the flag by default
.global vectors
.vectors:
    @ MSP the loader switches to before it BLXes entry (ldr_exec_: `msr msp, [image]; blx [image+4]`), and the
    @ stack the loader then returns on (`pop {r4,r5,r6,pc}` in ldr_exec_, then `pop {r4-r8,pc}` in ldr_exec).
    @ It must therefore be the loader's own SP at that moment, not its initial one:
    @   0x20000680 (initial SP, set at 0x20001268) - 16 (ldr_main push) - 24 (ldr_exec push) - 16 (ldr_exec_ push)
    @   = 0x20000648. With 0x20000680 the `bx lr` return pops garbage and the board hangs.
    .word 0x20000648
    .word entry + 1                        @ reset vector -> entry (Thumb)
    .rept 14
        .word 0                          @ unused: entry returns via LR; interrupts are masked by the loader
    .endr
    @ The table is kept to the 16 Cortex-M system vectors on purpose: fw_pack.pack() overwrites image offsets
    @ 0x1C8..0x1DB (and the loader owns 0x1C8..0x267) with the container header (CRCs, length), so the vector table,
    @ the code and its literal pool must all end below 0x1C8 - linker.ld asserts that.

/* rmw addr, clr, set: read-modify-write of a 32-bit register at an absolute address:
 *     *addr = (*addr & ~clr) | set
 * The full address comes from the literal pool because the 16-bit Thumb ldr/str here only reach offsets up
 * to 124 (SYS registers are at 0x80..0x330). Clobbers r0-r3. r4-r11 belong to the caller (the loader) and
 * must survive the `bx lr` return: the only other register used, r4, is saved on the stack around the wait. */
.macro rmw addr, clr, set
    ldr r0, =\addr                         @ r0 = register address
    ldr r1, =\clr                          @ r1 = bits to clear
    ldr r3, =\set                          @ r3 = bits to set
    ldr r2, [r0]                           @ r2 = current value
    bic r2, r2, r1                         @ r2 &= ~clr
    orr r2, r2, r3                         @ r2 |= set
    str r2, [r0]                           @ write back
.endm

.section .text
.global entry
.thumb_func
entry:
    @ r6 reports whether PLLSAI really reached CMUST_PLLSAI_STABLE or we gave up after PLLSAI_WAIT_TIMEOUT -
    @ picked up again below to choose which melody plays, as an audible yes/no without any UART. Pushed here
    @ (not just around the wait) because it must survive everything up to the melody choice; popped with
    @ r4/r5 before the final bx lr, below.
    push {r6}
    movs r6, #0                             @ 0 = reached stable; set to 1 below only on timeout

    @ ==== panel (VOUT): clock, reset, pinmux, timing, solid white - see the header comment for sources ====
    rmw (SYS_BASE + SYS_ENCLK0), 0, ENCLK0_GPIO | ENCLK0_VOUT        @ GPIO clock (see below) + VOUT clock
    rmw (SYS_BASE + SYS_IPSWRST1), IPSWRST1_VOUT, 0                  @ assert VOUT reset
    rmw (SYS_BASE + SYS_IPSWRST1), 0, IPSWRST1_VOUT                  @ release VOUT reset

    @ port E: all 16 pins = alternate function (the panel's 16 RGB565 data lines)
    @ BUG FIXED after a real hardware test (3rd try) still showed uniform grey regardless of BCCR or PLLSAI
    @ fixes: this used to write 0xFFFFFFFF here. With "0 = GPIO, 1 = AF, 3 = analog" (2 bits/pin), 0xFFFFFFFF
    @ is mode 3 - ANALOG - repeated for all 16 pins, not alternate function; the real `init_lcd` writes
    @ 0x55555555 (mode 1 repeated 16 times). Every RGB565 data line was floating, disconnected from VOUT,
    @ while HSYNC/VSYNC/DE/PCLK (port F, below) were correctly set - valid timing, undefined colour on every
    @ pixel, which is exactly a uniform grey regardless of what BCCR or the pixel clock were set to.
    rmw (SYS_BASE + SYS_IOMODE4), 0, 0x55555555                      @ mode = AF (01) for every pin, matching the firmware
    rmw (SYS_BASE + SYS_IOAFR9),  0, 0x22222222                      @ AF2, pins 0..7
    rmw (SYS_BASE + SYS_IOAFR10), 0, 0x22222222                      @ AF2, pins 8..15

    @ port F: only pins 0..4 (HSYNC/VSYNC/DE/PCLK + one more); pins 5..6 are touch RST/INT, left untouched
    rmw (SYS_BASE + SYS_IOMODE5), 0x3FF, 0x155                       @ mode = AF for pins 0..4 only
    rmw (SYS_BASE + SYS_IOAFR11), 0xFFFFFFFF, 0x22222                @ AF2, pins 0..4 (pins 5..7 untouched: no mode change above)

    @ no pulls on the panel's own pins (port E all, port F pins 0..4): E = low 16 bits, F = high 16 bits
    rmw (SYS_BASE + SYS_IOPU_EF), 0x001FFFFE, 0
    rmw (SYS_BASE + SYS_IOPD_EF), 0x001FFFFE, 0

    @ ---- oscillators + reference select: sub_27630's prefix, before it ever touches PLLSAI ----
    rmw (SYS_BASE + SYS_HIRC_CTRL), 0, CMUST_HIRC_STABLE              @ bit 0 = EN, same bit position as its CMUST flag
    ldr r0, =(SYS_BASE + SYS_CMUST)
    ldr r4, =OSC_WAIT_TIMEOUT
.hirc_wait:
    ldr r2, [r0]
    ldr r3, =CMUST_HIRC_STABLE
    tst r2, r3
    bne .hirc_stable
    sub r4, r4, #1
    cmp r4, #0
    bne .hirc_wait
.hirc_stable:

    rmw (SYS_BASE + SYS_LIRC_CTRL), 0, CMUST_LIRC_STABLE
    ldr r0, =(SYS_BASE + SYS_CMUST)         @ reload: the rmw above clobbered r0
    ldr r4, =OSC_WAIT_TIMEOUT
.lirc_wait:
    ldr r2, [r0]
    ldr r3, =CMUST_LIRC_STABLE
    tst r2, r3
    bne .lirc_stable
    sub r4, r4, #1
    cmp r4, #0
    bne .lirc_wait
.lirc_stable:

    rmw (SYS_BASE + SYS_HOSC_CTRL), 1, 0                              @ HOSC/LOSC: bit 0 = stop/power-down,
    rmw (SYS_BASE + SYS_LOSC_CTRL), 1, 0                              @   active-low (clearing it enables them)
    rmw (SYS_BASE + SYS_REFCLK_SRC), REFCLK_SRC_MASK, REFCLK_SRC_VAL  @ select HOSC as this PLL cluster's reference

    @ ---- VOUT pixel clock: PLLSAI must be enabled and stable before the VOUT_DIV divider does anything ----
    @ sub_27630's exact sequence: enable (no VCO/CPC write), wait stable, *then* overwrite the dividers.
    rmw (SYS_BASE + SYS_PLLSAI0), 0, PLLSAI_EN                              @ enable PLLSAI

    ldr r0, =(SYS_BASE + SYS_CMUST)
    ldr r4, =PLLSAI_WAIT_TIMEOUT
.pllsai_wait:
    ldr r2, [r0]
    ldr r3, =CMUST_PLLSAI_STABLE
    tst r2, r3
    bne .pllsai_stable                     @ PLLSAI reports stable: move on
    sub r4, r4, #1                         @ sub (not subs): no flag-immediate in this Thumb-16 mode
    cmp r4, #0
    bne .pllsai_wait                       @ safety timeout: proceed anyway rather than hang forever
    movs r6, #1                             @ record that we gave up instead of seeing the stable bit
.pllsai_stable:

    ldr r0, =(SYS_BASE + SYS_PLLSAI1)
    ldr r2, =PLLSAI_DIV_VAL
    str r2, [r0]                                                           @ full overwrite, not a read-modify-write

    rmw (SYS_BASE + SYS_CLKSRC3), VOUT_DIV_MASK, VOUT_DIV_VAL                @ VOUT pixel clock divider

    ldr r1, =VOUT_BASE
    ldr r2, =VOUT_SSCR_VAL
    str r2, [r1, #VOUT_SSCR]
    ldr r2, =VOUT_BPCR_VAL
    str r2, [r1, #VOUT_BPCR]
    ldr r2, =VOUT_AWCR_VAL
    str r2, [r1, #VOUT_AWCR]
    ldr r2, =VOUT_TWCR_VAL
    str r2, [r1, #VOUT_TWCR]
    ldr r2, =VOUT_BCCR_WHITE
    str r2, [r1, #VOUT_BCCR]
    @ sub_F0AC actually ORs in (tft_id | field_18 | field_1C | field_20) here, not just the enable bit; for this
    @ panel (model 0x431) the latter three are 0 in g_scr_infos[0] (confirmed by reading the struct's raw
    @ bytes), so the real value is 0x431 itself - it sets a couple of low dither-width bits (DBW/DGW) along
    @ with enable (bit 0, already part of 0x431), which does not affect whether anything is visible.
    ldr r2, [r1, #VOUT_GCR]
    ldr r3, =0x0FFFFFFF
    and r2, r2, r3                                                   @ clear bits [31:28], as the firmware does
    ldr r3, =0x431
    orr r2, r2, r3                                                   @ enable + this panel's dither-width bits
    str r2, [r1, #VOUT_GCR]

    @ Flush the literal pool here: without periodic breaks like this, GNU as puts every `ldr rX, =value` literal
    @ in one pool at the end of the function, and this function got long enough that the earliest such loads
    @ fall outside the 16-bit `ldr`'s +/-1020-byte reach ("invalid offset, value too big"). `b`+`.ltorg`+label
    @ dumps the pool without falling through into it as data.
    b 1f
    .ltorg
1:
    @ ==== layer 0: framebuffer, filled solid green - see the header comment's "Step B" section ====
    @ Fill first (two RGB565 pixels per 32-bit store), so the layer never displays whatever garbage SDRAM
    @ already held at FB_BASE in the moment between enabling it and finishing the fill.
    ldr r0, =FB_BASE
    ldr r2, =FB_FILL_WORD
    ldr r4, =FB_WORDS
.fb_fill:
    str r2, [r0]
    add r0, r0, #4
    sub r4, r4, #1                         @ sub (not subs): no flag-immediate in this Thumb-16 mode
    cmp r4, #0
    bne .fb_fill

    ldr r1, =VOUT_BASE                     @ reload: r1 was VOUT_BASE already, but be explicit
    ldr r2, =VOUT_L0_WHPCR_VAL
    str r2, [r1, #VOUT_L0_WHPCR]
    ldr r2, =VOUT_L0_WVPCR_VAL
    str r2, [r1, #VOUT_L0_WVPCR]
    ldr r2, =VOUT_PF_RGB565
    str r2, [r1, #VOUT_L0_PFCR]
    movs r2, #255
    str r2, [r1, #VOUT_L0_CACR]            @ fully opaque: no blending with BCCR behind it
    movs r2, #0
    str r2, [r1, #VOUT_L0_DCCR]
    ldr r2, =FB_CFBAR_VAL                   @ SDRAM_BASE + FB_BASE: VOUT's own bus address, not the CPU's
    str r2, [r1, #VOUT_L0_CFBAR]
    ldr r2, =VOUT_L0_CFBLR_VAL
    str r2, [r1, #VOUT_L0_CFBLR]
    ldr r2, =FB_HEIGHT
    str r2, [r1, #VOUT_L0_CFBLNR]
    movs r2, #1
    str r2, [r1, #VOUT_L0_CR]               @ LEN: enable the layer

    @ ==== draw "HELLO WORLD" into the framebuffer, on top of the green fill - see draw_text/draw_glyph below ====
    @ bl/bx lr need LR, which right now still holds the loader's own return address (from its BLX into this
    @ image) - save it around the call so entry's own final `bx lr` still works afterward.
    push {lr}
    bl draw_text
    pop {lr}

    b 2f                                     @ literal-pool flush, see the comment at the previous one
    .ltorg
2:
    @ ==== backlight (TIM8 PWM on GPIOC pin 9): see the header comment's backlight section ====
    rmw (SYS_BASE + SYS_ENCLK0), 0, ENCLK0_GPIO                      @ GPIO clock (harmless repeat)
    rmw (SYS_BASE + SYS_ENCLK2), 0, ENCLK2_TIM8                      @ TIM8 clock
    rmw (SYS_BASE + SYS_IPSWRST2), IPSWRST2_TIM8, 0                  @ assert TIM8 reset
    rmw (SYS_BASE + SYS_IPSWRST2), 0, IPSWRST2_TIM8                  @ release TIM8 reset

    rmw (SYS_BASE + SYS_IOMODE2), BL_IOMODE_MASK, BL_IOMODE_AF        @ pin mode = alternate function
    rmw (SYS_BASE + SYS_IOAFR6),  BL_AFR_MASK, BL_AFR_TIM8            @ alternate function number = 5

    ldr r0, =GPIOC_OMCR                     @ output-mode-control bit for the pin, as the firmware does
    ldr r2, =BL_PIN_MASK
    str r2, [r0]
    ldr r0, =GPIOC_OBSR                     @ drive it low before the PWM takes over (the firmware does the same)
    str r2, [r0]

    ldr r1, =TIM8_BASE
    movs r2, #0
    str r2, [r1, #TIM8_CR1]                 @ stopped while configuring
    ldr r2, =BL_PSC_VAL
    str r2, [r1, #TIM8_PSC]
    ldr r2, =BL_ARR_VAL
    str r2, [r1, #TIM8_ARR]
    ldr r0, [r1, #TIM8_CCMR1]
    ldr r2, =0xFFFF00FF
    and r0, r0, r2
    ldr r2, =0x7000                         @ OC2M = 0b111 (PWM mode 2), channel 2
    orr r0, r0, r2
    str r0, [r1, #TIM8_CCMR1]
    ldr r0, [r1, #TIM8_CCER]
    ldr r2, =0xFFFFFF0F
    and r0, r0, r2
    ldr r2, =0x50                           @ CC2E + CC2NE (channel 2, firmware's own value)
    orr r0, r0, r2
    str r0, [r1, #TIM8_CCER]
    ldr r0, [r1, #TIM8_BDTR]
    ldr r2, =0x8000                         @ MOE: without this the advanced timer's outputs stay off
    orr r0, r0, r2
    str r0, [r1, #TIM8_BDTR]
    ldr r2, =BL_CCR2_VAL
    str r2, [r1, #TIM8_CCR2]
    movs r2, #1
    str r2, [r1, #TIM8_CR1]                 @ go

    @ ==== buzzer (TIM5): unchanged from before - see the header comment's buzzer section ====
    @ ---- enable the GPIO and TIM5 clocks ----
    @ A peripheral whose clock is off ignores register writes, so this has to come first.
    rmw (SYS_BASE + SYS_ENCLK0), 0, ENCLK0_GPIO
    rmw (SYS_BASE + SYS_ENCLK2), 0, ENCLK2_TIM5

    @ ---- pulse the TIM5 software reset (active low) ----
    @ Puts the timer into a known state (whatever the stage-0 loader or the previous run left behind).
    rmw (SYS_BASE + SYS_IPSWRST2), IPSWRST2_TIM5, 0            @ assert reset
    rmw (SYS_BASE + SYS_IPSWRST2), 0, IPSWRST2_TIM5            @ release reset

    @ ---- pin PI3: alternate function 5 (TIM5_CH4), no pulls, push-pull ----
    rmw (SYS_BASE + SYS_IOMODE8), BUZZER_IOMODE_MASK, BUZZER_IOMODE_AF   @ pin mode = alternate function
    rmw (SYS_BASE + SYS_IOAFR16), BUZZER_AFR_MASK, BUZZER_AFR_TIM5       @ alternate function number = 5
    rmw (SYS_BASE + SYS_IOPULLUP4), BUZZER_PIN_MASK, 0                   @ no pull-up
    rmw (SYS_BASE + SYS_IOPULLDOWN4), BUZZER_PIN_MASK, 0                 @ no pull-down
    rmw (SYS_BASE + SYS_IOODC4), BUZZER_PIN_MASK, 0                      @ push-pull (not open drain)

    ldr r0, =GPIOI_OMCR                    @ output-mode-control bit for the pin (as the firmware does)
    ldr r2, =BUZZER_PIN_MASK
    str r2, [r0]

    @ ---- TIM5: PWM on CH4 (everything except the note-specific ARR / CCR4) ----
    @ Same values the firmware's `pwmf`/`beep` path writes (function at 0x1FA40 in the IDB).
    ldr r1, =TIM5_BASE                     @ r1 = TIM5 base for the rest of the file
    movs r2, #0
    str r2, [r1, #TIM_CR1]                 @ stopped while configuring
    ldr r2, =TIM_PSC_VAL
    str r2, [r1, #TIM_PSC]                 @ 2 MHz tick
    ldr r2, =0x7070                        @ OCxM = 0b111 (PWM mode 2) for both channels of the register
    str r2, [r1, #TIM_CCMR1]               @ channels 1, 2 (unused, configured like the firmware does)
    str r2, [r1, #TIM_CCMR2]               @ channels 3, 4
    ldr r2, =0x3333                        @ all four channels: output enabled, polarity bit set
    str r2, [r1, #TIM_CCER]

    b 3f                                     @ literal-pool flush, see the comment at the first one
    .ltorg
3:
    @ ---- play the melody ----
    @ The stack is the loader's (MSP = 0x20000648, vector word 0): pushing below it is safe.
    push {r4, r5}                          @ callee-saved: r5 = pointer into the table, r4 = safety timeout
    cmp r6, #0
    beq .pllsai_was_stable
    ldr r5, =melody_pllsai_timeout          @ r6 == 1: PLLSAI never reported stable
    b .next_note
.pllsai_was_stable:
    ldr r5, =melody
.next_note:
    ldr r3, [r5]                           @ r3 = periods still to wait (0 = end of the melody)
    cmp r3, #0
    beq .melody_done
    movs r2, #0
    str r2, [r1, #TIM_CR1]                 @ stop and zero the counter first: with a smaller new ARR a counter
    str r2, [r1, #TIM_CNT]                 @   above it would run on to 0xFFFF before wrapping (tens of ms of silence)
    ldr r2, [r5, #4]
    str r2, [r1, #TIM_ARR]                 @ period of the note
    ldr r2, [r5, #8]
    str r2, [r1, #TIM_CCR4]                @ duty of channel 4 = the buzzer (0 for a rest)
    add r5, r5, #12                        @ next entry
    movs r2, #1
    str r2, [r1, #TIM_CR1]                 @ go

    @ Poll TIM5's own counter and count its wrap-arounds (one per PWM period), so the length follows the timer
    @ clock, not the (slow, SDRAM-bound) instruction rate.
    ldr r4, =WAIT_TIMEOUT                  @ safety: bounded loop if the counter never moves
    movs r0, #0                            @ previous counter value
.wait:
    ldr r2, [r1, #TIM_CNT]
    cmp r2, r0
    bhs .no_wrap                           @ counter did not go down: same period
    sub r3, r3, #1                         @ counter wrapped: one more period done
.no_wrap:
    mov r0, r2                             @ remember the counter
    sub r4, r4, #1                         @ sub (not subs): this Thumb-16 assembler has no flag-immediate
    cmp r4, #0
    beq .note_done                         @ safety timeout
    cmp r3, #0
    bne .wait
.note_done:
    b .next_note
.melody_done:
    pop {r4, r5}

    @ ---- stop the timer ----
    @ The pin stays configured as TIM5_CH4; with the counter stopped the output stops toggling.
    movs r2, #0
    str r2, [r1, #TIM_CR1]

    @ ---- done: hand control back to the loader (LR from the BLX) ----
    pop {r6}
    bx lr

/* ==========================================================================
 *  Text: draw_text / draw_glyph (called once, via `bl`, from the main flow above)
 * ========================================================================== */

/* draw_text: walks text_string, calls draw_glyph per character, advances the cursor.
 * r4-r11 are the loader's (see the register-convention comment near the top of this file) - saved here with
 * `lr` in one push/pop so this whole call (and whatever draw_glyph does inside it) is transparent to the
 * caller. r0-r3 are scratch throughout this file and are not saved. */
.thumb_func
draw_text:
    push {r3, r4, r5, r6, r7, r8, r9, r10, r11, lr}
    ldr r3, =TEXT_COLOR                    @ constant for the whole call; draw_glyph must not clobber r3
    ldr r7, =text_string
    ldr r8, =TEXT_X0                       @ cursor x, advances after each character
    ldr r9, =TEXT_Y0                       @ fixed: single line of text
.dt_loop:
    ldrb r0, [r7]
    adds r7, r7, #1
    cmp r0, #0
    beq .dt_done
    bl draw_glyph                          @ leaf function: does not touch r3/r7/r8/r9, only r0-r2/r4-r6/r10-r12
    ldr r1, =CHAR_ADVANCE
    add r8, r8, r1
    b .dt_loop
.dt_done:
    pop {r3, r4, r5, r6, r7, r8, r9, r10, r11, pc}

/* draw_glyph: draws the character in r0 at (r8, r9) (both read-only here). r3 = colour (read-only).
 * Leaf function (no nested `bl`): returns via `bx lr` without its own push/pop. */
.thumb_func
draw_glyph:
    cmp r0, #0x48                           @ 'H'
    bne .dg_try_E
    ldr r10, =glyph_H
    b .dg_have_glyph
.dg_try_E:
    cmp r0, #0x45                           @ 'E'
    bne .dg_try_L
    ldr r10, =glyph_E
    b .dg_have_glyph
.dg_try_L:
    cmp r0, #0x4C                           @ 'L'
    bne .dg_try_O
    ldr r10, =glyph_L
    b .dg_have_glyph
.dg_try_O:
    cmp r0, #0x4F                           @ 'O'
    bne .dg_try_W
    ldr r10, =glyph_O
    b .dg_have_glyph
.dg_try_W:
    cmp r0, #0x57                           @ 'W'
    bne .dg_try_R
    ldr r10, =glyph_W
    b .dg_have_glyph
.dg_try_R:
    cmp r0, #0x52                           @ 'R'
    bne .dg_try_D
    ldr r10, =glyph_R
    b .dg_have_glyph
.dg_try_D:
    cmp r0, #0x44                           @ 'D'
    bne .dg_space
    ldr r10, =glyph_D
    b .dg_have_glyph
.dg_space:
    ldr r10, =glyph_SP                      @ space, or anything else not in this small set: blank
.dg_have_glyph:
    movs r5, #0                             @ font row 0..6
.dg_row_loop:
    cmp r5, #GLYPH_H
    bge .dg_done
    ldrb r4, [r10, r5]                      @ this row's 5-bit pattern, bit 4 = leftmost column

    @ r6 = framebuffer address of logical (x0, y0 + row*SCALE), measured *backward* from FB_BOTTOM_RIGHT - see
    @ the FB_BOTTOM_RIGHT comment above: this panel scans from the opposite corner, so what reads correctly on
    @ screen is addressed as an offset from the far end, not forward from FB_BASE.
    ldr r6, =TEXT_SCALE
    mul r6, r5, r6
    add r6, r6, r9
    ldr r1, =FB_PITCH
    mul r6, r6, r1
    ldr r0, =FB_BOTTOM_RIGHT
    sub r6, r0, r6
    lsls r0, r8, #1
    sub r6, r6, r0

    movs r1, #0                             @ scale_y: which of this row's TEXT_SCALE identical scanlines
.dg_scaley_loop:
    cmp r1, #TEXT_SCALE
    bge .dg_scaley_done
    mov r2, r6                              @ r2 = running pixel pointer for this one scanline
    mov r12, r4
    lsls r12, r12, #27                      @ bit 4 (leftmost pixel) of the 5-bit pattern -> bit 31, testable via N
    movs r11, #GLYPH_W                      @ column counter, GLYPH_W downto 1
.dg_col_loop:
    tst r12, r12
    bpl .dg_col_skip                        @ N clear: this font pixel is 0 - background (already filled) shows through
    movs r0, #TEXT_SCALE
.dg_px_loop:
    strh r3, [r2]
    subs r2, r2, #2                         @ "rightward" in logical columns = backward in physical address (flip)
    subs r0, r0, #1
    bne .dg_px_loop
    b .dg_col_next
.dg_col_skip:
    subs r2, r2, #(2 * TEXT_SCALE)
.dg_col_next:
    lsls r12, r12, #1
    subs r11, r11, #1
    bne .dg_col_loop

    ldr r0, =FB_PITCH
    sub r6, r6, r0                          @ next of this row's TEXT_SCALE identical scanlines (also backward)
    adds r1, r1, #1
    b .dg_scaley_loop
.dg_scaley_done:
    adds r5, r5, #1
    b .dg_row_loop
.dg_done:
    bx lr

.align 2
/* 5x7 bitmap font, hand-drawn for this test (not a real font file): one byte per row, bits [4:0], bit 4 =
 * leftmost column. Only the letters "HELLO WORLD" needs; draw_glyph falls back to glyph_SP for anything else. */
glyph_H: .byte 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11
glyph_E: .byte 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F
glyph_L: .byte 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F
glyph_O: .byte 0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E
glyph_W: .byte 0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11
glyph_R: .byte 0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11
glyph_D: .byte 0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E
glyph_SP: .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.align 2
text_string: .asciz "HELLO WORLD"

/* "ta-daa": a short note, a gap, then a longer one a fifth higher (C6 -> G6; a piezo is loudest around 2-4 kHz, so
 * the notes are kept high). Edit the table to change the tune; keep the total image below 0x1C8 bytes. */
.align 2
melody:
    note 1047, 110        @ "ta"   C6
    rest 40
    note 1568, 520        @ "daa"  G6
    .word 0               @ end of the melody

/* Diagnostic alternate melody: three short, identical, low beeps - unmistakably different from "ta-daa" by
 * ear, so PLLSAI's CMUST_PLLSAI_STABLE bit either showed up (normal tune) or PLLSAI_WAIT_TIMEOUT was hit
 * instead (this one), with nothing to read over UART. See the r6 flag set around .pllsai_wait, above. */
melody_pllsai_timeout:
    note 440, 80          @ A4, low and short
    rest 80
    note 440, 80
    rest 80
    note 440, 80
    .word 0
