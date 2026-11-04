/*
 * stage1: stage-0 SD-card bootloader for the SoVol SV08MAX TFT panel (AiHmiT7, Gree Edgeless
 * GM6721-family dual Cortex-M4 @ 200 MHz - not an STM32). The stock loader (ldr_main/ldr_exec)
 * reads TFWriter_AiHmiT7.bin.make from a FAT SD card to 0x80000 and BLX's its word 1 (this entry).
 *
 * COLD pass (first boot since power-on): bring up UART2 + the VOUT RGB panel (PLLSAI pixel clock,
 * a real SDRAM framebuffer with 5x7 text) + the backlight, play a 1st "ta-daa" on the TIM5 buzzer,
 * wait for touch, and plant a 32-byte runtime patch (site1+site2) into the loader's SRAM so the
 * final jump to the stock firmware detours through entry_trampoline - which plays a 2nd melody once
 * (HOOK_DONE-gated) before blx'ing the stock app. WARM pass (BOOT_FLAG already set - a
 * watchdog/relay reset): bail immediately and let the chain fall through to stock. Flash is never
 * written; the loader patch lives in SRAM and dies on power-off. Deploy contract:
 * .operator/specs/melody_deploy.md.
 *
 * Hand-off: ldr_exec_ copies the image's word 0 (MSP, must be 0x20000648) to MSP and BLX's word 1.
 * entry returns via `bx lr`, NOT `mov pc, lr`: BLX sets the Thumb bit in LR and `bx` clears it, so
 * the return lands in the loader's ARM context. A vector table (MSP + reset slot) is still emitted
 * (linker.ld puts (.vector_table) at the front of .text) so the image is one the loader can VTOR to
 * and read SP from. Pure assembly.
 *
 * --------------------------------------------------------------------------
 *  Buzzer (TIM5) - copied from the stock firmware's `beep` command
 * --------------------------------------------------------------------------
 * `beep` drives extended IO 7 = GPIOI pin 3 = TIM5_CH4 (AF5). Repeated here (values verified
 * against cmd_beep @0x21614 / cfgpio_apply @0x216a8 / TIM5 setup @0x1FA40 in the IDB):
 *   1. enable the GPIO + TIM5 clocks (SYS ENABLECLK0 / ENABLECLK2)
 *   2. pulse the TIM5 software reset (SYS IPSWRST[2] bit 20, active low)
 *   3. pin PI3: IOMODE AF, IOAFR nibble = 5, pull-up/down and open-drain cleared
 *   4. TIM5: PSC = 99 (200 MHz / 100 = 2 MHz), CCMR1 = CCMR2 = 0x7070 (PWM), CCER = 0x3333
 *   5. per note: ARR = 2 MHz / tone, CCR4 = ARR / 2 (0 for a rest), CR1 = 1, wait by counting TIM5
 *      wrap-arounds (the image runs from SDRAM where fetches are slow, so a 200 MHz-calibrated loop
 *      ran far too long - the timer self-measures each note), then stop
 * This assembler's Thumb-16 mode rejects flag-setting immediates, so the wait loop uses `sub`+`cmp`.
 * Not hardware-verified: the 200 MHz timer clock and the CCER polarity (copied from the firmware).
 *
 * --------------------------------------------------------------------------
 *  Panel (VOUT, the RGB/TTL LCD timing controller @ 0x40026000)
 * --------------------------------------------------------------------------
 * This unit is the generic-RGB-panel branch of the firmware's `init_lcd` (@0x13340, model code
 * 0x431, 480x272) - VOUT-driven, not a serial smart panel. Timing formulas read off `sub_F0AC`
 * (confirmed, not guessed):
 *   SSCR = (HSW-1)<<16 | (HFP-1)                     BPCR = (HSW+HBP-1)<<16 | (HFP+VSW-1)
 *   AWCR = (W-1+HBP+HSW)<<16 | (H-1+VSW+HFP)
 *   TWCR = (HSW+HBP+W+VFP-1)<<16 | (HFP+VSW+H+VBP-1)        GCR bit 0 = enable
 *   BCCR = background colour, all three channels set equal (channel order unidentified)
 * VOUT also needs a pixel ("dot") clock from the dedicated PLLSAI (SYS_BASE+0x198/0x19C), enabled
 * and stable BEFORE the CLKSRC[3] VOUT_DIV divider (SYS_BASE+0xA0, value 0x15) has any effect. The
 * firmware's real boot path (sub_27630 @0x27630, called from init_2D850) enables PLLSAI[0] with NO
 * VCO/CPC write, waits for CMUST stable, THEN writes the whole divider register
 * PLLSAI_CTRL2 = 0xAC020207 (DIVN=0xAC, DIVR=2, DIVQ=2, DIVP=7) - that exact sequence/constant is
 * copied, not the vendor HAL's generic path (which leaves the dividers at defaults and locks PLLSAI
 * at the wrong frequency). The shared PLL-reference mux (SYS_BASE+0x90) is left alone: this always
 * runs after a full boot, so a PLL is already stable and rewriting it could disturb the CPU's own
 * system clock.
 * Pinmux: port E (IO_MOD_REG5 / AF_SEL_REG9/10) all 16 pins -> AF2 (the 16 RGB565 data lines);
 * port F (IO_MOD_REG6 / AF_SEL_REG11) pins 0-4 -> AF2 (HSYNC/VSYNC/DE/PCLK). Port F pins 5-6 are
 * the touch RST/INT pins and are never touched.
 * Not hardware-verified end to end; the stock init_lcd reprograms all of this during its own boot.
 */

/* ==========================================================================
 *  Register map
 * ========================================================================== */

/* ---- SYS block (0x40000000): clocks, resets and pin multiplexing ----
 * Offsets are given from SYS_BASE. Names in brackets are the BSP names (soc_gm6721x.h, Sys_Device_T)
 * and, in brackets after them, the names used in the IDB. */
.equ SYS_BASE,        0x40000000
.equ SYS_IPSWRST2,    0x78                 // IPSWRST[2] (IP_RST_CTRL3): software reset of peripherals; bit 20 = TIM5,
                                           //   0 = held in reset, 1 = running (the firmware pulses it 0 -> 1)
.equ SYS_ENCLK0,      0x80                 // ENABLECLK[0] (CLK_EN_CTRL1): bit 1 = GPIO clock
.equ SYS_ENCLK2,      0x88                 // ENABLECLK[2] (CLK_EN_CTRL3): bit 20 = TIM5 clock
.equ SYS_IOODC4,      0x248                // IOODC[4] (IO_OD_REG5): open-drain enable, 1 bit per pin;
                                           //   register n covers ports 2n and 2n+1 (n = 4: port I in bits 0..15,
                                           //   port J in bits 16..31)
.equ SYS_IOPULLUP4,   0x278                // IOPULLUP[4] (IO_PU_REG5): pull-up enable, same layout as IOODC
.equ SYS_IOPULLDOWN4, 0x290                // IOPULLDOWN[4] (IO_PD_REG5): pull-down enable, same layout as IOODC
.equ SYS_IOMODE8,     0x2E4                // IOMODE[8] (IO_MOD_REG9): one 32-bit register per port (8 = port I),
                                           //   2 bits per pin: 0 = GPIO, 1 = alternate function, 3 = analog
.equ SYS_IOAFR16,     0x330                // IOAFR[16] (AF_SEL_REG17): alternate-function number, 4 bits per pin,
                                           //   two registers per port (16 = port I pins 0..7, 17 = pins 8..15)
.equ SYS_IOMODE9,     0x2E8                // IOMODE[9] (IO_MOD_REG10) = port J, following the same +4-bytes-per-
                                           //   port pattern as IOMODE4..8 above
.equ SYS_IOAFR18,     0x338                // IOAFR for port J pins 0..7 (same +4-per-register, +8-per-port pattern
                                           //   as IOAFR16 above: port I = 0x330/0x334, port J = 0x338/0x33C)

.equ SYS_IPSWRST1,    0x70                 // IPSWRST[1] (IP_RST_CTRL1): bit 19 = VOUT (SYS_IP_SW_RESET_VOUT_POS
                                           //   in the BSP), bit 1 = GPIO
.equ SYS_IOMODE4,     0x2D4                // IOMODE[4] (IO_MOD_REG5) = port E
.equ SYS_IOMODE5,     0x2D8                // IOMODE[5] (IO_MOD_REG6) = port F
.equ SYS_IOAFR9,      0x310                // IOAFR[9]  (AF_SEL_REG9)  = port E pins 0..7
.equ SYS_IOAFR10,     0x314                // IOAFR[10] (AF_SEL_REG10) = port E pins 8..15
.equ SYS_IOAFR11,     0x318                // IOAFR[11] (AF_SEL_REG11) = port F pins 0..7
.equ SYS_IOPU_EF,     0x270                // IOPULLUP pair register for ports E (bits 0..15) and F (bits 16..31)
.equ SYS_IOPD_EF,     0x288                // IOPULLDOWN, same pairing as IOPU_EF

/* ---- reset-survival flag: lives in the loader's internal SRAM, not SDRAM ----
 * ldr_main/ldr_exec sit in the 64 KiB internal SRAM segment 0x20000000..0x2000FFFF, separate from
 * the SDRAM window stage1 draws into. Everything the loader names there (code, strings, stack at
 * 0x20000680) is below ~0x20003970 and ldr_main has no SRAM-zeroing loop, so a flag planted at the
 * very top of the segment survives a normal run and a watchdog reset (a reset does not clear SRAM;
 * only a real power-on would, which would actually randomize it). Two states: unset = first boot
 * since power-on (run the pass once), DONE = skip straight to stock on every later pass.
 * BOOT_FLAG_DONE is an arbitrary 32-bit constant chosen only to not collide with post-power-on SRAM. */
.equ BOOT_FLAG_ADDR,  0x2000FFFC
.equ BOOT_FLAG_DONE,  0xB00710AD

/* HOOK_DONE: the word immediately below BOOT_FLAG, in the same untouched top-of-SRAM region. Set at the end of
 * the cold pass; consumed exactly once by entry_trampoline on this boot's final stock-firmware call (a1 == 0),
 * which plays the 2nd melody and clears it. Survives warm/watchdog resets; only a real power-off clears it.
 * (Magic 0x484F4F44 = ASCII "HOO D", same "must not read as garbage after power-on" criterion as BOOT_FLAG_DONE.) */
.equ HOOK_DONE_ADDR,  0x2000FFF8
.equ HOOK_DONE_MAGIC, 0x484F4F44
.equ FAULT_WORD,      0x2000FFF4                // fault_trap's parking spot: the fault-time SP (range-gates the
                                                //   warm-bail print). Like the two flags above, outside the loader's
                                                //   working set, so IWDG resets and the ROM re-copy both leave it intact
.equ FAULT_FRAME,     0x2000FF74                // fault_trap's raw exception frame R0,R1,R2,R3,R12,LR,PC,xPSR
                                                //   (8 words, 0x2000FF74-0x93)
.equ FAULT_STATUS,    0x2000FF94                // fault_trap's latched CFSR,HFSR,BFAR (3 words, 0x2000FF94-0x9F)

/* ---- hardware watchdog (IWDG) ----
 * IWDG_KR/PR/RLR at 0x40008000/4/8 (plain STM32-style). Sequence and magic values copied from the
 * firmware's own `restart` (@0x108E8, its generic reboot routine), not guessed. Clock is a fixed
 * internal ~32 kHz LIRC (BSP: HAL_IWDG_CLKSRC), independent of every other clock this file
 * configures - the whole point of an "independent" watchdog: it keeps running even if the main
 * clock tree is misconfigured or the CPU is stuck. */
.equ IWDG_BASE,         0x40008000
.equ IWDG_KR,           (IWDG_BASE + 0x00)
.equ IWDG_PR,           (IWDG_BASE + 0x04)
.equ IWDG_RLR,          (IWDG_BASE + 0x08)
.equ IWDG_KEY_UNLOCK,   0x5555              // unlocks PR/RLR for writing
.equ IWDG_KEY_START,    0xCCCC              // (re)starts the countdown
.equ IWDG_KEY_FEED,     0xAAAA              // reloads the counter from RLR - "feed"/"pet" the watchdog
.equ IWDG_PR_VAL,       6                   // prescaler = /256 (STM32-style PR encoding: 6 and 7 both mean /256)
.equ IWDG_RLR_VAL,      1250                // (1250+1)*256/32000 Hz ~= 10.0 s - a last-resort timeout, not a tight one
.equ SYS_PWR_MODE_REG,  0x18                // bit 12: backup-domain write unlock, needed only for PR/RLR writes,
                                            // not for feeding - same bit `restart` sets/clears around its own write
.equ PWR_BKP_UNLOCK_BIT, (1 << 12)

.macro iwdg_feed
    ldr r0, =IWDG_KR
    ldr r1, =IWDG_KEY_FEED
    str r1, [r0]
.endm
/* fault_word ch addr: print the 32-bit word at `addr` as "<ch>:XXXXXXXX" over the already-initialized UART
 * (the warm-bail dump of FAULT_WORD / FAULT_FRAME / FAULT_STATUS). Clobbers r0-r3 (uart_puts
 * saves r4; r4-r11 must survive). */
.macro fault_word ch, addr
    ldr r0, =\addr
    ldr r0, [r0]
    movs r1, #\ch
    ldr r2, =TEXT_BUF
    bl hex_line
    ldr r0, =TEXT_BUF
    bl uart_puts
.endm

/* timer_delay_ticks ticks: busy-waits until TIM5's free-running counter has advanced by `ticks`, using plain
 * 16-bit wraparound-safe subtraction (correct across at most one 16-bit wrap, so `ticks` must be <= 0xFFFF).
 * TIM5 must already be running (CR1 bit 0 set) with whatever prescaler the caller wants ticks measured in.
 * Clobbers r0-r3. */
.macro timer_delay_ticks ticks
    ldr r0, =(TIM5_BASE + TIM_CNT)
    ldr r1, [r0]
.Ltdelay\@:
    ldr r2, [r0]
    subs r2, r2, r1
    ldr r3, =0xFFFF
    ands r2, r2, r3
    ldr r3, =\ticks
    cmp r2, r3
    blo .Ltdelay\@
.endm

/* ---- UART2 (0x40006000): the real TJC serial link to the printer mainboard ----
 * Lets diagnostics go out over the wire (the existing Mac -> ESP32-S3 115200 passthrough bridge)
 * instead of off the panel a character at a time. Register map and values copied from this
 * firmware's own `uart_set_baud_rate` (@0x20734) and `uart_write_byte` (@0x208CC): pinmux port J
 * pins 6/7 (IO_MOD_REG10 / AF_SEL_REG19), AF 2, no pulls; baud divisor UART2_TC = 0x000F001A is
 * the firmware's own literal for 115200 (copied, not re-derived). No CLK_EN/reset is written for
 * UART2 - the boot ROM already has its bus clock live; if writes don't stick, that is the first
 * thing to revisit. */
.equ UART2_BASE, 0x40006000
.equ UART2_DR,   (UART2_BASE + 0x00)
.equ UART2_TC,   (UART2_BASE + 0x04)
.equ UART2_C1,   (UART2_BASE + 0x08)
.equ UART2_C2,   (UART2_BASE + 0x0C)
.equ UART2_C3,   (UART2_BASE + 0x10)
.equ UART2_LS,   (UART2_BASE + 0x14)
.equ UART2_TH,   (UART2_BASE + 0x18)
.equ UART2_IE,   (UART2_BASE + 0x1C)
.equ UART2_IS,   (UART2_BASE + 0x20)
.equ UART2_PINMODE_MASK, 0xF000            // IO_MOD_REG10 bits [15:12]: port J pins 6 (13:12) + 7 (15:14)
.equ UART2_PINMODE_AF,   0x5000            // mode = AF (01) for both pins
.equ UART2_AFR_MASK,     0x0FF00000        // AF_SEL_REG19 bits [27:20]: pin 6's nibble + pin 7's nibble
.equ UART2_AFR_VAL,      0x02200000        // AF2 for both pins
.equ UART2_PULL_MASK,    0x600000          // IO_PU_REG5/IO_PD_REG5: the exact bits `uart_set_baud_rate` clears -
                                           //   copied as-is rather than re-derived from a port/pin-number formula
.equ UART2_TC_VAL,       0x000F001A        // 115200 baud - this firmware's own literal value, see above
.equ UART2_TXFIFO_MASK,  0x1F00            // UART2_TH bits [12:8]: TX FIFO fill level
.equ UART2_TXFIFO_FULL,  0x1000            // uart_write_byte waits while fill level >= this

.equ ENCLK0_GPIO,     (1 << 1)             // GPIO block clock (probably already on, set again to be sure)
.equ ENCLK0_VOUT,     (1 << 19)            // VOUT (panel timing controller) bus clock
.equ ENCLK2_TIM5,     (1 << 20)            // TIM5 clock
.equ IPSWRST1_VOUT,   (1 << 19)            // VOUT reset bit
.equ IPSWRST2_TIM5,   (1 << 20)            // TIM5 reset bit

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
.equ SYS_PLLSAI0,   0x198                  // PLLSAI[0] (PLLSAI_CTRL1): bit0 = EN
.equ SYS_PLLSAI1,   0x19C                  // PLLSAI[1] (PLLSAI_CTRL2): DIVP/DIVQ/DIVR/DIVN, one byte each
.equ SYS_CMUST,     0x1A4                  // CMU clock status: bit 0 = HIRC, bit 1 = LIRC, bit 7 = PLLSAI stable
.equ SYS_CLKSRC3,   0xA0                   // CLKSRC[3]: bits [12:8] = VOUT_DIV
.equ CMUST_HIRC_STABLE,   1
.equ CMUST_LIRC_STABLE,   (1 << 1)
.equ PLLSAI_EN,           1
.equ CMUST_PLLSAI_STABLE, (1 << 7)
.equ REFCLK_SRC_MASK, 0x0F03               // sub_27630's own mask (~0xFFFFF0FC), the field REFCLK_SRC_VAL sits in
.equ REFCLK_SRC_VAL,  0x400                // sub_27630's exact value: select HOSC as this PLL cluster's reference
.equ PLLSAI_DIV_VAL, 0xAC020207            // sub_27630's exact value: DIVN=0xAC, DIVR=2, DIVQ=2, DIVP=7 -
                                           //   written only AFTER the stable wait, full overwrite, no read-modify-write
.equ VOUT_DIV_MASK,  (0x1F << 8)
.equ VOUT_DIV_VAL,   (0x15 << 8)           // 21: the firmware's init_lcd case 0x431 (this panel) value
.equ PLLSAI_WAIT_TIMEOUT, 3000000          // safety: give up waiting for PLLSAI stable after this many polls
.equ OSC_WAIT_TIMEOUT,    3000000          // same safety bound, for the HIRC/LIRC stable waits below

/* ---- panel (VOUT, 0x40026000): timing for this unit's 480x272 panel (g_scr_infos[0] in the IDB) ---- */
.equ VOUT_BASE,  0x40026000
.equ VOUT_SSCR,  0x00                      // (HSW-1)<<16 | (HFP-1)
.equ VOUT_BPCR,  0x04                      // (HSW+HBP-1)<<16 | (HFP+VSW-1)
.equ VOUT_AWCR,  0x08                      // (W-1+HBP+HSW)<<16 | (H-1+VSW+HFP)
.equ VOUT_TWCR,  0x0C                      // (HSW+HBP+W+VFP-1)<<16 | (HFP+VSW+H+VBP-1)
.equ VOUT_GCR,   0x10                      // bit 0 = enable
.equ VOUT_BCCR,  0x18                      // background colour (no active layer needed to show it)

/* ---- VOUT layer 0: the framebuffer ----
 * Register map from the vendor HAL (gm_ll_vout.h: VOUT_LAYER(base,n) = base + 0x30 + 0x30*n, and
 * VOUT_SetConfig's WHPCR/WVPCR/CFBLR formulas) rather than this firmware's ambiguous sub_21D9C:
 * it is the same STM32-LTDC-shaped set already confirmed correct for SSCR/BPCR/AWCR/TWCR/GCR/BCCR,
 * so it is trusted here too. */
.equ VOUT_L0_CR,     0x30                  // bit 0 = LEN (layer enable)
.equ VOUT_L0_WHPCR,  0x34                  // (window start + AHBP + 1) | (window stop + AHBP) << 16
.equ VOUT_L0_WVPCR,  0x38                  // (window start + AVBP + 1) | (window stop + AVBP) << 16
.equ VOUT_L0_PFCR,   0x40                  // pixel format: 2 = RGB565
.equ VOUT_L0_CACR,   0x44                  // constant alpha, 0..255
.equ VOUT_L0_DCCR,   0x48                  // default colour (shown where this layer is transparent/outside its window)
.equ VOUT_L0_CFBAR,  0x50                  // framebuffer address
.equ VOUT_L0_CFBLR,  0x54                  // (buffer stride in bytes) << 16 | (window width - 1) * bytes/pixel
.equ VOUT_L0_CFBLNR, 0x58                  // number of lines

.equ VOUT_AHBP, (PANEL_HSW + PANEL_HBP - 1)        // accumulated horizontal back porch: BPCR's own high half
.equ VOUT_AVBP, (PANEL_HFP + PANEL_VSW - 1)        // accumulated vertical back porch: BPCR's own low half
.equ VOUT_PF_RGB565, 2

/* ---- text: a hand-drawn 5x7 bitmap font, scaled up and blitted straight into the framebuffer ----
 * Not from any real font file (no license question, and only as many letters as "HELLO WORLD" needs) - each
 * glyph is 7 bytes, one per row, the row's pixels packed into bits [4:0] (bit 4 = leftmost column). Unknown
 * characters (anything not in the small dispatch table in draw_glyph) fall back to glyph_SP (blank), so this
 * is safe to feed any ASCII text, it just won't render letters outside this set. */
.equ GLYPH_W, 5
.equ GLYPH_H, 7
// TEXT_SCALE=4, not 6: at 6 the 4th identifier line (252 + one 42px-tall glyph = 294) ran past
// the 272px panel - the smaller font leaves headroom for added lines without re-deriving positions.
.equ TEXT_SCALE,   4                       // each font pixel becomes a TEXT_SCALE x TEXT_SCALE block on screen
.equ TEXT_X0,      40
.equ TEXT_Y0,      20
.equ TEXT_COLOR,   0x0000                  // black, on top of the green test fill
.equ CHAR_ADVANCE, ((GLYPH_W + 1) * TEXT_SCALE)    // glyph width plus one font-pixel of gap, both scaled

.equ TEXT_BUF, 0x90000                     // scratch RAM for building one hex line (11 bytes used) - this
                                           //   image's own code/data ends well below this (loaded at 0x80000,
                                           //   under 4 KiB so far), and it is far below FB_BASE
.equ ID_LINE_Y0,      60                   // first identifier line, below "HELLO WORLD" (TEXT_Y0=20, now 28px tall)
.equ ID_LINE_SPACING, 34                   // 28px glyph height (at TEXT_SCALE=4) + a gap, so lines don't touch

.equ FB_BASE,   0x200000                   // 2 MiB into SDRAM (address 0 = this image's own memory
                                                //  space, see the boot-contract comment above) - far past the
                                                //  image's code/data (0x80000) and well inside SDRAM (the
                                                //  app's own SP, 0x800000, implies at least 8 MiB).
// VOUT reads its framebuffer as a separate AHB bus master, not through the remap that makes SDRAM
// appear at low CPU addresses. Its native controller address is SDRAM_BASE = 0xC0000000 (FMC_BASE +
// 0x60000000, BSP soc_gm6721x.h). So CFBAR must be SDRAM_BASE + FB_BASE; the CPU-side fill loop
// below still uses the plain FB_BASE address.
.equ SDRAM_BASE, 0xC0000000
.equ FB_CFBAR_VAL, (SDRAM_BASE + FB_BASE)
.equ FB_WIDTH,  PANEL_WIDTH
.equ FB_HEIGHT, PANEL_HEIGHT
.equ FB_BPP,    2                          // RGB565: 2 bytes/pixel
.equ FB_PITCH,  (FB_WIDTH * FB_BPP)
.equ FB_WORDS,  (FB_WIDTH * FB_HEIGHT / 2) // 32-bit stores, 2 pixels per word (FB_WIDTH is even)

// The panel's glass is scanned from the opposite corner, so position-sensitive content must be
// pre-rotated 180 degrees (no VOUT flip/mirror bit exists - this IP is a plain timing controller,
// not a blitter). FB_BOTTOM_RIGHT is the address of the last pixel; draw_glyph (the only thing here
// that draws position-sensitive content - the solid fill doesn't care about direction) addresses
// pixels as offsets *backward* from it instead of forward from FB_BASE.
.equ FB_BOTTOM_RIGHT, (FB_BASE + (FB_HEIGHT - 1) * FB_PITCH + (FB_WIDTH - 1) * FB_BPP)
.equ FB_FILL_PIXEL, 0x07E0                 // RGB565 green: R=0, G=0x3F, B=0 - chosen to differ from the red BCCR test
.equ FB_FILL_WORD,  ((FB_FILL_PIXEL << 16) | FB_FILL_PIXEL)

// The layer's "window stop" field (the vendor HAL's windowX1) is literally the panel WIDTH (480)
// for a full-screen layer, NOT width-1: the firmware copies dword_762118 = 0x11001E0 (width =
// 0x1E0 = 480 low half, height = 0x110 = 272 high half) into both word4 and field_20 with no "-1".
// Using width-1 makes CFBLR's line-length 2 bytes short of the pitch, skewing each line's start
// and accumulating into visual noise over 272 lines.
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
// Diagnostic: pure red instead of white, to tell apart "BCCR works, backlight is just dim" (expect to see red)
// from "BCCR isn't what's actually visible" (expect the same grey/other colour regardless of this value).
// BCCR fields are BCRED (bits 23:16) / BCGREEN (8:15) / BCBLUE (0:7) per the BSP (gm_ll_vout.h) - channel
// order confirmed, not guessed, unlike the "all three bytes 0xFF" white test this replaces.
.equ VOUT_BCCR_WHITE, 0x00FF0000           // red only (BCRED = 0xFF, BCGREEN = BCBLUE = 0)

/* ---- backlight: GPIOC pin 9 = TIM8_CH2 (AF5), a separate PWM from the buzzer's TIM5 ----
 * VOUT drives the panel's RGB/sync, but the LED backlight is a separate enable: without it, VOUT
 * can produce a perfect signal while the panel stays dark (looks identical to "nothing works").
 * Sequence copied from the firmware's `backlight_init` (@0x1BA4). TIM8 is an "advanced" timer
 * (complementary outputs + break/dead-time unit), hence one extra register (BDTR) beyond TIM5.
 * Clock/reset: ENCLK2 / IPSWR2 bit 21 (same registers as TIM5, different bit). Not replicated:
 * backlight_init's GPIOB power-good poll - set_dim (@0x1CD8) shows that flag only changes a
 * secondary signal's drive sense, and every on path sets TIM8_CCR2 regardless, so it is not
 * required for this test. */
.equ SYS_IOMODE2,   0x2CC                  // IOMODE[2] (IO_MOD_REG3) = port C
.equ SYS_IOAFR6,    0x304                  // IOAFR port C pins 8..15 (AF_SEL_REG6)
.equ GPIOC_BASE,    0x40012000
.equ GPIOC_OBSR,    (GPIOC_BASE + 0x08)
.equ GPIOC_OMCR,    (GPIOC_BASE + 0x10)
.equ ENCLK2_TIM8,   (1 << 21)
.equ IPSWRST2_TIM8, (1 << 21)
.equ BL_PIN,            9
.equ BL_PIN_MASK,       (1 << BL_PIN)
.equ BL_IOMODE_MASK,    (3 << (2 * BL_PIN))               // pin 9's 2 mode bits in IOMODE[2] (whole port in one register)
.equ BL_IOMODE_AF,      (1 << (2 * BL_PIN))
.equ BL_AFR_MASK,       (0xF << (4 * (BL_PIN - 8)))       // AFR is split lo/hi (8 pins each); pin 9 is nibble 1 of the hi half
.equ BL_AFR_TIM8,       (5   << (4 * (BL_PIN - 8)))       // AF5 = TIM8_CH2

.equ TIM8_BASE,   0x40007500
.equ TIM8_CR1,    0x00
.equ TIM8_CCMR1,  0x18                     // channel 2's output-compare mode is bits [14:12] here
.equ TIM8_CCER,   0x20
.equ TIM8_PSC,    0x28
.equ TIM8_ARR,    0x2C
.equ TIM8_CCR2,   0x38
.equ TIM8_BDTR,   0x44                     // bit 15 = MOE (Main Output Enable) - without it the advanced
                                           //   timer's channel outputs stay off regardless of CR1/CCER
// backlight_init(3000): tier a1>500 -> PSC so the tick is 200MHz/8=25MHz, period = 25MHz/3000Hz
.equ BL_PSC_VAL,  7
.equ BL_PERIOD,   (25000000 / 3000)
.equ BL_ARR_VAL,  (BL_PERIOD - 1)
// set_dim (IDB 0x1CD8): CCR2 = period * (100 - brightness) / 100 - CC2P (CCER bit 5) inverts the channel, so a
// *small* CCR2 is *bright*, not a large one. BL_PERIOD/2 (50%, the firmware's literal post-init default) still
// looked grey on hardware, so this picks the equivalent of ~95% brightness instead for a clearer test.
.equ BL_CCR2_VAL, (BL_PERIOD / 20)

/* ---- buzzer pin: IO7 = GPIOI pin 3 = TIM5_CH4 (AF5) ----
 * The firmware's cfgpio_apply(7, 3, 0) (extended IO 7, mode 3 = PWM) touches exactly these bits.
 * Note: port I is the lower half of its register pair in the pull/open-drain registers, so the pin number
 * is used directly as the bit (port J would be shifted by 16). */
.equ BUZZER_PIN,        3
.equ BUZZER_PIN_MASK,   (1 << BUZZER_PIN)                 // bit of the pin in the pull / open-drain registers
.equ BUZZER_IOMODE_MASK, (3 << (2 * BUZZER_PIN))          // the pin's 2 mode bits in IOMODE[8]
.equ BUZZER_IOMODE_AF,   (1 << (2 * BUZZER_PIN))          // mode 1 = alternate function
.equ BUZZER_AFR_MASK,    (0xF << (4 * BUZZER_PIN))        // the pin's 4 AF bits in IOAFR[16]
.equ BUZZER_AFR_TIM5,    (5   << (4 * BUZZER_PIN))        // AF5 = TIM5_CH4 (BSP: GPIOI3_AF5_TIM5_CH4)
.equ GPIOI_OMCR,        0x40019010         // GPIOI base 0x40019000 + 0x10 (output mode control: writing the pin's
                                           //   bit selects output mode; the firmware does this for the PWM pin too)

/* ---- TIM5 (0x40007400), STM32-like layout (BSP TIM_Device_T) ---- */
.equ TIM5_BASE,  0x40007400
.equ TIM_CR1,    0x00                      // control 1: bit 0 = counter enable
.equ TIM_CCMR1,  0x18                      // capture/compare mode 1: output compare modes of channels 1 and 2
.equ TIM_CCMR2,  0x1C                      // capture/compare mode 2: output compare modes of channels 3 and 4
.equ TIM_CCER,   0x20                      // capture/compare enable (4 bits per channel: enable, polarity, ...)
.equ TIM_PSC,    0x28                      // prescaler: timer tick = clock / (PSC + 1)
.equ TIM_ARR,    0x2C                      // auto-reload: period = ARR ticks
.equ TIM_CNT,    0x24                      // counter: counts 0..ARR, then wraps to 0 (one wrap = one PWM period)
.equ TIM_CCR4,   0x40                      // compare value of channel 4: pulse width in ticks

/* ---- timer setup shared by all notes ---- */
.equ TIM_PSC_VAL,   99                     // 200 MHz / (99 + 1) = 2 MHz timer tick (the firmware's choice for 100 Hz..10 kHz)
.equ TIM_HZ,        2000000                // timer tick rate after the prescaler
.equ WAIT_TIMEOUT,  30000000               // safety: give up waiting for one note after this many loop iterations
                                           //   (only reached if the counter does not run)

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
    .word \ms                              // 1 kHz filler period = 1 ms
    .word (TIM_HZ / 1000)
    .word 0
.endm

/* uart_dump_buf: sends TEXT_BUF (nul-terminated, same buffer hex_line/draw_text already built this call's on-
 * screen line from) followed by CRLF, so every on-screen diagnostic line also lands in the serial log verbatim
 * (see the UART2 section further down for uart_puts/uart_putc themselves). Clobbers r0-r4 and lr (saved/restored
 * internally) - callers don't need to wrap this in their own push/pop. Defined here (not next to uart_puts/
 * uart_putc) because a macro must be defined before any use, even one nested inside another macro's body -
 * entry's ID-register readout below is the earliest use. */
.macro uart_dump_buf
    push {lr}
    ldr r0, =TEXT_BUF
    bl uart_puts
    movs r0, #0x0D
    bl uart_putc
    movs r0, #0x0A
    bl uart_putc
    pop {lr}
.endm

/* ==========================================================================
 *  Image
 * ========================================================================== */

// Needed from here on (the text-drawing code uses r8-r12 and more varied immediate forms than anything
// earlier in this file): without it, GNU as defaults to legacy "divided" Thumb syntax, which is actually
// stricter than real Thumb-1 hardware - it refuses high registers and most immediate forms outright instead
// of picking a wider Thumb-2 encoding, even though this CPU (-mcpu=cortex-m4) fully supports Thumb-2.
.syntax unified
.section .vector_table, "a"            // explicit alloc flag: needed now that this is its own output section
                                        // (linker.ld), not merged into .text, which gets the flag by default
.global vectors
.vectors:
    // MSP the loader switches to before it BLXes entry (ldr_exec_: `msr msp, [image]; blx [image+4]`), and the
    // stack the loader then returns on (`pop {r4,r5,r6,pc}` in ldr_exec_, then `pop {r4-r8,pc}` in ldr_exec).
    // It must therefore be the loader's own SP at that moment, not its initial one:
    //   0x20000680 (initial SP, set at 0x20001268) - 16 (ldr_main push) - 24 (ldr_exec push) - 16 (ldr_exec_ push)
    //   = 0x20000648. With 0x20000680 the `bx lr` return pops garbage and the board hangs.
    .word 0x20000648
    .word entry + 1                        // reset vector -> entry (Thumb)
    .word 0                                // NMI: unused (interrupts are masked by the loader)
    .word fault_trap + 1                   // HardFault: diagnostic trap - parks the fault-time SP in FAULT_WORD
                                           //   and spins until the IWDG resets; the warm bail prints it as "F:.."
    .rept 13
        .word 0                          // unused: entry returns via LR; interrupts are masked by the loader
    .endr
    // The table is kept to the 16 Cortex-M system vectors on purpose: fw_pack.pack() overwrites image offsets
    // 0x1C8..0x1DB (and the loader owns 0x1C8..0x267) with the container header (CRCs, length), so the vector table,
    // the code and its literal pool must all end below 0x1C8 - linker.ld asserts that.

/* rmw addr, clr, set: read-modify-write of a 32-bit register at an absolute address:
 *     *addr = (*addr & ~clr) | set
 * The full address comes from the literal pool because the 16-bit Thumb ldr/str here only reach offsets up
 * to 124 (SYS registers are at 0x80..0x330). Clobbers r0-r3. r4-r11 belong to the caller (the loader) and
 * must survive the `bx lr` return: the only other register used, r4, is saved on the stack around the wait. */
.macro rmw addr, clr, set
    ldr r0, =\addr                         // r0 = register address
    ldr r1, =\clr                          // r1 = bits to clear
    ldr r3, =\set                          // r3 = bits to set
    ldr r2, [r0]                           // r2 = current value
    bic r2, r2, r1                         // r2 &= ~clr
    orr r2, r2, r3                         // r2 |= set
    str r2, [r0]                           // write back
.endm

/* ensure_lirc: enables LIRC (the internal low-speed RC oscillator, SYS_LIRC_CTRL) and waits for
 * CMUST's LIRC-stable bit, bailing after OSC_WAIT_TIMEOUT polls instead of hanging forever. This
 * must run before arming the IWDG: this SoC's oscillators are OFF by default and must be
 * explicitly enabled (the exact bug that cost the PLLSAI iterations), and IWDG's "independent"
 * clock comes from this same LIRC - arming it before LIRC runs just loads a counter that never
 * ticks. Clobbers r0, r2, r3, r4 (same convention as rmw). */
.macro ensure_lirc
    rmw (SYS_BASE + SYS_LIRC_CTRL), 0, CMUST_LIRC_STABLE
    ldr r0, =(SYS_BASE + SYS_CMUST)
    ldr r4, =OSC_WAIT_TIMEOUT
.Lensure_lirc_wait\@:
    ldr r2, [r0]
    ldr r3, =CMUST_LIRC_STABLE
    tst r2, r3
    bne .Lensure_lirc_stable\@
    sub r4, r4, #1
    cmp r4, #0
    bne .Lensure_lirc_wait\@
.Lensure_lirc_stable\@:
.endm

.section .text
.global entry
.thumb_func
entry:
    // ---- reset-survival flag: on a repeat run since the last cold boot, skip straight back to
    // the loader (-> stock firmware). ldr_main rescans the SD card on EVERY reset, including one
    // from a hung stage1 tripping the IWDG - a reset does not erase SRAM (only a real power-on
    // would) - so a flag planted outside the loader's working set survives it. Without this, a
    // watchdog would restart stage1 forever instead of ever reaching stock. This check must be the
    // very first thing in entry, before anything touches r4-r11 or lr, so the early-exit bails
    // with nothing to unwind. Two states: DONE (skip straight to stock) or not (run once).
    ldr r0, =BOOT_FLAG_ADDR
    ldr r1, [r0]
    ldr r2, =BOOT_FLAG_DONE
    cmp r1, r2
    bne .flag_run
.flag_bail:
    // A warm pass only happens after an IWDG reset (the cold pass hung). If that hang was a
    // HardFault, fault_trap parked the fault-time SP in FAULT_WORD: print it as "F:XXXXXXXX" (the
    // SP says which frame was live - see fault_trap) before bailing to stock. Range-checked so
    // cold-SRAM garbage on a true power-on never prints. uart_init runs only on this dump path
    // (after the reset the GPIO mux is dead; the normal in-boot bail must stay out of it).
    ldr r0, =FAULT_WORD
    ldr r1, [r0]
    ldr r2, =0x20000000
    cmp r1, r2
    blo .Lsb_sp
    ldr r2, =0x20010000
    cmp r1, r2
    bhs .flag_bail_out
    push {lr}
    bl uart_init
    b .flag_bail_dump
.Lsb_sp:
    ldr r2, =0x700000
    cmp r1, r2
    blo .flag_bail_out
    ldr r2, =0x810000
    cmp r1, r2
    bhs .flag_bail_out
    push {lr}
    bl uart_init
    b .flag_bail_dump
.flag_bail_dump:
    fault_word 0x46, FAULT_WORD              // 'F'  fault-time SP (the gate value)
    fault_word 0x50, FAULT_FRAME + 24        // 'P'  faulting PC (Thumb bit set -> exact instruction)
    fault_word 0x4C, FAULT_FRAME + 20        // 'L'  fault-time LR (caller)
    fault_word 0x30, FAULT_FRAME + 0         // '0'  fault-time R0
    fault_word 0x31, FAULT_FRAME + 4         // '1'  fault-time R1
    fault_word 0x58, FAULT_FRAME + 28        // 'X'  fault-time xPSR (Thumb = bit 24, 0x01000000, on ARMv7-M)
    fault_word 0x43, FAULT_STATUS + 0        // 'C'  CFSR (usage/bus fault bits -> fault type)
    fault_word 0x48, FAULT_STATUS + 4        // 'H'  HFSR (lockup bit)
    fault_word 0x42, FAULT_STATUS + 8        // 'B'  BFAR (fault address for precise bus faults)
    pop {lr}
.flag_bail_out:
    bx lr                                   // already ran once since the last cold boot: straight to stock firmware
.flag_run:
    str r2, [r0]                            // mark done before doing anything risky
    ldr r0, =FAULT_WORD                     // clear the trap's word on every cold pass (SRAM after a true
    movs r1, #0                             //   power-off is only guaranteed zero, so do it explicitly)
    str r1, [r0]

    push {lr}                               // lr still holds the loader's own return address at this point -
                                           //   nothing has pushed it yet, so these two `bl`s must not clobber it
    bl uart_init                             // mirror every diagnostic line below out over the TJC serial link too
    ldr r0, =uart_banner
    bl uart_puts
    bl install_entry_hook                    // see its own comment: the 2nd-melody hook, so we
                                              // regain control after every future ldr_exec (the stock pass)
    // ---- verify the patch we just wrote: read the 32 bytes back out of the loader's SRAM and
    // compare them byte-for-byte against patch_blob (the very source install_entry_hook copied).
    // A clean read-back proves the next ldr_exec_ (the stock pass) will detour through
    // entry_trampoline; a mismatch means the stores silently failed and the 2nd melody can
    // never play.
    push {r4-r7, lr}
    ldr r4, =LDR_CALL_PATCH_SITE
    ldr r5, =LDR_EXEC_BLX_SITE
    ldr r6, =patch_blob
    movs r7, #0
.pv_site1_word:
    ldr r0, [r6, r7]                         // expected word
    ldr r1, [r4, r7]                         // actual: site1 read-back
    cmp r0, r1
    bne .pv_bad
    adds r7, r7, #4
    cmp r7, #24
    beq .pv_site2_word
    b .pv_site1_word
.pv_site2_word:
    ldr r6, =(patch_blob + 24)
    movs r7, #0
.pv_site2_loop:
    ldr r0, [r6, r7]
    ldr r1, [r5, r7]
    cmp r0, r1
    bne .pv_bad
    adds r7, r7, #4
    cmp r7, #8
    beq .pv_ok
    b .pv_site2_loop
.pv_bad:
    ldr r0, =pv_bad_str
    bl uart_puts                             // uart_puts preserves r4 (pushes/pops it); r5-r7 untouched
    ldr r0, [r4]                             // first read-back word of each site, for forensics
    movs r1, #0x70                          // 'p' = site1
    ldr r2, =TEXT_BUF
    bl hex_line
    ldr r0, =TEXT_BUF
    bl uart_puts
    ldr r0, [r5]
    movs r1, #0x71                          // 'q' = site2
    ldr r2, =TEXT_BUF
    bl hex_line
    ldr r0, =TEXT_BUF
    bl uart_puts
    b .pv_tail
.pv_ok:
    ldr r0, =pv_ok_str
    bl uart_puts
.pv_tail:
    b .pv_flushed
    .ltorg                                   // flush this block's pool before entry's next ldr-pc sequence
.pv_flushed:
    pop {r4-r7, lr}
    pop {lr}

    // ---- arm the hardware watchdog (~10s, see IWDG_RLR_VAL) before anything that could hang: a
    // last-resort net under the reset-survival flag and the software touch-wait timeout, covering
    // a hang in code a software timeout never reaches (a clobbered-lr self-loop was found this
    // way). iwdg_feed is called throughout; anywhere it stops for ~10s the chip resets and the
    // flag sends the next pass straight to stock firmware.
    ensure_lirc                                                   // IWDG's clock - see the macro's own comment
    rmw (SYS_BASE + SYS_PWR_MODE_REG), 0, PWR_BKP_UNLOCK_BIT      // unlock backup-domain writes
    ldr r0, =IWDG_KR
    ldr r1, =IWDG_KEY_UNLOCK
    str r1, [r0]                                                  // unlock IWDG_PR/IWDG_RLR for writing
    ldr r0, =IWDG_PR
    ldr r1, =IWDG_PR_VAL
    str r1, [r0]
.iwdg_pr_verify:
    ldr r2, [r0]
    cmp r2, r1
    bne .iwdg_pr_verify                      // same poll-until-latched pattern the firmware's own `restart` uses
    ldr r0, =IWDG_RLR
    ldr r1, =IWDG_RLR_VAL
    str r1, [r0]
.iwdg_rlr_verify:
    ldr r2, [r0]
    cmp r2, r1
    bne .iwdg_rlr_verify
    ldr r0, =IWDG_KR
    ldr r1, =IWDG_KEY_START
    str r1, [r0]                                                  // (re)start: harmless if already running
    rmw (SYS_BASE + SYS_PWR_MODE_REG), PWR_BKP_UNLOCK_BIT, 0      // re-lock the backup domain

    // r6 reports whether PLLSAI really reached CMUST_PLLSAI_STABLE or we gave up after PLLSAI_WAIT_TIMEOUT -
    // picked up again below to choose which melody plays, as an audible yes/no without any UART. Pushed here
    // (not just around the wait) because it must survive everything up to the melody choice; popped with
    // r4/r5 before the final bx lr, below.
    push {r6}
    movs r6, #0                             // 0 = reached stable; set to 1 below only on timeout

    // ==== panel (VOUT): clock, reset, pinmux, timing, solid white - see the header comment for sources ====
    rmw (SYS_BASE + SYS_ENCLK0), 0, ENCLK0_GPIO | ENCLK0_VOUT        // GPIO clock (see below) + VOUT clock
    rmw (SYS_BASE + SYS_IPSWRST1), IPSWRST1_VOUT, 0                  // assert VOUT reset
    rmw (SYS_BASE + SYS_IPSWRST1), 0, IPSWRST1_VOUT                  // release VOUT reset

    // port E: all 16 pins = alternate function (the 16 RGB565 data lines). 0x55555555 = mode 1
    // repeated (with "0 = GPIO, 1 = AF, 3 = analog" per 2-bit pin), matching the real init_lcd;
    // 0xFFFFFFFF would be mode 3 = ANALOG, floating every data line (HSYNC/VSYNC/DE/PCLK on port F
    // were correct, so a valid timing with undefined colour = uniform grey).
    rmw (SYS_BASE + SYS_IOMODE4), 0, 0x55555555                      // mode = AF (01) for every pin, matching the firmware
    rmw (SYS_BASE + SYS_IOAFR9),  0, 0x22222222                      // AF2, pins 0..7
    rmw (SYS_BASE + SYS_IOAFR10), 0, 0x22222222                      // AF2, pins 8..15

    // port F: only pins 0..4 (HSYNC/VSYNC/DE/PCLK + one more); pins 5..6 are touch RST/INT, left untouched
    rmw (SYS_BASE + SYS_IOMODE5), 0x3FF, 0x155                       // mode = AF for pins 0..4 only
    rmw (SYS_BASE + SYS_IOAFR11), 0xFFFFFFFF, 0x22222                // AF2, pins 0..4 (pins 5..7 untouched: no mode change above)

    // no pulls on the panel's own pins (port E all, port F pins 0..4): E = low 16 bits, F = high 16 bits
    rmw (SYS_BASE + SYS_IOPU_EF), 0x001FFFFE, 0
    rmw (SYS_BASE + SYS_IOPD_EF), 0x001FFFFE, 0

    // ---- oscillators + reference select: sub_27630's prefix, before it ever touches PLLSAI ----
    rmw (SYS_BASE + SYS_HIRC_CTRL), 0, CMUST_HIRC_STABLE              // bit 0 = EN, same bit position as its CMUST flag
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
    ldr r0, =(SYS_BASE + SYS_CMUST)         // reload: the rmw above clobbered r0
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

    rmw (SYS_BASE + SYS_HOSC_CTRL), 1, 0                              // HOSC/LOSC: bit 0 = stop/power-down,
    rmw (SYS_BASE + SYS_LOSC_CTRL), 1, 0                              //   active-low (clearing it enables them)
    rmw (SYS_BASE + SYS_REFCLK_SRC), REFCLK_SRC_MASK, REFCLK_SRC_VAL  // select HOSC as this PLL cluster's reference

    // ---- VOUT pixel clock: PLLSAI must be enabled and stable before the VOUT_DIV divider does anything ----
    // sub_27630's exact sequence: enable (no VCO/CPC write), wait stable, *then* overwrite the dividers.
    rmw (SYS_BASE + SYS_PLLSAI0), 0, PLLSAI_EN                              // enable PLLSAI

    ldr r0, =(SYS_BASE + SYS_CMUST)
    ldr r4, =PLLSAI_WAIT_TIMEOUT
.pllsai_wait:
    ldr r2, [r0]
    ldr r3, =CMUST_PLLSAI_STABLE
    tst r2, r3
    bne .pllsai_stable                     // PLLSAI reports stable: move on
    sub r4, r4, #1                         // sub (not subs): no flag-immediate in this Thumb-16 mode
    cmp r4, #0
    bne .pllsai_wait                       // safety timeout: proceed anyway rather than hang forever
    movs r6, #1                             // record that we gave up instead of seeing the stable bit
.pllsai_stable:

    ldr r0, =(SYS_BASE + SYS_PLLSAI1)
    ldr r2, =PLLSAI_DIV_VAL
    str r2, [r0]                                                           // full overwrite, not a read-modify-write

    rmw (SYS_BASE + SYS_CLKSRC3), VOUT_DIV_MASK, VOUT_DIV_VAL                // VOUT pixel clock divider

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
    // sub_F0AC actually ORs in (tft_id | field_18 | field_1C | field_20) here, not just the enable bit; for this
    // panel (model 0x431) the latter three are 0 in g_scr_infos[0] (confirmed by reading the struct's raw
    // bytes), so the real value is 0x431 itself - it sets a couple of low dither-width bits (DBW/DGW) along
    // with enable (bit 0, already part of 0x431), which does not affect whether anything is visible.
    ldr r2, [r1, #VOUT_GCR]
    ldr r3, =0x0FFFFFFF
    and r2, r2, r3                                                   // clear bits [31:28], as the firmware does
    ldr r3, =0x431
    orr r2, r2, r3                                                   // enable + this panel's dither-width bits
    str r2, [r1, #VOUT_GCR]

    // Flush the literal pool here: without periodic breaks like this, GNU as puts every `ldr rX, =value` literal
    // in one pool at the end of the function, and this function got long enough that the earliest such loads
    // fall outside the 16-bit `ldr`'s +/-1020-byte reach ("invalid offset, value too big"). `b`+`.ltorg`+label
    // dumps the pool without falling through into it as data.
    b 1f
    .ltorg
1:
    iwdg_feed
    // ==== layer 0: framebuffer, filled solid green - see the header comment's "Step B" section ====
    // Fill first (two RGB565 pixels per 32-bit store), so the layer never displays whatever garbage SDRAM
    // already held at FB_BASE in the moment between enabling it and finishing the fill.
    ldr r0, =FB_BASE
    ldr r2, =FB_FILL_WORD
    ldr r4, =FB_WORDS
.fb_fill:
    str r2, [r0]
    add r0, r0, #4
    sub r4, r4, #1                         // sub (not subs): no flag-immediate in this Thumb-16 mode
    cmp r4, #0
    bne .fb_fill

    ldr r1, =VOUT_BASE                     // reload: r1 was VOUT_BASE already, but be explicit
    ldr r2, =VOUT_L0_WHPCR_VAL
    str r2, [r1, #VOUT_L0_WHPCR]
    ldr r2, =VOUT_L0_WVPCR_VAL
    str r2, [r1, #VOUT_L0_WVPCR]
    ldr r2, =VOUT_PF_RGB565
    str r2, [r1, #VOUT_L0_PFCR]
    movs r2, #255
    str r2, [r1, #VOUT_L0_CACR]            // fully opaque: no blending with BCCR behind it
    movs r2, #0
    str r2, [r1, #VOUT_L0_DCCR]
    ldr r2, =FB_CFBAR_VAL                   // SDRAM_BASE + FB_BASE: VOUT's own bus address, not the CPU's
    str r2, [r1, #VOUT_L0_CFBAR]
    ldr r2, =VOUT_L0_CFBLR_VAL
    str r2, [r1, #VOUT_L0_CFBLR]
    ldr r2, =FB_HEIGHT
    str r2, [r1, #VOUT_L0_CFBLNR]
    movs r2, #1
    str r2, [r1, #VOUT_L0_CR]               // LEN: enable the layer

    // ==== draw "HELLO WORLD" into the framebuffer, on top of the green fill - see draw_text/draw_glyph below ====
    // bl/bx lr need LR, which right now still holds the loader's own return address (from its BLX into this
    // image) - save it around every nested `bl` so entry's own final `bx lr` still works afterward.
    ldr r0, =text_string
    ldr r1, =TEXT_X0
    ldr r2, =TEXT_Y0
    push {lr}
    bl draw_text
    ldr r0, =text_string
    bl uart_puts
    movs r0, #0x0D
    bl uart_putc
    movs r0, #0x0A
    bl uart_putc
    pop {lr}

    b 2f                                     // literal-pool flush, see the comment at the previous one
    .ltorg
2:
    iwdg_feed
    // ==== identifiers: a couple of real SoC/core ID registers, in hex, one per line - see hex_line below ====
    // "0:" = CID (the stage-0 loader's own chip-variant register, SYS_BASE+0x00, see the firmware-hazards and
    // soc-identification project memories); "1:" = CPUID (standard ARM SCB->CPUID, 0xE000ED00 - generic to any
    // Cortex-M, not vendor-specific). OTP CHIPID1/2 are deliberately not shown here: their offsets are known
    // (0x10/0xF0) but the OTP block's own base address was never pinned down, so reading them would be a guess.
    ldr r0, =SYS_BASE
    ldr r0, [r0]
    movs r1, #0x30                           // '0'
    ldr r2, =TEXT_BUF
    push {lr}
    bl hex_line
    pop {lr}
    ldr r0, =TEXT_BUF
    ldr r1, =TEXT_X0
    ldr r2, =ID_LINE_Y0
    push {lr}
    bl draw_text
    uart_dump_buf
    pop {lr}

    ldr r0, =0xE000ED00                      // CPUID
    ldr r0, [r0]
    movs r1, #0x31                           // '1'
    ldr r2, =TEXT_BUF
    push {lr}
    bl hex_line
    pop {lr}
    ldr r0, =TEXT_BUF
    ldr r1, =TEXT_X0
    ldr r2, =(ID_LINE_Y0 + ID_LINE_SPACING)
    push {lr}
    bl draw_text
    uart_dump_buf
    pop {lr}

    // g_scr_info.field_16 (the touch-controller-type selector, confirmed GT911 via the now-removed two-pass
    // probe - see entry's own history comment) is no longer read/displayed here: on a single-boot flow, stock
    // firmware hasn't run yet by this point, so that SDRAM address holds leftover/uninitialized content, not a
    // real value - displaying it now would just be misleading.

    b 3f
    .ltorg
3:
    iwdg_feed
    // ==== backlight (TIM8 PWM on GPIOC pin 9): see the header comment's backlight section ====
    rmw (SYS_BASE + SYS_ENCLK0), 0, ENCLK0_GPIO                      // GPIO clock (harmless repeat)
    rmw (SYS_BASE + SYS_ENCLK2), 0, ENCLK2_TIM8                      // TIM8 clock
    rmw (SYS_BASE + SYS_IPSWRST2), IPSWRST2_TIM8, 0                  // assert TIM8 reset
    rmw (SYS_BASE + SYS_IPSWRST2), 0, IPSWRST2_TIM8                  // release TIM8 reset

    rmw (SYS_BASE + SYS_IOMODE2), BL_IOMODE_MASK, BL_IOMODE_AF        // pin mode = alternate function
    rmw (SYS_BASE + SYS_IOAFR6),  BL_AFR_MASK, BL_AFR_TIM8            // alternate function number = 5

    ldr r0, =GPIOC_OMCR                     // output-mode-control bit for the pin, as the firmware does
    ldr r2, =BL_PIN_MASK
    str r2, [r0]
    ldr r0, =GPIOC_OBSR                     // drive it low before the PWM takes over (the firmware does the same)
    str r2, [r0]

    ldr r1, =TIM8_BASE
    movs r2, #0
    str r2, [r1, #TIM8_CR1]                 // stopped while configuring
    ldr r2, =BL_PSC_VAL
    str r2, [r1, #TIM8_PSC]
    ldr r2, =BL_ARR_VAL
    str r2, [r1, #TIM8_ARR]
    ldr r0, [r1, #TIM8_CCMR1]
    ldr r2, =0xFFFF00FF
    and r0, r0, r2
    ldr r2, =0x7000                         // OC2M = 0b111 (PWM mode 2), channel 2
    orr r0, r0, r2
    str r0, [r1, #TIM8_CCMR1]
    ldr r0, [r1, #TIM8_CCER]
    ldr r2, =0xFFFFFF0F
    and r0, r0, r2
    ldr r2, =0x50                           // CC2E + CC2NE (channel 2, firmware's own value)
    orr r0, r0, r2
    str r0, [r1, #TIM8_CCER]
    ldr r0, [r1, #TIM8_BDTR]
    ldr r2, =0x8000                         // MOE: without this the advanced timer's outputs stay off
    orr r0, r0, r2
    str r0, [r1, #TIM8_BDTR]
    ldr r2, =BL_CCR2_VAL
    str r2, [r1, #TIM8_CCR2]
    movs r2, #1
    str r2, [r1, #TIM8_CR1]                 // go

    // ==== buzzer (TIM5): unchanged from before - see the header comment's buzzer section ====
    // ---- enable the GPIO and TIM5 clocks ----
    // A peripheral whose clock is off ignores register writes, so this has to come first.
    rmw (SYS_BASE + SYS_ENCLK0), 0, ENCLK0_GPIO
    rmw (SYS_BASE + SYS_ENCLK2), 0, ENCLK2_TIM5

    // ---- pulse the TIM5 software reset (active low) ----
    // Puts the timer into a known state (whatever the stage-0 loader or the previous run left behind).
    rmw (SYS_BASE + SYS_IPSWRST2), IPSWRST2_TIM5, 0            // assert reset
    rmw (SYS_BASE + SYS_IPSWRST2), 0, IPSWRST2_TIM5            // release reset

    // ---- pin PI3: alternate function 5 (TIM5_CH4), no pulls, push-pull ----
    rmw (SYS_BASE + SYS_IOMODE8), BUZZER_IOMODE_MASK, BUZZER_IOMODE_AF   // pin mode = alternate function
    rmw (SYS_BASE + SYS_IOAFR16), BUZZER_AFR_MASK, BUZZER_AFR_TIM5       // alternate function number = 5
    rmw (SYS_BASE + SYS_IOPULLUP4), BUZZER_PIN_MASK, 0                   // no pull-up
    rmw (SYS_BASE + SYS_IOPULLDOWN4), BUZZER_PIN_MASK, 0                 // no pull-down
    rmw (SYS_BASE + SYS_IOODC4), BUZZER_PIN_MASK, 0                      // push-pull (not open drain)

    ldr r0, =GPIOI_OMCR                    // output-mode-control bit for the pin (as the firmware does)
    ldr r2, =BUZZER_PIN_MASK
    str r2, [r0]

    // ---- TIM5: PWM on CH4 (everything except the note-specific ARR / CCR4) ----
    // Same values the firmware's `pwmf`/`beep` path writes (function at 0x1FA40 in the IDB).
    ldr r1, =TIM5_BASE                     // r1 = TIM5 base for the rest of the file
    movs r2, #0
    str r2, [r1, #TIM_CR1]                 // stopped while configuring
    ldr r2, =TIM_PSC_VAL
    str r2, [r1, #TIM_PSC]                 // 2 MHz tick
    ldr r2, =0x7070                        // OCxM = 0b111 (PWM mode 2) for both channels of the register
    str r2, [r1, #TIM_CCMR1]               // channels 1, 2 (unused, configured like the firmware does)
    str r2, [r1, #TIM_CCMR2]               // channels 3, 4
    ldr r2, =0x3333                        // all four channels: output enabled, polarity bit set
    str r2, [r1, #TIM_CCER]

    b 3f                                     // literal-pool flush, see the comment at the first one
    .ltorg
3:
    // ---- play the melody (1st, "ta-daa") ----
    // The stack is the loader's (MSP = 0x20000648, vector word 0): pushing below it is safe. melody_play
    // is self-contained (re-sets the tick rate, clobbers only r0-r5, leaves the stack balanced), so only
    // the table pointer needs setting up.
    cmp r6, #0
    beq .pllsai_was_stable
    ldr r0, =melody_pllsai_timeout          // r6 == 1: PLLSAI never reported stable
    b .play_melody
.pllsai_was_stable:
    ldr r0, =melody
.play_melody:
    bl melody_play                          // stops TIM5 when done (the pin stays TIM5_CH4, output silent)

    // ==== fixed 3-second hold (melody-isolation: the touch section was removed; the hand-off
    // under test is the 2nd melody on the stock pass, which fires shortly after this return) ====
    // melody_play just stopped TIM5. Slow the prescaler to 10 kHz (1 tick = 100 us) and run the
    // free counter 30000 ticks = 3 s in one timer_delay_ticks call (wrap-safe to 6.5 s at this
    // rate), then stop and restore the buzzer section's 2 MHz (TIM_PSC_VAL) so the 2nd-melody
    // caller finds the timer exactly as it left it. IWDG was last fed in the ID-register block;
    // this whole tail (~4 s) is inside its ~10 s window, so no feed is needed here.
    ldr r1, =TIM5_BASE
    ldr r2, =19999                                 // 200 MHz / 20000 = 10 kHz tick
    str r2, [r1, #TIM_PSC]
    ldr r2, =0xFFFF
    str r2, [r1, #TIM_ARR]
    movs r2, #1
    str r2, [r1, #TIM_CR1]                         // run the counter
    timer_delay_ticks 30000                        // 3 s (clobbers r0-r3 incl. r1 - reloaded below)
    ldr r1, =TIM5_BASE
    movs r2, #0
    str r2, [r1, #TIM_CR1]                         // stop the counter
    ldr r2, =TIM_PSC_VAL                           // back to the buzzer section's 2 MHz
    str r2, [r1, #TIM_PSC]
    b .delay3s_done
    .ltorg
.delay3s_done:
    // ---- done: the cold pass is complete. Set HOOK_DONE: the 2nd melody plays exactly once, on
    // this boot's final stock-firmware call (a1 == 0 in entry_trampoline), and is consumed there.
    // Exit is NOT `bx lr`: this call's 0x1dfc resume point is now site2's patched `blx r0`
    // (originally MOVS R0,#0), and r0 here is HOOK_DONE_ADDR - even, so ARM mode, whose stored
    // magic word 0x484f4f44 decodes as an undefined ARM instruction -> HardFault -> IWDG reset ->
    // ROM re-copies the loader (patch wiped) -> warm bail -> stock, with the trampoline never
    // entered (the m2c/m2d symptom). Instead, jump straight into entry_trampoline: its SD path
    // (a1 = 0x80000 from this call's frame) prints T SD, bl's entry (BOOT_FLAG == DONE -> immediate
    // warm bail, no print) and its epilogue unwinds both frames back to ldr_main -> slot loop ->
    // the stock ldr_call -> trampoline stock path (melody2 + blx ldr_last_dst).
    ldr r0, =HOOK_DONE_ADDR
    ldr r1, =HOOK_DONE_MAGIC
    str r1, [r0]
    ldr r1, =entry_trampoline
    b .tail_trampoline                      // m2f/m2g: the .ltorg below emits the pending pool between this ldr
                                            // and the pop with nothing branching across, so the CPU executed the
                                            // pool as Thumb (faults at 0x81824 / 0x818E8). Cross it like .delay3s_done.
    .ltorg
.tail_trampoline:
    pop {r6}
    bx r1

/* ==========================================================================
 *  Text: draw_text / draw_glyph (called once, via `bl`, from the main flow above)
 * ========================================================================== */

/* draw_text(r0 = nul-terminated string pointer, r1 = x0, r2 = y0): walks the string, calls draw_glyph per
 * character, advances the cursor. r4-r11 are the loader's (see the register-convention comment near the top
 * of this file) - saved here with `lr` in one push/pop so this whole call (and whatever draw_glyph does
 * inside it) is transparent to the caller. r0-r3 are scratch throughout this file and are not saved - the
 * three inputs are moved into callee-saved registers immediately, before the push list's own r3 use. */
.thumb_func
draw_text:
    push {r3, r4, r5, r6, r7, r8, r9, r10, r11, lr}
    mov r7, r0                              // string pointer
    mov r8, r1                              // cursor x, advances after each character
    mov r9, r2                              // fixed: single line of text
    ldr r3, =TEXT_COLOR                     // constant for the whole call; draw_glyph must not clobber r3
.dt_loop:
    ldrb r0, [r7]
    adds r7, r7, #1
    cmp r0, #0
    beq .dt_done
    bl draw_glyph                          // leaf function: does not touch r3/r7/r8/r9, only r0-r2/r4-r6/r10-r12
    ldr r1, =CHAR_ADVANCE
    add r8, r8, r1
    b .dt_loop
.dt_done:
    pop {r3, r4, r5, r6, r7, r8, r9, r10, r11, pc}

/* draw_glyph: draws the character in r0 at (r8, r9) (both read-only here). r3 = colour (read-only).
 * Leaf function (no nested `bl`): returns via `bx lr` without its own push/pop. */
.thumb_func
draw_glyph:
    cmp r0, #0x48                           // 'H'
    bne .dg_try_E
    ldr r10, =glyph_H
    b .dg_have_glyph
.dg_try_E:
    cmp r0, #0x45                           // 'E'
    bne .dg_try_L
    ldr r10, =glyph_E
    b .dg_have_glyph
.dg_try_L:
    cmp r0, #0x4C                           // 'L'
    bne .dg_try_O
    ldr r10, =glyph_L
    b .dg_have_glyph
.dg_try_O:
    cmp r0, #0x4F                           // 'O'
    bne .dg_try_W
    ldr r10, =glyph_O
    b .dg_have_glyph
.dg_try_W:
    cmp r0, #0x57                           // 'W'
    bne .dg_try_R
    ldr r10, =glyph_W
    b .dg_have_glyph
.dg_try_R:
    cmp r0, #0x52                           // 'R'
    bne .dg_try_D
    ldr r10, =glyph_R
    b .dg_have_glyph
.dg_try_D:
    cmp r0, #0x44                           // 'D'
    bne .dg_try_hex
    ldr r10, =glyph_D
    b .dg_have_glyph
.dg_try_hex:
    cmp r0, #0x30                           // '0'
    blt .dg_try_colon
    cmp r0, #0x39                           // '9'
    bgt .dg_try_AF
    ldr r1, =glyph_0
    sub r0, r0, #0x30                       // digit index 0..9
    lsls r0, r0, #3                         // 8 bytes-worth... see note below: glyphs are 7 bytes but kept
    b .dg_hex_index                         //   4-byte-aligned (8 apart) so this is a plain shift, not a multiply
.dg_try_AF:
    cmp r0, #0x41                           // 'A'
    blt .dg_space
    cmp r0, #0x43                           // 'C'
    bgt .dg_try_F
    ldr r1, =glyph_A
    sub r0, r0, #0x41                       // 0=A, 1=B, 2=C
    lsls r0, r0, #3
    b .dg_hex_index
.dg_try_F:
    cmp r0, #0x46                           // 'F'
    bne .dg_try_colon
    ldr r10, =glyph_F
    b .dg_have_glyph
.dg_hex_index:
    add r10, r1, r0
    b .dg_have_glyph
.dg_try_colon:
    cmp r0, #0x3A                           // ':'
    bne .dg_space
    ldr r10, =glyph_COLON
    b .dg_have_glyph
.dg_space:
    ldr r10, =glyph_SP                      // space, or anything else not in this small set: blank
.dg_have_glyph:
    movs r5, #0                             // font row 0..6
.dg_row_loop:
    cmp r5, #GLYPH_H
    bge .dg_done
    ldrb r4, [r10, r5]                      // this row's 5-bit pattern, bit 4 = leftmost column

    // r6 = framebuffer address of logical (x0, y0 + row*SCALE), measured *backward* from FB_BOTTOM_RIGHT - see
    // the FB_BOTTOM_RIGHT comment above: this panel scans from the opposite corner, so what reads correctly on
    // screen is addressed as an offset from the far end, not forward from FB_BASE.
    ldr r6, =TEXT_SCALE
    mul r6, r5, r6
    add r6, r6, r9
    ldr r1, =FB_PITCH
    mul r6, r6, r1
    ldr r0, =FB_BOTTOM_RIGHT
    sub r6, r0, r6
    lsls r0, r8, #1
    sub r6, r6, r0

    movs r1, #0                             // scale_y: which of this row's TEXT_SCALE identical scanlines
.dg_scaley_loop:
    cmp r1, #TEXT_SCALE
    bge .dg_scaley_done
    mov r2, r6                              // r2 = running pixel pointer for this one scanline
    mov r12, r4
    lsls r12, r12, #27                      // bit 4 (leftmost pixel) of the 5-bit pattern -> bit 31, testable via N
    movs r11, #GLYPH_W                      // column counter, GLYPH_W downto 1
.dg_col_loop:
    tst r12, r12
    bpl .dg_col_skip                        // N clear: this font pixel is 0 - background (already filled) shows through
    movs r0, #TEXT_SCALE
.dg_px_loop:
    strh r3, [r2]
    subs r2, r2, #2                         // "rightward" in logical columns = backward in physical address (flip)
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
    sub r6, r6, r0                          // next of this row's TEXT_SCALE identical scanlines (also backward)
    adds r1, r1, #1
    b .dg_scaley_loop
.dg_scaley_done:
    adds r5, r5, #1
    b .dg_row_loop
.dg_done:
    bx lr

/* hex_line(r0 = 32-bit value, r1 = label character, r2 = destination buffer) -> writes "L:HHHHHHHH\0" (11
 * bytes) at [r2], most-significant nibble first. Leaf function, uses only r0-r3 (all free-scratch registers
 * throughout this file), so it needs no push/pop of its own. */
.thumb_func
hex_line:
    strb r1, [r2]
    adds r2, r2, #1
    movs r3, #0x3A                          // ':'
    strb r3, [r2]
    adds r2, r2, #1
    movs r1, #8                             // 8 nibbles in a 32-bit value
.hl_loop:
    lsrs r3, r0, #28                        // top nibble (bits 31:28)
    lsls r0, r0, #4                         // shift the rest up for the next iteration
    cmp r3, #10
    blt .hl_digit
    adds r3, r3, #(0x41 - 10)               // 'A' + (nibble - 10)
    b .hl_store
.hl_digit:
    adds r3, r3, #0x30                      // '0' + nibble
.hl_store:
    strb r3, [r2]
    adds r2, r2, #1
    subs r1, r1, #1
    bne .hl_loop
    movs r3, #0
    strb r3, [r2]                           // nul-terminate
    bx lr

/* ==========================================================================
 *  UART2: mirrors this file's on-screen diagnostics out over the TJC serial link
 * ========================================================================== */

/* uart_init: GPIO pinmux (port J pins 6/7, AF2, no pulls) + baud/format - see UART2_* equs' own comment for
 * sources. Leaf function (no nested `bl`), r0-r3 scratch only, matching hex_line's convention above. */
.thumb_func
uart_init:
    rmw (SYS_BASE + SYS_IOMODE9), UART2_PINMODE_MASK, UART2_PINMODE_AF
    rmw (SYS_BASE + SYS_IOAFR18), UART2_AFR_MASK, UART2_AFR_VAL
    rmw (SYS_BASE + SYS_IOPULLUP4),   UART2_PULL_MASK, 0
    rmw (SYS_BASE + SYS_IOPULLDOWN4), UART2_PULL_MASK, 0

    ldr r0, =UART2_IE
    movs r1, #0
    str r1, [r0]
    ldr r0, =UART2_TC
    ldr r1, =UART2_TC_VAL
    str r1, [r0]

    ldr r0, =UART2_C3
    ldr r1, [r0]
    movs r2, #4
    bics r1, r1, r2                         // bic/bics: Thumb-16 only has the register form, no immediate - use
    movs r2, #3                             //   a scratch register for the small constant instead
    orrs r1, r1, r2
    movs r2, #8
    bics r1, r1, r2
    str r1, [r0]

    ldr r0, =UART2_C2
    ldr r1, [r0]
    movs r2, #7
    orrs r1, r1, r2
    str r1, [r0]

    ldr r0, =UART2_IS
    ldr r1, =0xFFFFFFFF
    str r1, [r0]                            // clear pending flags (not using interrupts, harmless either way)
    ldr r0, =UART2_LS
    movs r1, #0
    str r1, [r0]
    bx lr

/* uart_putc(r0 = byte): polls UART2_TH's TX FIFO fill level, same as uart_write_byte's own wait, then writes
 * UART2_DR. Leaf function. */
.thumb_func
uart_putc:
    mov r3, r0                              // byte, kept out of r0-r2 while polling
.uart_tx_wait:
    ldr r0, =UART2_TH
    ldr r1, [r0]
    ldr r2, =UART2_TXFIFO_MASK
    ands r1, r1, r2
    ldr r2, =UART2_TXFIFO_FULL
    cmp r1, r2
    bhs .uart_tx_wait
    ldr r0, =UART2_DR
    strb r3, [r0]
    bx lr

/* uart_puts(r0 = nul-terminated string pointer): walks the string, calls uart_putc per character. */
.thumb_func
uart_puts:
    push {r4, lr}
    mov r4, r0
.uart_puts_loop:
    ldrb r0, [r4]
    cmp r0, #0
    beq .uart_puts_done
    bl uart_putc
    adds r4, r4, #1
    b .uart_puts_loop
.uart_puts_done:
    pop {r4, lr}                             // m2o: restore LR, not just pc: the loop's bl uart_putc leaves
                                              //   LR at that bl's return address, so a caller whose tail is a bare
                                              //   `bl uart_puts` + `bx lr` (the m2l-m2n 'death in the gap' class)
                                              //   gets the original LR back
    bx lr

// uart_dump_buf is defined up near entry's ID-register readout (its first use): unlike a `bl` to
// a label, a macro must be *defined* before any use, even a nested one inside another macro's body.

/* ==========================================================================
 *  Loader patch (two sites) + entry_trampoline: the 2nd melody and the final hand-off
 * --------------------------------------------------------------------------
 * The stage-0 loader runs our SD image through ldr_call(a1) (IDB 0x200015a4): it copies the first
 * 0x800 bytes a2->a1, sets VTOR = a1 & ~0x7F, then BL.W's ldr_exec_(a1) (IDB 0x20001de0) - its only
 * caller. ldr_exec_ (bytes verified in the IDB):
 *
 *   1de0  PUSH {R4-R6,LR}      16-byte frame at 0x20000648 (MSP; never moves after)
 *   1de2  MOV  R4, R0          r4 = a1 (0x80000 on the SD pass; 0 on the stock pass)
 *   1de4  MOVS R5, #0
 *   1de6  LDR  R5, [R4,#4]     r5 = [a1+4] = the reset-vector word = the real jump target
 *   1de8  LDR  R0, =ldr_last_dst  (global at 0x20000010)
 *   1dea  STR  R5, [R0]
 *   1dec  LDR  R0, [R4]        r0 = [a1] = the image's SP word
 *   1dee  BL   wrmsr           (0x1dd8: MSR.W MSP, R0; BX LR)
 *   1df2  BL   ldr_smth        (0x1528: clears 0x200 words of CPUCTL+0xC)
 *   1df6  LDR  R0, =ldr_last_dst   <-- SITE2 window (0x1df6..0x1dfd, 8 bytes)
 *   1df8  LDR  R0, [R0]
 *   1dfa  BLX  R0             jumps the target; r0 still holds that word at entry
 *   1dfc  MOVS R0, #0         (only reached if the target RETURNS)
 *   1dfe  POP  {R4-R6,PC}
 *
 * Everything ldr_exec_ uses is re-read from memory each call, so running it twice with the same a1
 * is idempotent. ldr_main calls ldr_call exactly twice: BL @ 0x2fda (ret 0x2fde, a1 = R5 = 0x80000,
 * the SD pass) and BL @ 0x302a (ret 0x302e, a1 = R4 = 0, the stock pass - IDB-verified: r4 = 0 in
 * ldr_main's prologue, never written). On the stock pass [a1+4] = [0+4] = the ROM reset vector
 * 0x349, so ldr_last_dst = 0x349 and the original 0x1dfa blx re-runs the ROM's normal boot (loads
 * the stock app); the PUSH/POP epilogue restores R4-R8 as a normal return would.
 *
 * ldr_call's original tail (the bytes our 24-byte SITE1 window 0x15c4..0x15db overwrites):
 *
 *   15c2  STR  R5, [R7]
 *   15c4  BIC.W R0, R4, #0x7F    the original VTOR write (literal at 0x15d8)
 *   15c8  LDR   R1, =SCB_VTOR
 *   15ca  STR   R0, [R1]
 *   15cc  MOV  R0, R4
 *   15ce  BL.W ldr_exec_        4 bytes -> returns to 0x15d2
 *   15d2  POP.W {R4-R8,PC}
 *   15d6  NOP
 *   15d8  <literal 0xE000ED08>
 *
 * Since site1 kills that VTOR write, entry_trampoline restores it (a1 & ~0x7F) on both paths.
 *
 * The 32-byte patch blob (build.py splices the two assembled halves from stage1/patch1.S / patch2.S
 * before packing) is installed by install_entry_hook during the cold pass:
 *   site1 (24 B @ 0x15c4): 7 x NOP (kills the original VTOR write and the 4-byte original BL.W),
 *     then at 0x15d2 (where the original BL.W returns): mov r0, r4; ldr r1, [pc,#0]; blx r1, with the
 *     pool literal at 0x15d8 = 0x20001DE1 (ldr_exec_, Thumb) reusing the original SCB->VTOR pool slot
 *     (a pool load, not the old mov/lsl/add, which built only the 16-bit 0x1DE1 and dropped the
 *     0x2000 word). This re-runs ldr_exec_ (now detoured by site2); the blx return is never taken -
 *     the trampoline returns to ldr_main.
 *   site2 (8 B @ 0x1df6): mov r0, #hi(TRAMP); lsl r0, #12; add r0, #lo(TRAMP); blx r0 (patch2.S) -
 *     all 16-bit (this GAS builds no 12-bit 16-bit ADD imm, so lo = TRAMP & 0xFFF must be <= 0xFF,
 *     which the .align 12 below and build.py's range assert guarantee; hi fits an 8-bit mov for
 *     TRAMP < 0x1000000). Redirects EVERY ldr_exec_ blx (the original 0x1dfa) into the in-image
 *     entry_trampoline. The 0x1e00 literal (0x20000010) stays intact - 0x1de8 still references it.
 *   I-cache reset (in install_entry_hook, right after the 32-byte write): this SoC's I-cache is an
 *     MMIO block (CCR/SR @ 0xE0042100/4, CPU CACHECTR @ 0xE0042024 - the vendor "CMSDK" cache), not
 *     a CP15 MCR, with NO invalidate op (HAL_ICACHE_Invalid is a no-op). The 1st ldr_exec_ already
 *     cached the ORIGINAL site1/site2 lines, so install_entry_hook resets the I-cache with the
 *     vendor's only idiom (HAL_ICACHE_Enable: bypass off, enable off->on, status poll) and restores
 *     the saved CCR/CACHECTR. The D-cache is write-through (HAL_DCACHE_Flush no-op), so the stores
 *     reached SRAM. Without this, every later ldr_exec_ re-fetches the cached originals and the
 *     trampoline is never entered (the m2c symptom). The cold pass probes the ROM's cache state
 *     first ('I:xxxx' = I-cache SR, 'B:xxxx' = CACHECTR over UART).
 *
 * The trampoline (no size limit - it lives in this image) reads ldr_exec_'s fresh frame at the
 * absolute LDR_EXEC_FRAME address (never via [sp] - set_msp moved MSP to the target image's SP word
 * before the detour: 0x20000648 on the SD pass, the stock app's 0x800000 on the stock pass):
 * [frame+0] = r4 = a1, [frame+4] = r5 = [a1+4].
 *   a1 == 0x80000 (SD pass): prints T SD, then `bl entry` (the known label - NOT [a1+4], which is
 *     this image's own reset vector and the cold pass clobbered: blx of that clobbered word fetched
 *     in ARM mode -> LOCKUP; bl by label is immune). entry sees BOOT_FLAG == DONE and bails
 *     immediately (no panel work, no chime, no print); the epilogue (add sp,#16; pop {r4-r8,lr};
 *     bx lr) unwinds both frames back to ldr_main (0x2fde after the one-off call, 0x302e in the
 *     slot loop).
 *   a1 == 0 (stock pass): the final hand-off of the boot. Prints M2 IN + M:HOOK_DONE; if
 *     HOOK_DONE == 0x484F4F44 (a completed cold pass this power-on) prints M2 OK, plays melody2
 *     exactly once, and clears HOOK_DONE. Sets VTOR = a1 & ~0x7f (=0 on stock), then blx
 *     ldr_last_dst (0x20000010) - ldr_exec_'s 1de6/1dea copy of [a1+4] = [0+4] = the ROM reset
 *     vector 0x349, the very word the original 0x1dfa blx'd: the ROM re-boots and loads the stock
 *     app normally (one-way; all push/pop on this path is net-zero on the stock's own SP word).
 *     melody2 only plays inside this (a1!=0x80000, HOOK_DONE) window, so no stray chimes: SD
 *     passes are a1==0x80000 (no chime), and HOOK_DONE is consumed by the stock call that ends
 *     the cold boot, so a later warm boot finds it cleared.
 *
 * COLD (a1 = 0x80000, first boot after power-on; loader unpatched): the original ldr_exec_ blx's
 * entry; entry runs the whole pass (BOOT_FLAG, UART, install_entry_hook, IWDG, bring-up, 1st
 * melody, 3 s hold, HOOK_DONE) and exits with `bx r1` straight into entry_trampoline - NOT `bx lr`
 * (the 0x1dfc resume point is now site2's blx, and r0 would be HOOK_DONE_ADDR). The trampoline
 * prints T SD, bl's entry (warm bail), and the epilogue unwinds to ldr_main -> slot loop ->
 * ldr_call(a1 = the decoded flash target) via the patched site1 (NOPs fall through, re-running
 * ldr_exec_) -> set_msp to the stock's SP word -> site2's blx -> trampoline stock path -> M2 IN /
 * M: / (M2 OK + melody2) -> VTOR -> blx ldr_last_dst = the stock app.
 * WARM (a1 = 0x80000, BOOT_FLAG already DONE - an IWDG/relay reset; the ROM re-copied the loader,
 * so the patch is gone and the trampoline is never entered): entry bails immediately (bx lr to the
 * original 0x1dfc -> 0x1dfe POP -> 0x15d2 chain); no panel work, no chime; the stock pass runs
 * through the original bytes.
 * POWER-ON WITHOUT SD / BAD IMAGE: ldr_main never runs our image; the loader stays unpatched and
 * boots stock through the original bytes - untouched.
 *
 * Both patch sites live in the loader's SRAM copy (flash is never written) and vanish on power-off;
 * they are only FETCHED again on later ldr_call/ldr_exec_ invocations, so writing them
 * mid-cold-pass (while the CPU sits in this image) is safe. The trampoline is an absolute blx
 * target on purpose: the image at 0x80000+ and the loader at 0x20000000+ are ~31.5 MB apart, far
 * outside BL/B.W range; only a pointer crosses that gap.
 */
.equ LDR_CALL_PATCH_SITE, 0x200015c4   // site1: 24-byte window inside ldr_call (0x200015c4..0x200015db)
.equ LDR_EXEC_BLX_SITE, 0x20001df6     // site2: 8-byte window inside ldr_exec_ (0x20001df6..0x20001dfd)
.equ LDR_EXEC_ADDR, 0x20001de0         // (referenced by site1's tail; loader code is Thumb)
.equ LDR_LAST_DST, 0x20000010        // ldr_exec_'s global (this->data4, this=0x20000000): the 1de6/1dea copy of [a1+4], the word the original 0x1dfa blx'd
.equ LDR_EXEC_FRAME, 0x20000648        // ldr_exec_'s saved frame base: [frame]=R4=a1, [frame+4]=R5=[a1+4].
                                        // Both ldr_call sites (SD at 0x2FDA, stock at 0x302A) run at the
                                        // same ldr_main SP, and ldr_call/ldr_exec_ push 24 B + 16 B, so
                                        // the frame base at the site2 BLX is 0x20000648 on every pass
                                        // (this is also why our image word 0 must be 0x20000648).
                                        // set_msp moves MSP to the target image's word 0 before the blx,
                                        // so the frame can only be read by this absolute address - never [sp].
.equ SCB_VTOR, 0xE000ED08
/* MMIO cache block (vendor "CMSDK" cache - NOT a CP15 MCR; the loader contains zero MCRs):
 * 0xE0042100 = I-cache CCR (bit 0 = enable), 0xE0042104 = I-cache SR (bits 1:0: 0=off,
 * 1=enabling, 2=on, 3=disabling), 0xE0042024 = CPU CACHECTR (bit 0 = I-cache bypass,
 * bit 1 = D-cache bypass). Addresses per the BSP's soc_gm6721x.h / gm_ll_cache.h
 * (CPU_BASE = 0xE0042020, CMSDK_ICACHE = 0xE0042000+0x100). */
.equ ICACHE_CCR, 0xE0042100
.equ ICACHE_SR, 0xE0042104
.equ CPU_CACHECTR, 0xE0042024

/* --------------------------------------------------------------------------
 *  melody_play: self-contained TIM5 note player, shared by entry's 1st melody and
 *  entry_trampoline's 2nd
 * --------------------------------------------------------------------------
 * r0 = pointer to a note table (see the `note`/`rest` macros). Clobbers r0-r5, preserves lr,
 * leaves the stack balanced (pushes r4/r5 itself), and stops the timer when done (the pin stays
 * configured as TIM5_CH4; with the counter stopped the output stops toggling). Self-contained on
 * purpose: it stops the timer, zeroes the counter and re-sets the tick rate to TIM_PSC_VAL (2 MHz)
 * itself, so note durations stay correct no matter what the caller left behind. The buzzer pin's
 * PWM mode (CCMR1/2 = 0x7070, CCER = 0x3333) must already be set - entry's buzzer section does
 * that once and nothing between ever touches it.
 * Per note: stop and zero the counter first (with a smaller new ARR a counter above it would run
 * on to 0xFFFF before wrapping = tens of ms of silence), then ARR = period, CCR4 = duty (0 for a
 * rest), start, and poll the counter counting its wrap-arounds (one per PWM period) so the length
 * follows the timer clock, not the (slow, SDRAM-bound) instruction rate.
 */
melody_play:
    push {r4, r5}
    mov r5, r0                                 // r5 = pointer into the table
    ldr r1, =TIM5_BASE
    movs r2, #0
    str r2, [r1, #TIM_CR1]                     // stop the timer
    str r2, [r1, #TIM_CNT]                     // zero the counter
    ldr r2, =TIM_PSC_VAL
    str r2, [r1, #TIM_PSC]                     // 2 MHz tick (the note durations assume it)
.mp_next_note:
    ldr r3, [r5]                               // r3 = periods still to wait (0 = end of the melody)
    cmp r3, #0
    beq .mp_done
    movs r2, #0
    str r2, [r1, #TIM_CR1]                     // stop and zero before the next note
    str r2, [r1, #TIM_CNT]
    ldr r2, [r5, #4]
    str r2, [r1, #TIM_ARR]                     // period of the note
    ldr r2, [r5, #8]
    str r2, [r1, #TIM_CCR4]                    // duty of channel 4 = the buzzer (0 for a rest)
    add r5, r5, #12                            // next entry
    movs r2, #1
    str r2, [r1, #TIM_CR1]                     // go
    ldr r4, =WAIT_TIMEOUT                      // safety: bounded loop if the counter never moves
    movs r0, #0                                // previous counter value
.mp_wait:
    ldr r2, [r1, #TIM_CNT]
    cmp r2, r0
    bhs .mp_no_wrap                            // counter did not go down: same period
    sub r3, r3, #1                             // counter wrapped: one more period done
.mp_no_wrap:
    mov r0, r2                                 // remember the counter
    sub r4, r4, #1                             // sub (not subs): this Thumb-16 assembler has no flag-immediate
    cmp r4, #0
    beq .mp_note_done                          // safety timeout
    cmp r3, #0
    bne .mp_wait
.mp_note_done:
    b .mp_next_note
.mp_done:
    movs r2, #0
    str r2, [r1, #TIM_CR1]                     // stop; the output stops toggling
    pop {r4, r5}
    bx lr

/* buzzer_rearm: standalone re-init of the buzzer pin and TIM5 - the same register recipe as entry's
 * inline buzzer block, factored into a function so entry_trampoline can re-assert it. ldr_init_app
 * (0x200031B0) runs between the two melodies and reprograms IO_MOD/AF_SEL/IO_PU-PD registers; if any
 * of that touches PI3's mux (or the GPIO/TIM5 clock enables), the 2nd melody's PWM never reaches the
 * pin without this. Leaf: clobbers r0-r3 only, returns via bx lr. */
.thumb_func
buzzer_rearm:
    // ---- enable the GPIO and TIM5 clocks (a peripheral with its clock off ignores writes) ----
    rmw (SYS_BASE + SYS_ENCLK0), 0, ENCLK0_GPIO
    rmw (SYS_BASE + SYS_ENCLK2), 0, ENCLK2_TIM5

    // ---- pulse the TIM5 software reset (active low): known state ----
    rmw (SYS_BASE + SYS_IPSWRST2), IPSWRST2_TIM5, 0
    rmw (SYS_BASE + SYS_IPSWRST2), 0, IPSWRST2_TIM5

    // ---- pin PI3: alternate function 5 (TIM5_CH4), no pulls, push-pull ----
    rmw (SYS_BASE + SYS_IOMODE8), BUZZER_IOMODE_MASK, BUZZER_IOMODE_AF
    rmw (SYS_BASE + SYS_IOAFR16), BUZZER_AFR_MASK, BUZZER_AFR_TIM5
    rmw (SYS_BASE + SYS_IOPULLUP4), BUZZER_PIN_MASK, 0
    rmw (SYS_BASE + SYS_IOPULLDOWN4), BUZZER_PIN_MASK, 0
    rmw (SYS_BASE + SYS_IOODC4), BUZZER_PIN_MASK, 0

    ldr r0, =GPIOI_OMCR
    ldr r2, =BUZZER_PIN_MASK
    str r2, [r0]

    // ---- TIM5: PWM on CH4 (the note-specific ARR / CCR4 come from melody_play) ----
    ldr r1, =TIM5_BASE
    movs r2, #0
    str r2, [r1, #TIM_CR1]                     // stopped while configuring
    ldr r2, =TIM_PSC_VAL
    str r2, [r1, #TIM_PSC]                     // 2 MHz tick
    ldr r2, =0x7070
    str r2, [r1, #TIM_CCMR1]
    str r2, [r1, #TIM_CCMR2]
    ldr r2, =0x3333
    str r2, [r1, #TIM_CCER]
    bx lr

/* install_entry_hook: writes the 32-byte patch blob into the loader's SRAM - the 24-byte site1
 * window first, then the 8-byte site2 window (the blob is laid out in that order). Both sites are
 * only fetched again on later ldr_call/ldr_exec_ invocations, so writing them here (while the CPU
 * sits in this image) is safe. */
install_entry_hook:
    push {r4-r6, lr}
    ldr r4, =LDR_CALL_PATCH_SITE
    ldr r0, =patch_blob
    movs r1, #0
.ieh_site1:
    ldr r2, [r0, r1]
    str r2, [r4, r1]
    adds r1, r1, #4
    cmp r1, #24
    blo .ieh_site1
    ldr r4, =LDR_EXEC_BLX_SITE
    ldr r0, =patch_blob
    adds r0, r0, #24
    movs r1, #0
.ieh_site2:
    ldr r2, [r0, r1]
    str r2, [r4, r1]
    adds r1, r1, #4
    cmp r1, #8
    blo .ieh_site2
    // ---- I-cache reset: the stores above reached SRAM (the D-cache is write-through - the
    // vendor's HAL_DCACHE_Flush is a no-op), but the I-cache still holds the ORIGINAL site1/site2
    // lines fetched during the 1st ldr_exec_. This cache has no invalidate op (HAL_ICACHE_Invalid
    // is a no-op); the vendor's only reset idiom (HAL_ICACHE_Enable, used by reset.S) is
    // bypass-clear then disable->enable with a status wait. Mirror it, then restore the saved
    // CCR/CACHECTR so the stock firmware sees exactly the state the boot ROM left. Without this,
    // every later ldr_exec_ re-fetches the cached originals and the trampoline is never entered.
    ldr r4, =ICACHE_CCR
    ldr r5, =ICACHE_SR
    ldr r6, =CPU_CACHECTR
    ldr r0, [r6]                             // save CACHECTR (bypass bits)
    ldr r1, [r4]                             // save CCR (enable bit)
    bic r2, r0, #1                           // bypass off (as in HAL_ICACHE_Enable)
    str r2, [r6]
    movs r2, #0
    str r2, [r4]                             // I-cache off
    ldr r3, =0x40000
.ieh_ic_off:
    ldr r2, [r5]
    ands r2, r2, #3
    beq .ieh_ic_on                           // SR[1:0] == 0: disabled
    subs r3, r3, #1
    bne .ieh_ic_off
.ieh_ic_on:
    movs r2, #1
    str r2, [r4]                             // I-cache on (refills from SRAM on next fetch)
    ldr r3, =0x40000
.ieh_ic_on2:
    ldr r2, [r5]
    ands r2, r2, #3
    cmp r2, #2
    beq .ieh_ic_restore                      // SR[1:0] == 2: enabled
    subs r3, r3, #1
    bne .ieh_ic_on2
.ieh_ic_restore:
    str r0, [r6]                             // restore CACHECTR
    cmp r1, #1
    beq .ieh_ic_done                         // was on: the toggle left it on - done
    str r1, [r4]                             // was off: put it back off
    ldr r3, =0x40000
.ieh_ic_off3:
    ldr r2, [r5]
    ands r2, r2, #3
    beq .ieh_ic_done
    subs r3, r3, #1
    bne .ieh_ic_off3
.ieh_ic_done:
    dsb
    isb
    pop {r4-r6, pc}

.align 2
/* The 32-byte loader patch: site1 (24 B, assembled from stage1/patch1.S) then site2 (8 B, from
 * stage1/patch2.S). build.py's 2nd pass assembles both and splices the bytes in before packing;
 * the zeros here never ship. */
patch_blob:
    .space 32

/* entry_trampoline: what ldr_exec_'s patched blx (site2) jumps into instead of the reset-vector
 * word it would normally load. No registers are passed: set_msp already replaced MSP with the target
 * image's word 0 BEFORE the blx (0x20000648 on the SD pass, the app's 0x800000 on the stock pass), so
 * a1 is read from its absolute address LDR_EXEC_FRAME (0x80000 on the SD pass, 0 on the stock pass).
 * The stock jump blx's ldr_last_dst - ldr_exec_'s 1de6/1dea copy of [a1+4] = [0+4] = the ROM reset
 * vector 0x349, the very word the original 0x1dfa blx'd - never re-reading [a1+4] itself (the SD path
 * clobbers that word). Stack: the stock pass's MSP is the app's (every push net-zero; the blx is
 * one-way); the SD pass's MSP = 0x20000648 = ldr_exec_'s frame base, and the epilogue unwinds both
 * frames (add sp,#16 + pop {r4-r8,lr}) back to ldr_main.
 * .align 12 (0x1000) on purpose: site2 builds TRAMP as (hi << 12) + lo with 8-bit immediates only
 * (this GAS emits no 12-bit 16-bit ADD imm), so lo = TRAMP & 0xFFF must be <= 0xFF, which only
 * 0x1000-alignment guarantees (build.py asserts both bounds); .ltorg first, without it the alignment
 * padding pushes the pending literal pool out of 16-bit LDR range ("offset out of range").
 */
.ltorg
.align 12
.thumb_func
entry_trampoline:
    ldr r0, =LDR_EXEC_FRAME
    ldr r0, [r0]                             // r0 = a1 ([LDR_EXEC_FRAME]: 0x80000 on the SD pass, 0 on the
                                              // stock pass - ldr_main's R4, never written)
    ldr r1, [r0, #4]                         // r1 = [a1+4] = the target's reset vector word
    bic r3, r0, #0x7f                        // r3 = VTOR value (a1 & ~0x7f): restores the write that
                                              // site1's NOPs killed (0x80000 on SD, the target region on stock)
    cmp r0, #0
    bne .tm_sd                               // a1 != 0: the SD pass - no chime, just go
    // ---- stock pass: one blx away from the stock firmware ----
    push {r0, r3}                            // keep a1 (VTOR source) across the detour; net-zero
    iwdg_feed                                // extend the hang-guard window across the whole detour: the
                                              // chime below adds ~0.2 s (clobbers r0-r1, both saved)
    bl uart_init                             // ldr_init_app runs between the passes and reprograms the GPIO
                                              // registers: re-mux UART2 before trusting it (the SD pass must NOT do this)
    ldr r0, =m2_in_str
    bl uart_puts                             // "M2 IN": the stock pass actually reached the trampoline
    ldr r4, =HOOK_DONE_ADDR
    ldr r4, [r4]                             // r4 = HOOK_DONE as-is: the magic if the cold pass completed,
                                              // 0/stale otherwise (hex_line touches only r0-r3; uart_puts saves r4)
    mov r0, r4
    movs r1, #0x4D                           // 'M'
    ldr r2, =TEXT_BUF
    bl hex_line
    ldr r0, =TEXT_BUF
    bl uart_puts                             // "M:XXXXXXXX"
    ldr r5, =HOOK_DONE_MAGIC                 // 32-bit magic doesn't fit a Thumb cmp immediate
    cmp r4, r5
    bne .tm_no_chime                         // no completed cold pass on this power-on: no chime
    ldr r0, =m2_ok_str
    bl uart_puts
    bl buzzer_rearm                         // re-assert PI3/TIM5: ldr_init_app may have clobbered the mux
    ldr r0, =melody2
    bl melody_play                           // the 2nd melody: a short rising chime, "leaving stage1"
    ldr r0, =HOOK_DONE_ADDR
    movs r1, #0
    str r1, [r0]                             // consume HOOK_DONE: at most one chime per power-on
    pop {r0, r3}
    b .tm_common
.tm_no_chime:
    ldr r0, =m2_no_str
    bl uart_puts                             // diagnostic marker for the no-chime case too
    pop {r0, r3}
    b .tm_common
.tm_sd:
    // SD pass: only reachable after the patch is installed (an in-boot re-run of the SD slot after the
    // cold pass) - "T SD" proves the trampoline sits in the SD-pass chain. UART is still live from this
    // boot's cold pass: do NOT re-run uart_init here (m2h did; a re-init aborts the cold pass's
    // in-flight UART TX mid-word, corrupting the rest of the dump).
    push {r0, r3}                            // net-zero (popped below): the T SD print clobbers r0
    ldr r0, =t_sd_str
    bl uart_puts                             // "T SD"
    pop {r0, r3}
    bl entry                                 // NOT [a1+4]: m2h blx'd the image's reset-vector word and it
                                              // had been clobbered to 0xF00 -> ARM-mode fetch -> LOCKUP. The known
                                              // label is immune; entry sees BOOT_FLAG == DONE and bails immediately
                                              // (no panel work, no print: FAULT_WORD was cleared to 0 on this pass)
    b .tm_common
.tm_common:
    ldr r2, =SCB_VTOR
    str r3, [r2]                             // VTOR = 0x80000 (SD) or the target region (stock)
    iwdg_feed                                // a fresh ~10 s window: for the stock app itself (stock), for
                                              // the rest of the chain (SD)
    ldr r0, =LDR_EXEC_FRAME
    ldr r0, [r0]                             // reload a1 (iwdg_feed clobbers r0)
    cmp r0, #0
    bne .tm_sd_exit
    ldr r0, =LDR_LAST_DST
    ldr r0, [r0]                             // r0 = ldr_last_dst = [a1+4] (ldr_exec_'s 1de6/1dea copy)
    blx r0                                   // one-way into the stock app (it never returns)
.tm_sd_exit:
    movs r0, #0                              // ldr_call's return status (the original 1dfc MOVS R0,#0 we replaced)
    add sp, #16                              // skip ldr_exec_'s 16-byte frame (SP = 0x20000648 = the frame base)
    pop {r4-r8, lr}                          // restore ldr_call's 24-byte frame
    bx lr                                    // -> ldr_main (0x2fde after the one-off, 0x302e in the slot loop)
    .ltorg

/* fault_trap: the HardFault handler (vector slot 3). On entry the HW has already pushed the
 * exception frame (R0-R3, R12, LR, PC, xPSR at [sp..sp+28]) onto the faulting stack, so r13 sits 32
 * bytes BELOW the fault-time SP. This trap copies the raw frame to FAULT_FRAME and the latched
 * CFSR/HFSR/BFAR to FAULT_STATUS (mandatory SCB registers on any M4), parks r13 in FAULT_WORD (it
 * range-gates the warm-bail print), and spins until the IWDG (armed on the cold pass) resets the
 * chip. All three blocks sit outside the loader's working set, so the reset and the ROM re-copy
 * leave them intact: the next warm pass prints F:/P:/L:/0:/1:/X:/C:/H:/B: before bailing (SP
 * localizes the live frame, PC names the exact faulting instruction, CFSR/BFAR the fault type and
 * address). Runs on the faulting stack; only plain-SRAM ldr/str plus the three SCB reads below.
 */
.thumb_func
fault_trap:
    ldr r0, =FAULT_WORD
    str r13, [r0]
    ldr r0, =FAULT_FRAME
    ldr r1, [sp, #0]
    str r1, [r0, #0]
    ldr r1, [sp, #4]
    str r1, [r0, #4]
    ldr r1, [sp, #8]
    str r1, [r0, #8]
    ldr r1, [sp, #12]
    str r1, [r0, #12]
    ldr r1, [sp, #16]
    str r1, [r0, #16]
    ldr r1, [sp, #20]
    str r1, [r0, #20]
    ldr r1, [sp, #24]
    str r1, [r0, #24]
    ldr r1, [sp, #28]
    str r1, [r0, #28]
    ldr r0, =FAULT_STATUS
    ldr r1, =0xE000ED24
    ldr r2, [r1, #0]
    str r2, [r0, #0]
    ldr r1, =0xE000ED28
    ldr r2, [r1, #0]
    str r2, [r0, #4]
    ldr r1, =0xE000ED34
    ldr r2, [r1, #0]
    str r2, [r0, #8]
    b fault_trap
    .ltorg

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

/* Hex digits and a colon, for printing register values - added so identifier readouts (CID, CPUID, ...) can
 * be drawn with the same font/blitter as the letters above. glyph_0..glyph_9 and glyph_A..glyph_C are each
 * padded to 8 bytes (7 real rows + 1 filler) so draw_glyph's dispatcher can index them with a plain `lsls #3`
 * instead of a multiply by 7. glyph_F and glyph_COLON stand alone (not part of either indexed run). */
.align 2
glyph_0: .byte 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E, 0x00
glyph_1: .byte 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E, 0x00
glyph_2: .byte 0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F, 0x00
glyph_3: .byte 0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E, 0x00
glyph_4: .byte 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02, 0x00
glyph_5: .byte 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E, 0x00
glyph_6: .byte 0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E, 0x00
glyph_7: .byte 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08, 0x00
glyph_8: .byte 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E, 0x00
glyph_9: .byte 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C, 0x00
glyph_A: .byte 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11, 0x00
glyph_B: .byte 0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E, 0x00
glyph_C: .byte 0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E, 0x00
glyph_F: .byte 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10
glyph_COLON: .byte 0x00, 0x04, 0x00, 0x00, 0x04, 0x00, 0x00
.align 2
text_string: .asciz "HELLO WORLD"
uart_banner: .asciz "\r\n--- Nanachi stage1 probe pass ---\r\n"
m2_ok_str: .asciz "\r\nM2 OK\r\n"             // trampoline marker: stock path + HOOK_DONE set (chime follows)
m2_no_str: .asciz "\r\nM2 NO\r\n"             // trampoline marker: stock path, HOOK_DONE not set (no chime)
m2_in_str: .asciz "\r\nM2 IN\r\n"             // trampoline marker: stock branch entered, before the HOOK_DONE check
t_sd_str:  .asciz "\r\nT SD\r\n"              // trampoline marker: SD pass ran through the patched chain
pv_ok_str: .asciz "\r\nPATCH OK\r\n"          // cold pass: 32-byte patch read back from the loader SRAM == patch_blob
pv_bad_str: .asciz "\r\nPATCH BAD\r\n"        // cold pass: patch read-back mismatch (followed by 'p:'/'q:' hex of site1/site2 word 0)

/* "ta-daa": a short note, a gap, then a longer one a fifth higher (C6 -> G6; a piezo is loudest around 2-4 kHz, so
 * the notes are kept high). Edit the table to change the tune; keep the total image below 0x1C8 bytes. */
.align 2
melody:
    note 1047, 110        // "ta"   C6
    rest 40
    note 1568, 520        // "daa"  G6
    .word 0               // end of the melody

/* Diagnostic alternate melody: three short, identical, low beeps - unmistakably different from "ta-daa" by
 * ear, so PLLSAI's CMUST_PLLSAI_STABLE bit either showed up (normal tune) or PLLSAI_WAIT_TIMEOUT was hit
 * instead (this one), with nothing to read over UART. See the r6 flag set around .pllsai_wait, above. */
melody_pllsai_timeout:
    note 440, 80          // A4, low and short
    rest 80
    note 440, 80
    rest 80
    note 440, 80
    .word 0

/* 2nd melody: played by entry_trampoline (via the loader patch) on the final stock-firmware call of a
 * completed cold boot, HOOK_DONE-gated - a short rising chime, unmistakably different from "ta-daa". */
melody2:
    note 1760, 60         // A6
    rest 40
    note 2637, 120        // E7
    .word 0
