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
.equ SYS_IOMODE9,     0x2E8                @ IOMODE[9] (IO_MOD_REG10) = port J, following the same +4-bytes-per-
                                           @   port pattern as IOMODE4..8 above
.equ SYS_IOAFR18,     0x338                @ IOAFR for port J pins 0..7 (same +4-per-register, +8-per-port pattern
                                           @   as IOAFR16 above: port I = 0x330/0x334, port J = 0x338/0x33C)

.equ SYS_IPSWRST1,    0x70                 @ IPSWRST[1] (IP_RST_CTRL1): bit 19 = VOUT (SYS_IP_SW_RESET_VOUT_POS
                                           @   in the BSP), bit 1 = GPIO
.equ SYS_IOMODE4,     0x2D4                @ IOMODE[4] (IO_MOD_REG5) = port E
.equ SYS_IOMODE5,     0x2D8                @ IOMODE[5] (IO_MOD_REG6) = port F
.equ SYS_IOAFR9,      0x310                @ IOAFR[9]  (AF_SEL_REG9)  = port E pins 0..7
.equ SYS_IOAFR10,     0x314                @ IOAFR[10] (AF_SEL_REG10) = port E pins 8..15
.equ SYS_IOAFR11,     0x318                @ IOAFR[11] (AF_SEL_REG11) = port F pins 0..7
.equ SYS_IOPU_EF,     0x270                @ IOPULLUP pair register for ports E (bits 0..15) and F (bits 16..31)
.equ SYS_IOPD_EF,     0x288                @ IOPULLDOWN, same pairing as IOPU_EF

/* ---- reset-survival flag (internal SRAM, not SDRAM - see entry's own comment) ----
 * The SD-card stage-0 loader (ldr_main/ldr_exec) is confirmed (IDB segment map) to live in a 64 KiB internal
 * SRAM segment, 0x20000000..0x2000FFFF - separate from the SDRAM window (0x100000..0x800000) stage1 itself
 * loads/draws into. Every symbol the IDB names in that SRAM segment (the loader's own code, strings, and its
 * stack at 0x20000680, matching the vector table's MSP) sits below ~0x20003970 - the top ~49 KiB of the segment
 * has no named reference anywhere, and `ldr_main`'s own decompile has no SRAM-zeroing loop, so a flag planted
 * at the very top of the segment should survive both a normal run and a loader re-run completely undisturbed.
 * Plain 2-state flag: unset (first boot since power-on - run once) or DONE (skip straight to stock firmware on
 * every pass after). This briefly grew a 3rd state for a one-shot diagnostic (read back g_scr_info.field_16,
 * the touch-controller-type selector, by letting stock firmware boot once under a long unfed IWDG before
 * re-entering) - that confirmed GT911 (type 2) and real touch detection now works end to end on a single boot,
 * so the extra state (and the double-reboot it required) was removed; see git history / entry's own comment if
 * that diagnostic is ever needed again for a different unit. BOOT_FLAG_DONE's value is an arbitrary 32-bit
 * constant, chosen only to not collide with whatever uninitialized SRAM happens to read as after a real power-on
 * (which WOULD actually clear/randomize this, unlike a warm/watchdog reset). */
.equ BOOT_FLAG_ADDR,  0x2000FFFC
.equ BOOT_FLAG_DONE,  0xB00710AD

/* ---- hardware watchdog (IWDG) ----
 * Confirmed via the IDB: IWDG_KR/PR/RLR at 0x40008000/4/8 (plain STM32-style IWDG), and the stock firmware's own
 * `restart` function (IDB 0x108E8, the firmware's generic "reboot the board" routine) uses exactly this register
 * sequence and these magic values - copied here, not guessed. `restart` never writes KR=0xCCCC (start), which
 * suggests the IWDG may already be running by the time any of this code executes (likely armed by the boot ROM
 * - an IDB xref to IWDG_KR from a ROM-labelled region is consistent with this, though not fully traced); writing
 * 0xCCCC here anyway is harmless (restarting an already-running IWDG) and makes this correct even if nothing
 * upstream has armed it. Clock source is a fixed internal ~32 kHz oscillator (BSP: HAL_IWDG_CLKSRC), independent
 * of every other clock this file configures - the whole point of an "independent" watchdog is that it keeps
 * running even if the main clock tree is misconfigured or the CPU is stuck. */
.equ IWDG_BASE,         0x40008000
.equ IWDG_KR,           (IWDG_BASE + 0x00)
.equ IWDG_PR,           (IWDG_BASE + 0x04)
.equ IWDG_RLR,          (IWDG_BASE + 0x08)
.equ IWDG_KEY_UNLOCK,   0x5555              @ unlocks PR/RLR for writing
.equ IWDG_KEY_START,    0xCCCC              @ (re)starts the countdown
.equ IWDG_KEY_FEED,     0xAAAA              @ reloads the counter from RLR - "feed"/"pet" the watchdog
.equ IWDG_PR_VAL,       6                   @ prescaler = /256 (STM32-style PR encoding: 6 and 7 both mean /256)
.equ IWDG_RLR_VAL,      1250                @ (1250+1)*256/32000 Hz ~= 10.0 s - a last-resort timeout, not a tight one
.equ SYS_PWR_MODE_REG,  0x18                @ bit 12: backup-domain write unlock, needed only for PR/RLR writes,
                                           @   not for feeding - same bit `restart` sets/clears around its own write
.equ PWR_BKP_UNLOCK_BIT, (1 << 12)

.macro iwdg_feed
    ldr r0, =IWDG_KR
    ldr r1, =IWDG_KEY_FEED
    str r1, [r0]
.endm

/* ---- touch controller (GT911-style, "type 2" in the firmware's own touch_init/touch_int_ctrl, IDB 0x1FCC8
 * and 0x2ABD0): RST = PF6, INT = PF5. Register sequence copied from those two functions, not guessed.
 * CORRECTED after a hardware test: watching the raw INT (PF5) level alone was not enough - it read low
 * immediately, with no touch, right after the reset sequence (most likely the chip's own post-reset/self-test
 * period, or needing the full handshake below before it means anything). The real firmware's own
 * `touch_gt911_read` (IDB 0x105B0) explains why: even *it* only treats a low INT as a hint to go check, by
 * actually reading the GT911's status register (0x814E) over I2C and testing bit 7 (data-ready) - the INT
 * line by itself is not trusted. This file now does the same real I2C read (bit-banged on PB12/PB13, SCL/SDA
 * - register sequence from this firmware's own i2c_start/i2c_write_byte/i2c_read_byte/i2c_wait_ack/
 * i2c_send_ack/i2c_send_nack/i2c_stop, IDB 0x10B74/0x10AE0/0x10A3C/0x10C38/0x10934/0x109C8/0x10BD0), not just
 * the GPIO level - see the touch-hardware-i2c project memory for the wider protocol context. */
.equ GPIOF_BASE, 0x40015000
.equ GPIOF_OBSR, (GPIOF_BASE + 0x08)
.equ GPIOF_OMCR, (GPIOF_BASE + 0x10)
.equ GPIOF_IMCR, (GPIOF_BASE + 0x14)
.equ GPIOF_DR,   (GPIOF_BASE + 0x00)
.equ TOUCH_RST_PIN, 6
.equ TOUCH_INT_PIN, 5
.equ TOUCH_RST_IOMODE_MASK, (3 << (2 * TOUCH_RST_PIN))
.equ TOUCH_INT_IOMODE_MASK, (3 << (2 * TOUCH_INT_PIN))
.equ TOUCH_RST_PU_PD_BIT,   (1 << (16 + TOUCH_RST_PIN))    @ IOPU_EF/IOPD_EF: port F is the high half (bits 16..31)
.equ TOUCH_INT_PU_PD_BIT,   (1 << (16 + TOUCH_INT_PIN))
.equ TOUCH_RST_PIN_MASK,    (1 << TOUCH_RST_PIN)
.equ TOUCH_INT_PIN_MASK,    (1 << TOUCH_INT_PIN)
.equ TOUCH_RST_PIN_HI_MASK, (1 << (16 + TOUCH_RST_PIN))    @ OBSR high half = drive/release this pin HIGH
.equ TOUCH_INT_PIN_HI_MASK, (1 << (16 + TOUCH_INT_PIN))
@ CORRECTED after a hardware test showed the GT911 NACKing every single I2C transaction (bus reads as a floating
@ 0xFF, never a real ACK): re-decompiling the real firmware's `touch_init`/`touch_int_ctrl` (IDB 0x1FCC8/0x2ABD0)
@ found two real differences from what this file did before, not just "needs calibrating":
@  1. The RST-low/INT-low hold time is an exact, timer-measured 10 ms (`sub_26ACC(10)`, confirmed ms-based), not
@     a plain instruction-count busy-loop - this project already has one confirmed case (the buzzer) of such
@     loops running at wildly unpredictable real speed from SDRAM, so a bare iteration count here was a guess.
@  2. Critically: `touch_init` does NOT release INT back to input right after RST's rising edge - it leaves INT
@     driven low (as a GPIO output) indefinitely; the only place that ever calls `touch_int_ctrl(1)` (the
@     release-to-input branch) is a *different* function (`widget_event_process`), on first real use, long after
@     boot. This file used to switch INT to input immediately after releasing RST, which likely corrupts the
@     GT911's address-latch window (common for this controller family to need INT held at the select level for
@     some time after reset, not just during it) - this is very likely the actual cause of the all-NACK result.
@ Since this file still needs INT as an input eventually (to read real touches), it can't just leave it low
@ forever like the real firmware does - instead it holds INT low for an extra, generous margin after RST releases
@ (TOUCH_ADDR_LATCH_HOLD_MS - a guess at "long enough", not independently confirmed) before switching it to input.
@ Both delays are now measured with TIM5 as a free-running tick counter (see timer_delay_ticks below), not an
@ instruction-count loop - a temporary faster prescaler (TIM_DELAY_PSC_VAL, 500 kHz) is used only for these two
@ short delays, restored to the buzzer section's 2 MHz (TIM_PSC_VAL) before the later long touch-wait timeout.
.equ TIM_DELAY_PSC_VAL,         399        @ 200 MHz / 400 = 500 kHz tick (2 us/tick) - up to ~131 ms range,
                                           @   comfortably covering both delays below with real precision
.equ TOUCH_RESET_HOLD_MS,       10         @ the exact value touch_init itself uses (sub_26ACC(10))
.equ TOUCH_RESET_HOLD_TICKS,    (TOUCH_RESET_HOLD_MS * 500)         @ 500 kHz tick = 500 ticks/ms
.equ TOUCH_ADDR_LATCH_HOLD_MS,  100        @ generous margin after RST releases, INT still held low - see above
.equ TOUCH_ADDR_LATCH_HOLD_TICKS, (TOUCH_ADDR_LATCH_HOLD_MS * 500)

/* timer_delay_ticks ticks: busy-waits until TIM5's free-running counter has advanced by `ticks`, using plain
 * 16-bit wraparound-safe subtraction (works correctly across at most one wrap, true for both delays above - the
 * largest, 50000 ticks, is still under the 16-bit range). TIM5 must already be running (CR1 bit 0 set) with
 * whatever prescaler the caller wants ticks measured in - see TIM_DELAY_PSC_VAL above for this file's two uses.
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
 * Added so this file's diagnostics can go out over the wire (an existing Mac -> ESP32-S3 UART-passthrough bridge,
 * 115200 baud, already used for other TJC work in this project) instead of only being readable off the panel a
 * character at a time. Register map and exact values confirmed against this firmware's own `uart_set_baud_rate`
 * (IDB 0x20734, called from `main`) and `uart_write_byte` (IDB 0x208CC) - UART2, not a generic/guessed instance:
 * GPIO pinmux is port J pins 6/7 (`IO_MOD_REG10`/0x2E8 bits [15:12], `AF_SEL_REG19`/0x338 bits [27:20], both
 * confirmed by decompile), AF number 2, no pulls; baud divisor `UART2_TC = 0x000F001A` is `uart_set_baud_rate`'s
 * own literal value for 115200 (field_4=15 forces TC's upper nibble, field_8=0x1A is the low-16 divisor - not
 * independently re-derived from a clock/divider formula, just copied, since the real firmware already solved it
 * for this exact baud). `uart_set_baud_rate` never touches any CLK_EN_CTRL (or reset) register for UART2 - its own
 * xrefs show the boot ROM already touching UART2_DR/C2, so its bus clock is assumed already live by the time any
 * firmware code runs (same pattern already seen for IWDG in this project) - if writes here don't stick, that
 * assumption is the first thing to revisit. */
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
.equ UART2_PINMODE_MASK, 0xF000            @ IO_MOD_REG10 bits [15:12]: port J pins 6 (13:12) + 7 (15:14)
.equ UART2_PINMODE_AF,   0x5000            @ mode = AF (01) for both pins
.equ UART2_AFR_MASK,     0x0FF00000        @ AF_SEL_REG19 bits [27:20]: pin 6's nibble + pin 7's nibble
.equ UART2_AFR_VAL,      0x02200000        @ AF2 for both pins
.equ UART2_PULL_MASK,    0x600000          @ IO_PU_REG5/IO_PD_REG5: the exact bits `uart_set_baud_rate` clears -
                                           @   copied as-is rather than re-derived from a port/pin-number formula
.equ UART2_TC_VAL,       0x000F001A        @ 115200 baud - this firmware's own literal value, see above
.equ UART2_TXFIFO_MASK,  0x1F00            @ UART2_TH bits [12:8]: TX FIFO fill level
.equ UART2_TXFIFO_FULL,  0x1000            @ uart_write_byte waits while fill level >= this

/* ---- bit-banged I2C on PB12 (SCL) / PB13 (SDA) - register sequence from i2c_pins_init (IDB 0x10890) and
 * the i2c_start/stop/write_byte/read_byte/wait_ack/send_ack/send_nack functions listed above. Like the panel
 * pins, these are read back through GPIOB_DR regardless of what this file last wrote to GPIOB_OBSR (true for
 * open-drain pins with an external/internal pull-up) - the real firmware never toggles direction mid-
 * transaction either, only once in i2c_pins_init, which is why every routine below only touches OBSR/DR. */
.equ SYS_IOMODE_B, 0x2C8                   @ IO_MOD_REG2 = port B's pin-mode register
.equ SYS_IOOD_AB,  0x238                   @ IO_OD_REG1 = open-drain enable, ports A (bits 0..15) / B (bits 16..31)
.equ GPIOB_BASE, 0x40011000
.equ GPIOB_DR,   (GPIOB_BASE + 0x00)
.equ GPIOB_OBSR, (GPIOB_BASE + 0x08)
.equ GPIOB_OMCR, (GPIOB_BASE + 0x10)
.equ I2C_SCL_PIN, 12
.equ I2C_SDA_PIN, 13
.equ I2C_SCL_LO, (1 << I2C_SCL_PIN)
.equ I2C_SCL_HI, (1 << (I2C_SCL_PIN + 16))
.equ I2C_SDA_LO, (1 << I2C_SDA_PIN)
.equ I2C_SDA_HI, (1 << (I2C_SDA_PIN + 16))
.equ TOUCH_I2C_IOMODE_MASK, (0xF << 24)    @ IO_MOD_REG2 bits [27:24]: PB12 mode (25:24) + PB13 mode (27:26)
.equ TOUCH_I2C_OD_BITS,     ((1 << 28) | (1 << 29))   @ IO_OD_REG1: PB12/PB13 open-drain enable
@ CORRECTED after two GPIO self-loopback tests (SCL/SDA and RST/INT) both proved every pin toggles exactly
@ as commanded, yet the GT911 still gave zero real ACKs: re-decompiling `i2c_start`/`i2c_stop`/`i2c_write_byte`/
@ `i2c_wait_ack`/`i2c_read_byte`/`i2c_send_ack`/`i2c_send_nack` (IDB 0x10B74/0x10BD0/0x10AE0/0x10C38/0x10A3C/
@ 0x10934/0x109C8) found every single GPIO transition in the real firmware is paced by `usleep(N)` with N in
@ 1-40 *microseconds* - nothing like this file's old instruction-count `i2c_delay` (last at 2000 iterations),
@ which has no established relationship to real time at all (this project's own confirmed slow-and-unpredictable
@ SDRAM instruction fetch rate, already the root cause of two earlier bugs - the buzzer and the touch-wait
@ "looks frozen" symptom - applies here too: 2000 iterations could be orders of magnitude longer than the
@ microseconds GT911 actually expects between transitions, which plausibly looks like a bus-timeout fault to a
@ simple I2C slave). The real firmware also verifies every transition by polling GPIOB_DR for the expected level
@ (up to 100 times, ~2us apart) instead of blindly delaying a fixed time - `i2c_set_and_verify` below replicates
@ this, and `i2c_wait_us` replaces the old `i2c_delay` with a TIM5-timed microsecond wait (this project's already-
@ established fix for "needs to be real time, not instruction count": see timer_delay_ticks above). TIM5 runs at
@ the same 500 kHz (2us/tick) prescaler used for the RST/INT hold delays - now kept running throughout the whole
@ touch section instead of being reconfigured back to 2MHz partway through, so one consistent timer serves both
@ the microsecond-scale I2C pacing and the longer touch-wait timeout (TOUCH_TIMEOUT_WRAPS/TOUCH_REPORT_HOLD_WRAPS
@ below are recomputed for 500 ticks/ms instead of 2000 accordingly).
.equ TOUCH_TIMER_ARR,     0xFFFF
.equ TOUCH_TIMEOUT_MS,    10000
.equ TOUCH_TIMEOUT_WRAPS, (((TOUCH_TIMEOUT_MS * 500) / (TOUCH_TIMER_ARR + 1)) + 1)
@ Purely a debug aid: a hardware test showed the final 'S'/'K'/'X' report flashing by too fast to read, because
@ the screen gets reprogrammed almost immediately once control returns to the loader's own stock-firmware boot
@ path - hold whatever was just drawn on screen for a few seconds before actually returning, same TIM5-wrap
@ timing technique as TOUCH_TIMEOUT_WRAPS above (not an instruction-count loop, for the same reason).
.equ TOUCH_REPORT_HOLD_MS,    10000           @ bumped from 3000: still not quite enough time to read both the
                                           @   status line and the X/Y coordinate line together
.equ TOUCH_REPORT_HOLD_WRAPS, (((TOUCH_REPORT_HOLD_MS * 500) / (TOUCH_TIMER_ARR + 1)) + 1)

/* i2c_wait_us us: busy-waits until TIM5's free-running counter (500 kHz, 2us/tick - see the comment above) has
 * advanced by `us` microseconds, rounding up ((us+1)/2 ticks) so even a 1us request waits at least one real
 * tick. Same wraparound-safe subtraction as timer_delay_ticks. Clobbers r0-r3. */
.macro i2c_wait_us us
    ldr r0, =(TIM5_BASE + TIM_CNT)
    ldr r1, [r0]
.Liwait\@:
    ldr r2, [r0]
    subs r2, r2, r1
    ldr r3, =0xFFFF
    ands r2, r2, r3
    ldr r3, =(((\us) + 1) / 2)
    cmp r2, r3
    blo .Liwait\@
.endm

/* i2c_set_and_verify value, pin, expect: writes GPIOB_OBSR = value, then polls GPIOB_DR bit `pin` for level
 * `expect` (0 or 1), up to 100 times with a 2us pause between checks - the real firmware's own pattern (every
 * i2c_start/stop/write_byte/etc. transition is followed by exactly this poll, not a blind delay). Falls through
 * after 100 tries regardless (matching the real firmware, which also doesn't hang forever here). Clobbers r0-r3. */
.macro i2c_set_and_verify value, pin, expect
    ldr r0, =GPIOB_OBSR
    ldr r1, =\value
    str r1, [r0]
    movs r2, #100
.Lisv_loop\@:
    ldr r0, =GPIOB_DR
    ldr r1, [r0]
    lsrs r1, r1, #\pin
    ands r1, r1, #1
    cmp r1, #\expect
    beq .Lisv_done\@
    i2c_wait_us 2
    subs r2, r2, #1
    bne .Lisv_loop\@
.Lisv_done\@:
.endm

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
@ CORRECTED after a hardware test showed the 4th identifier line (g_scr_info.field_16, the newest addition)
@ running off the bottom of the panel: at the old TEXT_SCALE=6, TOUCH_TYPE_Y0 (252) + one glyph's height (42)
@ = 294, past the 272-pixel-tall panel - nothing caught this because each line was only ever checked against the
@ *next* line's position, not the panel's actual bottom edge. Shrinking the font leaves comfortable headroom for
@ this many lines (and then some) instead of re-deriving one more exact-fit position every time a line is added.
.equ TEXT_SCALE,   4                       @ each font pixel becomes a TEXT_SCALE x TEXT_SCALE block on screen
.equ TEXT_X0,      40
.equ TEXT_Y0,      20
.equ TEXT_COLOR,   0x0000                  @ black, on top of the green test fill
.equ CHAR_ADVANCE, ((GLYPH_W + 1) * TEXT_SCALE)    @ glyph width plus one font-pixel of gap, both scaled

.equ TEXT_BUF, 0x90000                     @ scratch RAM for building one hex line (11 bytes used) - this
                                           @   image's own code/data ends well below this (loaded at 0x80000,
                                           @   under 4 KiB so far), and it is far below FB_BASE
.equ ID_LINE_Y0,      60                   @ first identifier line, below "HELLO WORLD" (TEXT_Y0=20, now 28px tall)
.equ ID_LINE_SPACING, 34                   @ 28px glyph height (at TEXT_SCALE=4) + a gap, so lines don't touch
.equ TOUCH_DEBUG_Y0,  (ID_LINE_Y0 + 2 * ID_LINE_SPACING)   @ 3rd identifier line: the touch status byte, see wait_touch_i2c
.equ TOUCH_DEBUG_W,   (11 * CHAR_ADVANCE)  @ "L:HHHHHHHH" is 10 chars, rounded up to the hex_line buffer's 11
.equ TOUCH_DEBUG_H,   (GLYPH_H * TEXT_SCALE)
.equ LOOPBACK_Y0,     (ID_LINE_Y0 + 3 * ID_LINE_SPACING)   @ 4th identifier line: GPIO self-loopback test, see
                                                           @   clear_touch_debug's own comment / entry's touch section

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

/* uart_dump_buf: sends TEXT_BUF (nul-terminated, same buffer hex_line/draw_text already built this call's on-
 * screen line from) followed by CRLF, so every on-screen diagnostic line also lands in the serial log verbatim
 * (see the UART2 section further down for uart_puts/uart_putc themselves). Clobbers r0-r4 and lr (saved/restored
 * internally) - callers don't need to wrap this in their own push/pop. Defined here (not next to uart_puts/
 * uart_putc) because a macro must be defined before any use, even one nested inside another macro's body - see
 * touch_checkpoint below, the first thing that needs it. */
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
/* touch_checkpoint label: draws a single digit on the touch-debug line and leaves it there - a crude but cheap
 * "did we get this far" marker for narrowing down a hang/crash with no debugger, reusing the already-working
 * clear_touch_debug/hex_line/draw_text path (hex_line's value is fixed at 0, only the label digit matters here).
 * TEMPORARY: for bisecting the "no S: line ever appears, even with WTI_BATCH=1" hardware report - remove once
 * the real cause is found, these are not meant to stay in the final image. */
.macro touch_checkpoint label
    push {lr}
    ldr r0, =TOUCH_DEBUG_Y0
    bl clear_touch_debug
    movs r0, #0
    movs r1, #\label
    ldr r2, =TEXT_BUF
    bl hex_line
    ldr r0, =TEXT_BUF
    ldr r1, =TEXT_X0
    ldr r2, =TOUCH_DEBUG_Y0
    bl draw_text
    uart_dump_buf
    pop {lr}
.endm

.macro rmw addr, clr, set
    ldr r0, =\addr                         @ r0 = register address
    ldr r1, =\clr                          @ r1 = bits to clear
    ldr r3, =\set                          @ r3 = bits to set
    ldr r2, [r0]                           @ r2 = current value
    bic r2, r2, r1                         @ r2 &= ~clr
    orr r2, r2, r3                         @ r2 |= set
    str r2, [r0]                           @ write back
.endm

/* ensure_lirc: enables LIRC (the internal low-speed RC oscillator, SYS_LIRC_CTRL) and waits for CMUST's LIRC-
 * stable bit, bailing out after OSC_WAIT_TIMEOUT polls rather than hanging forever if it never reports stable.
 * CORRECTED after a hardware test showed the cold-boot IWDG (armed right at the very top of `entry`, before any
 * of the oscillator bring-up further down) never actually firing even after waiting well past its programmed
 * timeout - this SoC's oscillators are confirmed OFF by default and must be explicitly enabled (the exact bug
 * that cost several hardware iterations on PLLSAI earlier in this file's history, see its own header comment);
 * IWDG's "independent" clock almost certainly still comes from this same LIRC block, so arming it before LIRC
 * is even running just loads a counter that never ticks. Both IWDG arm sites in `entry` (the cold-boot one and
 * the probe-pass one) now call this first. Clobbers r0, r2, r3, r4 - same convention as rmw above. */
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
    @ ---- reset-survival flag: skip straight back to the loader (-> stock firmware, see the boot-chain comment
    @ below BOOT_FLAG_ADDR) if this is a repeat run since the last cold boot ----
    @ ldr_main (the SD-card stage-0 loader, SRAM-resident) copies itself into SRAM and rescans the SD card on
    @ EVERY reset, including one caused by a hung stage1 tripping a hardware watchdog - a watchdog reset does
    @ not erase SRAM (only a real power-on reset would), so a flag planted outside the loader's own working set
    @ survives it. Without this, a watchdog would just restart stage1 forever (same diagnostics, same chance to
    @ hang again) instead of ever reaching the stock firmware it is meant to fall back to. This check has to be
    @ the very first thing in `entry`, before anything else touches r4-r11 or lr, so the early-exit path here
    @ can `bx lr` directly with zero cleanup - nothing has been pushed yet to pop.
    @ SIMPLIFIED back to a single-boot flow: this used to be a 3-state machine (cold pass arms a long IWDG and
    @ bails immediately, letting stock firmware run once so a second pass could read back g_scr_info.field_16 -
    @ the touch-controller-type selector) purely to answer a one-time question: is this unit's touch controller
    @ really GT911? A hardware test confirmed field_16==2 (GT911) and, with that settled, real touch detection
    @ now works end to end (see wait_touch_i2c's own history) - the double-reboot dance was never needed for
    @ touch itself (RST/I2C bring-up is from-scratch, independent of anything stock firmware does), only for that
    @ one-shot diagnostic read. Back to a plain 2-state flag: DONE (skip straight to stock) or not (run once).
    ldr r0, =BOOT_FLAG_ADDR
    ldr r1, [r0]
    ldr r2, =BOOT_FLAG_DONE
    cmp r1, r2
    bne .flag_run
.flag_bail:
    bx lr                                   @ already ran once since the last cold boot: straight to stock firmware
.flag_run:
    str r2, [r0]                            @ mark done before doing anything risky

    push {lr}                               @ lr still holds the loader's own return address at this point -
                                           @   nothing has pushed it yet, so these two `bl`s must not clobber it
    bl uart_init                             @ mirror every diagnostic line below out over the TJC serial link too
    ldr r0, =uart_banner
    bl uart_puts
    pop {lr}

    @ ---- arm the hardware watchdog (~10s, see IWDG_RLR_VAL's comment) before doing anything else that could
    @ hang - this is a last-resort net underneath the reset-survival flag above and the software touch-wait
    @ timeout further down: a hardware test already found one bug (a clobbered-lr self-loop in i2c_clear_status)
    @ that no software timeout could ever see, because the hang happened in code the timeout-checking loop never
    @ got back to. `iwdg_feed` (defined above) is called periodically throughout this file below; anywhere that
    @ stops happening for ~10s, the chip resets and the flag above sends the next pass straight to stock firmware.
    ensure_lirc                                                   @ IWDG's clock - see the macro's own comment
    rmw (SYS_BASE + SYS_PWR_MODE_REG), 0, PWR_BKP_UNLOCK_BIT      @ unlock backup-domain writes
    ldr r0, =IWDG_KR
    ldr r1, =IWDG_KEY_UNLOCK
    str r1, [r0]                                                  @ unlock IWDG_PR/IWDG_RLR for writing
    ldr r0, =IWDG_PR
    ldr r1, =IWDG_PR_VAL
    str r1, [r0]
.iwdg_pr_verify:
    ldr r2, [r0]
    cmp r2, r1
    bne .iwdg_pr_verify                      @ same poll-until-latched pattern the firmware's own `restart` uses
    ldr r0, =IWDG_RLR
    ldr r1, =IWDG_RLR_VAL
    str r1, [r0]
.iwdg_rlr_verify:
    ldr r2, [r0]
    cmp r2, r1
    bne .iwdg_rlr_verify
    ldr r0, =IWDG_KR
    ldr r1, =IWDG_KEY_START
    str r1, [r0]                                                  @ (re)start: harmless if already running
    rmw (SYS_BASE + SYS_PWR_MODE_REG), PWR_BKP_UNLOCK_BIT, 0      @ re-lock the backup domain

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
    iwdg_feed
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
    @ image) - save it around every nested `bl` so entry's own final `bx lr` still works afterward.
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

    b 2f                                     @ literal-pool flush, see the comment at the previous one
    .ltorg
2:
    iwdg_feed
    @ ==== identifiers: a couple of real SoC/core ID registers, in hex, one per line - see hex_line below ====
    @ "0:" = CID (the stage-0 loader's own chip-variant register, SYS_BASE+0x00, see the firmware-hazards and
    @ soc-identification project memories); "1:" = CPUID (standard ARM SCB->CPUID, 0xE000ED00 - generic to any
    @ Cortex-M, not vendor-specific). OTP CHIPID1/2 are deliberately not shown here: their offsets are known
    @ (0x10/0xF0) but the OTP block's own base address was never pinned down, so reading them would be a guess.
    ldr r0, =SYS_BASE
    ldr r0, [r0]
    movs r1, #0x30                           @ '0'
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

    ldr r0, =0xE000ED00                      @ CPUID
    ldr r0, [r0]
    movs r1, #0x31                           @ '1'
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

    @ g_scr_info.field_16 (the touch-controller-type selector, confirmed GT911 via the now-removed two-pass
    @ probe - see entry's own history comment) is no longer read/displayed here: on a single-boot flow, stock
    @ firmware hasn't run yet by this point, so that SDRAM address holds leftover/uninitialized content, not a
    @ real value - displaying it now would just be misleading.

    b 3f
    .ltorg
3:
    iwdg_feed
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

    @ ==== touch: bring up I2C (PB12/PB13), reset the controller (GT911 address select), then wait for a tap ====
    iwdg_feed
    touch_checkpoint 0x31                                     @ '1': reached the touch section at all

    @ ---- bring up TIM5 as a free-running tick counter at TIM_DELAY_PSC_VAL (500 kHz) FIRST, before anything else
    @ in this section - the I2C bit-bang timing (i2c_wait_us/i2c_set_and_verify, used starting with the loopback
    @ test just below) and the RST/INT hold delays both need this running; it also serves the long touch-wait
    @ timeout later (TOUCH_TIMEOUT_WRAPS is computed for this same 500 kHz rate, see its own comment - this file
    @ no longer switches TIM5 back to 2 MHz partway through, one consistent timer now serves the whole section).
    @ Idle since the melody finished; its PWM setup (CCMR1/2, CCER) from the buzzer section is still intact, duty
    @ stays 0 (CCR4), so this counts silently with no audible change. ----
    ldr r1, =TIM5_BASE
    movs r2, #0
    str r2, [r1, #TIM_CR1]                                     @ stop while reconfiguring
    str r2, [r1, #TIM_CNT]
    str r2, [r1, #TIM_CCR4]                                    @ duty 0: silent even while running
    ldr r2, =TIM_DELAY_PSC_VAL
    str r2, [r1, #TIM_PSC]
    ldr r2, =TOUCH_TIMER_ARR
    str r2, [r1, #TIM_ARR]
    movs r2, #1
    str r2, [r1, #TIM_CR1]                                     @ go

    @ CORRECTED (again) after a hardware test with an on-screen/UART GPIO self-loopback readback test (see
    @ clear_touch_debug's own "GPIO self-loopback sanity check" block) directly proved SCL (PB12) was NOT
    @ actually going low when commanded: driving it low via OBSR still read back HIGH on GPIOB_DR, while SDA
    @ behaved exactly as expected (low reads low, released reads high). Earlier, this file had matched the real
    @ `i2c_pins_init`'s (IDB 0x10890) OMCR write bit-for-bit - it only ever puts SDA into output mode
    @ (`GPIOB_OMCR = 0x2000`), never SCL - on the theory that this register's semantics are opaque enough to not
    @ second-guess. The loopback test shows that theory was wrong for THIS boot context: the real firmware can
    @ get away with never touching SCL's OMCR bit because something earlier in its own (much longer, much later)
    @ boot sequence already leaves it in output mode by the time `i2c_pins_init` runs - this image runs from a
    @ cold SD-loader boot with no such prior state, so SCL's OMCR bit is back to whatever this SoC's true reset
    @ value is, which this test proves is NOT "output". Setting it explicitly (restoring this file's very first,
    @ pre-"bit-for-bit-match" attempt) is the correct fix for this boot context, not a step backward.
    rmw (SYS_BASE + SYS_IOMODE_B), TOUCH_I2C_IOMODE_MASK, 0   @ PB12/PB13 mode = GPIO
    rmw (SYS_BASE + SYS_IOOD_AB), 0, TOUCH_I2C_OD_BITS        @ open-drain
    ldr r0, =GPIOB_OMCR
    ldr r1, =(I2C_SCL_LO | I2C_SDA_LO)
    str r1, [r0]                                              @ both pins -> output (see the comment above for why)
    ldr r0, =GPIOB_OBSR
    ldr r1, =(I2C_SCL_HI | I2C_SDA_HI)
    str r1, [r0]                                              @ release both high: idle bus
    ldr r2, =100
.i2c_pins_wait:
    ldr r0, =GPIOB_DR
    ldr r1, [r0]
    lsrs r1, r1, #I2C_SCL_PIN
    ands r1, r1, #1
    cmp r1, #1
    beq .i2c_pins_ready
    i2c_wait_us 2
    subs r2, r2, #1
    bne .i2c_pins_wait
.i2c_pins_ready:

    @ ---- GPIO self-loopback sanity check (TEMPORARY diagnostic) ----
    @ Drives SCL then SDA low (via OBSR) and reads them back (via DR), then releases each high and reads back
    @ again - no GT911 cooperation needed for this, it only proves OUR OWN pin access/mode/clock config is real.
    @ Added after zero real ACKs from the GT911 couldn't be explained by anything else checked (pin mode,
    @ open-drain enable, OMCR, RST/INT sequence/timing, GPIO clock gating, bit-bang delay length - all matched
    @ the real firmware with no discrepancy found). Expected result if the pins are genuinely alive and not,
    @ say, clock-gated-off or stuck floating: bit0=0 (SCL driven low reads low), bit1=1 (SCL released reads high,
    @ pulled up), bit2=0, bit3=1 (same for SDA) - displayed value 0x0A. Anything else points at the GPIO/clock
    @ level, below the I2C protocol entirely.
    movs r9, #0
    ldr r0, =GPIOB_OBSR
    ldr r1, =I2C_SCL_LO
    str r1, [r0]
    i2c_wait_us 2
    ldr r0, =GPIOB_DR
    ldr r1, [r0]
    lsrs r1, r1, #I2C_SCL_PIN
    ands r1, r1, #1
    orrs r9, r9, r1                          @ bit0: SCL driven low

    ldr r0, =GPIOB_OBSR
    ldr r1, =I2C_SCL_HI
    str r1, [r0]
    i2c_wait_us 2
    ldr r0, =GPIOB_DR
    ldr r1, [r0]
    lsrs r1, r1, #I2C_SCL_PIN
    ands r1, r1, #1
    lsls r1, r1, #1
    orrs r9, r9, r1                          @ bit1: SCL released

    ldr r0, =GPIOB_OBSR
    ldr r1, =I2C_SDA_LO
    str r1, [r0]
    i2c_wait_us 2
    ldr r0, =GPIOB_DR
    ldr r1, [r0]
    lsrs r1, r1, #I2C_SDA_PIN
    ands r1, r1, #1
    lsls r1, r1, #2
    orrs r9, r9, r1                          @ bit2: SDA driven low

    ldr r0, =GPIOB_OBSR
    ldr r1, =I2C_SDA_HI
    str r1, [r0]
    i2c_wait_us 2
    ldr r0, =GPIOB_DR
    ldr r1, [r0]
    lsrs r1, r1, #I2C_SDA_PIN
    ands r1, r1, #1
    lsls r1, r1, #3
    orrs r9, r9, r1                          @ bit3: SDA released

    mov r0, r9
    movs r1, #0x4C                           @ 'L' = loopback test result
    ldr r2, =TEXT_BUF
    push {lr}
    bl hex_line
    pop {lr}
    ldr r0, =TEXT_BUF
    ldr r1, =TEXT_X0
    ldr r2, =LOOPBACK_Y0
    push {lr}
    bl draw_text
    uart_dump_buf
    pop {lr}

    @ RST = PF6, driven low then released; INT = PF5, driven low during the reset pulse (selects the GT911's
    @ 0xBA/0xBB I2C address, matching touch_init's own sequence), held low well past RST's release (see
    @ TOUCH_ADDR_LATCH_HOLD_MS's comment above), then switched to input - a touch pulls it low.
    @ GPIO self-loopback check for RST/INT too (r9 accumulator: bit0=RST@low, bit1=RST@released, bit2=INT@low,
    @ bit3=INT@released) - added after the I2C SCL/SDA loopback test caught a real bug (SCL silently not going
    @ output despite the real firmware never needing to set it explicitly); same reasoning applies here, these
    @ pins were never independently verified to actually toggle. Expected if genuinely alive: 0b1010 = 0xA,
    @ same pattern as the I2C test. Dumped over UART only (no screen space budgeted for a 6th identifier line).
    movs r9, #0
    rmw (SYS_BASE + SYS_IOMODE5), TOUCH_RST_IOMODE_MASK, 0   @ PF6 mode = GPIO
    rmw (SYS_BASE + SYS_IOPU_EF), TOUCH_RST_PU_PD_BIT, 0     @ no pull-up
    rmw (SYS_BASE + SYS_IOPD_EF), TOUCH_RST_PU_PD_BIT, 0     @ no pull-down
    ldr r0, =GPIOF_OMCR
    ldr r1, =TOUCH_RST_PIN_MASK
    str r1, [r0]                                              @ PF6 -> output
    ldr r0, =GPIOF_OBSR
    str r1, [r0]                                              @ PF6 low: RST asserted
    ldr r0, =GPIOF_DR
    ldr r1, [r0]
    lsrs r1, r1, #TOUCH_RST_PIN
    ands r1, r1, #1
    orrs r9, r9, r1                                           @ bit0: RST driven low

    rmw (SYS_BASE + SYS_IOMODE5), TOUCH_INT_IOMODE_MASK, 0   @ PF5 mode = GPIO
    rmw (SYS_BASE + SYS_IOPU_EF), TOUCH_INT_PU_PD_BIT, 0
    rmw (SYS_BASE + SYS_IOPD_EF), TOUCH_INT_PU_PD_BIT, 0
    ldr r0, =GPIOF_OMCR
    ldr r1, =TOUCH_INT_PIN_MASK
    str r1, [r0]                                              @ PF5 -> output
    ldr r0, =GPIOF_OBSR
    str r1, [r0]                                              @ PF5 low: selects the GT911 I2C address
    ldr r0, =GPIOF_DR
    ldr r1, [r0]
    lsrs r1, r1, #TOUCH_INT_PIN
    ands r1, r1, #1
    lsls r1, r1, #2
    orrs r9, r9, r1                                           @ bit2: INT driven low

    timer_delay_ticks TOUCH_RESET_HOLD_TICKS                   @ 10 ms, matching touch_init's own sub_26ACC(10)

    ldr r0, =GPIOF_OBSR
    ldr r1, =TOUCH_RST_PIN_HI_MASK
    str r1, [r0]                                              @ PF6 high: RST released - INT (PF5) stays LOW
    ldr r0, =GPIOF_DR
    ldr r1, [r0]
    lsrs r1, r1, #TOUCH_RST_PIN
    ands r1, r1, #1
    lsls r1, r1, #1
    orrs r9, r9, r1                                           @ bit1: RST released

    timer_delay_ticks TOUCH_ADDR_LATCH_HOLD_TICKS               @ extra margin before touching INT - see the
                                                               @   TOUCH_ADDR_LATCH_HOLD_MS comment above

    rmw (SYS_BASE + SYS_IOPU_EF), 0, TOUCH_INT_PU_PD_BIT      @ pull-up PF5 before switching it to input
    ldr r0, =GPIOF_IMCR
    ldr r1, =TOUCH_INT_PIN_MASK
    str r1, [r0]                                              @ PF5 -> input
    ldr r0, =GPIOF_OBSR
    ldr r1, =TOUCH_INT_PIN_HI_MASK
    str r1, [r0]                                              @ release PF5 (now pulled high, idle = no touch)
    ldr r0, =GPIOF_DR
    ldr r1, [r0]
    lsrs r1, r1, #TOUCH_INT_PIN
    ands r1, r1, #1
    lsls r1, r1, #3
    orrs r9, r9, r1                                           @ bit3: INT released

    mov r0, r9
    movs r1, #0x52                           @ 'R' = RST/INT loopback test result
    ldr r2, =TEXT_BUF
    push {lr}
    bl hex_line
    pop {lr}
    push {lr}
    ldr r0, =TEXT_BUF
    bl uart_puts
    movs r0, #0x0D
    bl uart_putc
    movs r0, #0x0A
    bl uart_putc
    pop {lr}

    @ TIM5 is still running, uninterrupted, at the 500 kHz rate set up at the top of this section - no
    @ reconfigure needed here any more (this file used to switch back to 2 MHz for the long touch-wait timeout;
    @ now one consistent rate serves both the microsecond I2C pacing and the timeout, see TOUCH_TIMEOUT_WRAPS).
    touch_checkpoint 0x32                                      @ '2': I2C/RST/INT/timer bring-up all completed
    iwdg_feed

    b 4f
    .ltorg
4:
    push {lr}
    bl wait_touch_i2c                                         @ returns on a real touch, or after TOUCH_TIMEOUT_MS
    pop {lr}

    @ ---- done: hand control back to the loader (LR from the BLX) ----
    pop {r6}
    bx lr

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
    mov r7, r0                              @ string pointer
    mov r8, r1                              @ cursor x, advances after each character
    mov r9, r2                              @ fixed: single line of text
    ldr r3, =TEXT_COLOR                     @ constant for the whole call; draw_glyph must not clobber r3
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
    bne .dg_try_hex
    ldr r10, =glyph_D
    b .dg_have_glyph
.dg_try_hex:
    cmp r0, #0x30                           @ '0'
    blt .dg_try_colon
    cmp r0, #0x39                           @ '9'
    bgt .dg_try_AF
    ldr r1, =glyph_0
    sub r0, r0, #0x30                       @ digit index 0..9
    lsls r0, r0, #3                         @ 8 bytes-worth... see note below: glyphs are 7 bytes but kept
    b .dg_hex_index                         @   4-byte-aligned (8 apart) so this is a plain shift, not a multiply
.dg_try_AF:
    cmp r0, #0x41                           @ 'A'
    blt .dg_space
    cmp r0, #0x43                           @ 'C'
    bgt .dg_try_F
    ldr r1, =glyph_A
    sub r0, r0, #0x41                       @ 0=A, 1=B, 2=C
    lsls r0, r0, #3
    b .dg_hex_index
.dg_try_F:
    cmp r0, #0x46                           @ 'F'
    bne .dg_try_colon
    ldr r10, =glyph_F
    b .dg_have_glyph
.dg_hex_index:
    add r10, r1, r0
    b .dg_have_glyph
.dg_try_colon:
    cmp r0, #0x3A                           @ ':'
    bne .dg_space
    ldr r10, =glyph_COLON
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

/* hex_line(r0 = 32-bit value, r1 = label character, r2 = destination buffer) -> writes "L:HHHHHHHH\0" (11
 * bytes) at [r2], most-significant nibble first. Leaf function, uses only r0-r3 (all free-scratch registers
 * throughout this file), so it needs no push/pop of its own. */
.thumb_func
hex_line:
    strb r1, [r2]
    adds r2, r2, #1
    movs r3, #0x3A                          @ ':'
    strb r3, [r2]
    adds r2, r2, #1
    movs r1, #8                             @ 8 nibbles in a 32-bit value
.hl_loop:
    lsrs r3, r0, #28                        @ top nibble (bits 31:28)
    lsls r0, r0, #4                         @ shift the rest up for the next iteration
    cmp r3, #10
    blt .hl_digit
    adds r3, r3, #(0x41 - 10)               @ 'A' + (nibble - 10)
    b .hl_store
.hl_digit:
    adds r3, r3, #0x30                      @ '0' + nibble
.hl_store:
    strb r3, [r2]
    adds r2, r2, #1
    subs r1, r1, #1
    bne .hl_loop
    movs r3, #0
    strb r3, [r2]                           @ nul-terminate
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
    bics r1, r1, r2                         @ bic/bics: Thumb-16 only has the register form, no immediate - use
    movs r2, #3                             @   a scratch register for the small constant instead
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
    str r1, [r0]                            @ clear pending flags (not using interrupts, harmless either way)
    ldr r0, =UART2_LS
    movs r1, #0
    str r1, [r0]
    bx lr

/* uart_putc(r0 = byte): polls UART2_TH's TX FIFO fill level, same as uart_write_byte's own wait, then writes
 * UART2_DR. Leaf function. */
.thumb_func
uart_putc:
    mov r3, r0                              @ byte, kept out of r0-r2 while polling
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
    pop {r4, pc}

@ uart_dump_buf is a macro, not a subroutine, and macros must be *defined* before any use, even a nested one
@ inside another macro's body (unlike a `bl` to a labeled subroutine, which can forward-reference) - it is
@ therefore defined up near touch_checkpoint (the earliest macro that needs it), not down here next to the
@ uart_puts/uart_putc subroutines it actually calls (which, being plain labels, have no such ordering constraint).

/* ==========================================================================
 *  I2C (bit-banged, PB12/PB13) and the touch-wait loop that uses it
 * ========================================================================== */

/* CORRECTED (again) after both GPIO self-loopback tests proved every pin toggles correctly yet the GT911 still
 * gave zero real ACKs: these used to pace every transition with the old instruction-count `i2c_delay` (see its
 * replacement, `i2c_wait_us`, and `i2c_set_and_verify`'s own comment above for why). Every GPIO write below now
 * goes through `i2c_set_and_verify` (write + poll-until-confirmed, matching the real firmware's own pattern)
 * with the real firmware's own per-transition `usleep()` values. i2c_write_byte/i2c_read_byte now need r4 (to
 * hold the byte/accumulator across `i2c_set_and_verify`'s own r0-r3 use) and so are no longer leaf-with-no-
 * push/pop - they push/pop r4 themselves, transparent to callers. The others still only need r0-r3. */
.thumb_func
i2c_start:
    i2c_set_and_verify I2C_SDA_HI, I2C_SDA_PIN, 1
    i2c_wait_us 2
    i2c_set_and_verify I2C_SCL_HI, I2C_SCL_PIN, 1
    i2c_wait_us 2
    i2c_set_and_verify I2C_SDA_LO, I2C_SDA_PIN, 0
    i2c_wait_us 2
    i2c_set_and_verify I2C_SCL_LO, I2C_SCL_PIN, 0
    i2c_wait_us 2
    bx lr

.thumb_func
i2c_stop:
    i2c_wait_us 10
    i2c_set_and_verify I2C_SDA_LO, I2C_SDA_PIN, 0
    i2c_wait_us 4
    i2c_set_and_verify I2C_SCL_HI, I2C_SCL_PIN, 1
    i2c_wait_us 4
    i2c_set_and_verify I2C_SDA_HI, I2C_SDA_PIN, 1
    i2c_wait_us 4
    bx lr

/* i2c_write_byte(r0 = byte, MSB first) - r4 holds the byte being shifted; i2c_set_and_verify/i2c_wait_us never
 * touch r4, only r0-r3, so r4 persists across iterations untouched and needs no save/restore of its own - only
 * the bit counter (r1) is saved/restored, since i2c_set_and_verify does use r1 internally. */
.thumb_func
i2c_write_byte:
    push {r4, lr}
    mov r4, r0                               @ byte, shifted left each iteration
    movs r1, #8
.i2c_wb_loop:
    lsls r4, r4, #1                          @ next bit (MSB first) into Carry
    push {r1}
    bcc .i2c_wb_0
    i2c_set_and_verify I2C_SDA_HI, I2C_SDA_PIN, 1
    b .i2c_wb_set
.i2c_wb_0:
    i2c_set_and_verify I2C_SDA_LO, I2C_SDA_PIN, 0
.i2c_wb_set:
    i2c_wait_us 1
    i2c_set_and_verify I2C_SCL_HI, I2C_SCL_PIN, 1
    i2c_wait_us 4
    i2c_set_and_verify I2C_SCL_LO, I2C_SCL_PIN, 0
    pop {r1}
    subs r1, r1, #1
    bne .i2c_wb_loop
    pop {r4, pc}

/* i2c_wait_ack -> r0 = 0 (device pulled SDA low: real ACK) or 1 (SDA stayed high/floating: NACK, or nothing
 * answering at all). See this function's own long-standing comment history above for why the ack bit is
 * checked at all (diagnostic value) - now paced with the real firmware's own ~40us/100-try ack-settle timing
 * instead of the fixed short delay used everywhere else. */
.thumb_func
i2c_wait_ack:
    i2c_set_and_verify I2C_SDA_HI, I2C_SDA_PIN, 1
    i2c_set_and_verify I2C_SCL_HI, I2C_SCL_PIN, 1
    i2c_wait_us 40
    ldr r1, =GPIOB_DR
    ldr r2, [r1]
    lsrs r2, r2, #I2C_SDA_PIN
    ands r0, r2, #1                         @ r0 = SDA level during the ack clock: 0 = ACK, 1 = NACK/floating
    i2c_set_and_verify I2C_SCL_LO, I2C_SCL_PIN, 0
    bx lr

.thumb_func
i2c_send_ack:
    i2c_set_and_verify I2C_SDA_LO, I2C_SDA_PIN, 0
    i2c_set_and_verify I2C_SCL_HI, I2C_SCL_PIN, 1
    i2c_wait_us 4
    i2c_set_and_verify I2C_SCL_LO, I2C_SCL_PIN, 0
    i2c_set_and_verify I2C_SDA_HI, I2C_SDA_PIN, 1
    bx lr

.thumb_func
i2c_send_nack:
    i2c_set_and_verify I2C_SDA_HI, I2C_SDA_PIN, 1
    i2c_set_and_verify I2C_SCL_HI, I2C_SCL_PIN, 1
    i2c_wait_us 4
    i2c_set_and_verify I2C_SCL_LO, I2C_SCL_PIN, 0
    bx lr

/* i2c_read_byte() -> r0 = byte read, MSB first */
.thumb_func
i2c_read_byte:
    push {r4, lr}
    movs r4, #0                             @ accumulator
    movs r1, #8                             @ bit counter
.i2c_rb_loop:
    push {r1}                                @ only the bit counter needs protecting - r4 (accumulator) is never
                                           @   touched by i2c_set_and_verify/i2c_wait_us (r0-r3 only)
    i2c_set_and_verify I2C_SCL_LO, I2C_SCL_PIN, 0
    i2c_wait_us 4
    i2c_set_and_verify I2C_SCL_HI, I2C_SCL_PIN, 1
    i2c_wait_us 3
    ldr r0, =GPIOB_DR
    ldr r3, [r0]
    lsrs r3, r3, #I2C_SDA_PIN
    ands r3, r3, #1
    pop {r1}
    lsls r4, r4, #1
    orrs r4, r4, r3
    subs r1, r1, #1
    bne .i2c_rb_loop
    mov r0, r4
    pop {r4, pc}

/* i2c_clear_status: writes 0x00 to the GT911's status register (0x814E) - a plain register write, no repeated
 * start/read. The GT911 does NOT clear its own "buffer status" bit (0x814E bit 7) after being read - the real
 * firmware's touch_gt911_read always writes it back to 0 once it has consumed a touch (`touch_i2c_write_reg16`
 * in the decompile). If that bit was left set from a touch that happened before this image's own RST pulse (or
 * from any state the controller powered up with), the very first status read in wait_touch_i2c would see
 * bit 7 already 1 and return instantly, with no real new touch - exactly the "doesn't wait" symptom reported
 * on hardware. Calling this once, unconditionally, before the wait loop starts flushes any such stale flag. */
/* BUG FIXED after a hardware test showed execution never returning from this call (checkpoint '3', set right
 * before calling this, showed; checkpoint '4', set right after, never did): unlike every other function in the
 * I2C section, this one is NOT a leaf - it makes several nested `bl` calls - but it still ended with a bare
 * `bx lr`, copying the leaf convention used everywhere else in this file. Each nested `bl` overwrites `lr` with
 * its own return address; by the time control reached the final `bx lr`, `lr` held the return address from the
 * *last* nested call (into `i2c_stop`), not the address this function was itself called from - `bx lr` branched
 * there instead, which (since nothing meaningful follows `bl i2c_stop` but this same `bx lr`) looped back on
 * itself forever. Needs its own push/pop of `lr`, same as wait_touch_i2c already does correctly below. */
.thumb_func
i2c_clear_status:
    push {lr}
    bl i2c_start
    movs r0, #0xBA
    bl i2c_write_byte
    bl i2c_wait_ack
    movs r0, #0x81
    bl i2c_write_byte
    bl i2c_wait_ack
    movs r0, #0x4E
    bl i2c_write_byte
    bl i2c_wait_ack
    movs r0, #0x00
    bl i2c_write_byte
    bl i2c_wait_ack
    bl i2c_stop
    pop {pc}

/* i2c_read_reg8(r0 = register high byte, r1 = register low byte) -> r0 = data byte read.
 * A standalone, independently-addressed single-register read - the exact same shape as the already-proven
 * status-register read in wait_touch_i2c, just parameterised. CORRECTED after a hardware test showed the touch
 * point's X/Y bytes reading as a suspicious, uniform 0xFFF/0xFFF (floating-bus-looking, unlike the genuinely-
 * ACKed status byte) when read as a single continued burst (ACK after the status byte, then keep clocking more
 * bytes without re-addressing) - whatever this chip/wiring needs for a multi-byte auto-increment burst read
 * evidently isn't satisfied by this file's plain ACK-to-continue bit-bang, even though it works perfectly for a
 * single-byte read. Re-addressing every single byte, like this, is slower (one full transaction per byte instead
 * of one transaction for all of them) but reuses only the already-proven-reliable path. */
.thumb_func
i2c_read_reg8:
    push {r4, r5, lr}
    mov r4, r0                              @ register high byte
    mov r5, r1                              @ register low byte
    bl i2c_start
    movs r0, #0xBA
    bl i2c_write_byte
    bl i2c_wait_ack
    mov r0, r4
    bl i2c_write_byte
    bl i2c_wait_ack
    mov r0, r5
    bl i2c_write_byte
    bl i2c_wait_ack
    bl i2c_stop
    bl i2c_start
    movs r0, #0xBB
    bl i2c_write_byte
    bl i2c_wait_ack
    bl i2c_read_byte
    mov r4, r0                              @ stash the byte - send_nack/stop don't touch r4
    bl i2c_send_nack
    bl i2c_stop
    mov r0, r4
    pop {r4, r5, pc}

/* clear_touch_debug(r0 = y0): fills the on-screen debug line's rectangle (at the given y0, TOUCH_DEBUG_W wide,
 * TOUCH_DEBUG_H tall) with the background fill colour, using the same backward (180-degree-flip) addressing as
 * draw_glyph. Needed because draw_text/draw_glyph only ever paint a glyph's "on" pixels - a changing digit's
 * "off" pixels leave whatever was drawn there by the previous value showing through, which would otherwise
 * garble a repeatedly-refreshed line into noise. CORRECTED after a hardware test showed the X/Y coordinate line
 * (drawn at LOOPBACK_Y0, reusing that slot after the one-time loopback test) garbling on top of the old loopback
 * digits - this used to hardcode TOUCH_DEBUG_Y0, so only the status line ever actually got cleared; any OTHER
 * line reusing this function inherited stale pixels forever. Takes y0 as a parameter now. Leaf function. */
.thumb_func
clear_touch_debug:
    push {r4, r5, r6, r9}
    mov r9, r0                              @ y0 - stashed before r0 becomes scratch below
    movs r5, #0                             @ row 0..TOUCH_DEBUG_H-1
.ctd_row:
    cmp r5, #TOUCH_DEBUG_H
    bge .ctd_done
    mov r6, r5
    add r6, r6, r9
    ldr r4, =FB_PITCH
    mul r6, r6, r4
    ldr r4, =FB_BOTTOM_RIGHT
    sub r6, r4, r6
    ldr r4, =TEXT_X0
    lsls r4, r4, #1
    sub r6, r6, r4                          @ r6 = address of (TEXT_X0, TOUCH_DEBUG_Y0 + row)
    movs r4, #0                             @ column counter (pixels, not bytes)
.ctd_col:
    cmp r4, #TOUCH_DEBUG_W
    bge .ctd_col_done
    ldr r0, =FB_FILL_PIXEL
    strh r0, [r6]
    subs r6, r6, #2
    adds r4, r4, #1
    b .ctd_col
.ctd_col_done:
    adds r5, r5, #1
    b .ctd_row
.ctd_done:
    pop {r4, r5, r6, r9}
    bx lr

/* wait_touch_i2c: polls INT (PF5) and only reads the GT911 status register (0x814E) over I2C when INT is
 * already low - matching `touch_gt911_read`'s own check (IDB 0x105B0) exactly: `if (GPIOF_DR & 0x20) return 0;`
 * before it ever touches I2C. CORRECTED after a hardware test found the status register stably reading 0xFF
 * across many genuinely-ACKed reads: this used to query the I2C bus unconditionally every attempt regardless of
 * INT's level (and proactively "clear" the status register first, via a now-removed `i2c_clear_status` call) -
 * off-protocol behaviour the real firmware never does, and the most likely reason the chip settled into
 * returning constant junk instead of a real idle status. Bounded by TOUCH_TIMEOUT_MS (measured with TIM5, free-
 * running - see the setup in `entry` right before this is called - not an instruction-count loop: a hardware
 * test showed a real touch not being detected at all, so this must give up and let the caller continue rather
 * than hang forever) and broken into WTI_BATCH-attempt batches, redrawing the last status byte on screen after
 * each batch ('S' while still waiting - INT idle or a real-but-not-ready read, 'K' on a real touch, 'X' on
 * timeout) - an earlier version only drew once at the very end and, combined with a too-long delay, was
 * indistinguishable from frozen; periodic redraws make "still polling" visible.
 * r4 = status byte (0 whenever INT was idle and no I2C read happened this attempt), r5 = batch counter, r6 =
 * exit flag (0 = keep polling, 1 = return after this report) - also free for clear_touch_debug/draw_text's own
 * use, since both preserve it across their own `bl`s. r7 = previous TIM_CNT sample, r8 = elapsed TIM5 wrap count
 * (one wrap = ~131 ms at this section's 500 kHz tick). r9 = "saw a real NACK this attempt" flag (OR of all four
 * i2c_wait_ack results for the current transaction, only meaningful when INT was actually low this attempt) -
 * shown as the displayed value's bit 31, so "K:800000FF"-style output (leading 8, not 0) means the bus never
 * actually answered and the status byte is meaningless floating-bus noise, not a real register read. */
@ CORRECTED after a hardware test showed the real working loop now flooding UART with thousands of "S:00000000"
@ lines a second (now that most attempts don't touch I2C at all, each INT-idle iteration is cheap, matching the
@ earlier buzzer/touch "SDRAM instruction fetch speed is unpredictable" lesson but in the opposite direction this
@ time) - 1 was needed back when the bug under investigation was "does this loop even run", not "how often should
@ it report"; now that it demonstrably runs and works, something far less chatty is correct.
.equ WTI_BATCH, 2000

.thumb_func
wait_touch_i2c:
    push {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    touch_checkpoint 0x33                   @ '3': inside wait_touch_i2c, entering the poll loop

    @ TEMPORARY diagnostic: read the status register (0x814E) TWICE in a row, back-to-back with no intervening
    @ work, once, right here, independent of touch state - isolating whether the earlier "every read after the
    @ first touch-triggering one returns floating-bus 0xFF" symptom is actually specific to a real touch event,
    @ or just "any second read done too soon after a first one", which idle polling never exercises (each idle
    @ attempt is naturally spaced out by the rest of the loop's own work - the elapsed-time check, batch count,
    @ iwdg_feed). This runs once per call, at idle (INT not necessarily low), so if it ALSO degrades, the bug is
    @ universal, not touch-specific.
    push {lr}
    @ CORRECTED: a 50 ms gap between the two reads (tried before this) did NOT help - both still read 0xFF. New
    @ theory: it's not about the GAP BETWEEN reads, it's about how soon after the RST/INT sequence THIS FIRST
    @ ATTEMPT happens at all - the GT911 may need real boot/calibration time after reset before it answers
    @ correctly at all, and this diagnostic (first real I2C transaction attempted after reset) runs only
    @ milliseconds after RST releases, while the main loop's LATER iterations (which do work correctly) have
    @ naturally had much more wall-clock time pass by then. Test: wait a substantial time here, before either
    @ read, and see if the FIRST read (not just the second) comes back clean this time.
    timer_delay_ticks 60000                  @ ~120 ms (close to timer_delay_ticks' own ~131 ms safe ceiling at
                                           @   this 500 kHz rate - see its own comment on the 16-bit wraparound
                                           @   limit), giving the GT911 time to finish booting before any query
    movs r0, #0x81
    movs r1, #0x4E
    bl i2c_read_reg8
    mov r4, r0                               @ first read, after the boot-settle delay
    movs r0, #0x81
    movs r1, #0x4E
    bl i2c_read_reg8
    mov r5, r0                               @ immediate second read, no gap
    lsls r0, r4, #8
    orrs r0, r0, r5                          @ combined: first read in bits [15:8], second in bits [7:0]
    movs r1, #0x54                           @ 'T' = double-read test
    ldr r2, =TEXT_BUF
    bl hex_line
    ldr r0, =TEXT_BUF
    bl uart_puts
    movs r0, #0x0D
    bl uart_putc
    movs r0, #0x0A
    bl uart_putc
    pop {lr}

    ldr r0, =(TIM5_BASE + TIM_CNT)
    ldr r7, [r0]                             @ initial counter sample (0, if the caller just zeroed it - read it
                                             @   back anyway rather than assume)
    movs r8, #0                              @ elapsed wraps
    movs r4, #0                              @ status byte, 0 until a real I2C read happens
    movs r9, #0                              @ "any NACK" flag, only meaningful after a real I2C read
.wti_outer:
    ldr r5, =WTI_BATCH
.wti_loop:
    @ CORRECTED after a hardware test found the real register content stably reading 0xFF across many genuinely-
    @ ACKed reads: re-decompiling `touch_gt911_read` (IDB 0x105B0) found it checks `GPIOF_DR & 0x20` (INT/PF5)
    @ FIRST and returns immediately, with ZERO I2C traffic, whenever INT reads high - the real firmware only ever
    @ queries the status register when INT is already asserted low. This file used to hammer the I2C bus every
    @ single attempt regardless of INT's level, which is off-protocol: querying a GT911 with no pending event is
    @ not something the real firmware (or presumably the datasheet) ever does, and is the most likely reason the
    @ chip settled into returning constant junk instead of a real idle status. Gate the actual I2C transaction
    @ behind the same check.
    @ TEMPORARY: INT gate disabled to test a new theory - r4 (status byte) is only ever initialised ONCE, before
    @ the loop starts, and if INT genuinely stays high for a long idle stretch (expected - no real touch pending),
    @ the gated I2C transaction never runs and r4 never gets overwritten, so every repeated "S:00000000" report
    @ during idle may have just been re-displaying that untouched initial placeholder, not a real, successful
    @ 0x00 read - meaning there may be NO actual evidence yet that a real query of this device EVER returns
    @ anything but 0xFF. Forcing the real transaction every attempt, unconditionally, tests this directly.
    ldr r0, =GPIOF_DR
    ldr r1, [r0]
    lsrs r1, r1, #TOUCH_INT_PIN
    ands r1, r1, #1
    @ cmp r1, #0
    @ bne .wti_int_idle                     @ disabled for this test

    movs r9, #0                              @ reset the "any NACK this attempt" flag
    bl i2c_start
    movs r0, #0xBA                          @ GT911 write address
    bl i2c_write_byte
    bl i2c_wait_ack
    orrs r9, r9, r0
    movs r0, #0x81                          @ register 0x814E, high byte
    bl i2c_write_byte
    bl i2c_wait_ack
    orrs r9, r9, r0
    movs r0, #0x4E                          @ register 0x814E, low byte
    bl i2c_write_byte
    bl i2c_wait_ack
    orrs r9, r9, r0
    bl i2c_stop
    bl i2c_start
    movs r0, #0xBB                          @ GT911 read address
    bl i2c_write_byte
    bl i2c_wait_ack
    orrs r9, r9, r0
    bl i2c_read_byte
    mov r4, r0                              @ r4 = status byte
    lsrs r0, r4, #7                         @ bit 7 (data ready) -> bit 0
    tst r0, #1
    beq .wti_status_only                    @ no data ready: NACK the status byte and stop, same as before

    @ data ready: finish this transaction (NACK + stop), then - TEMPORARY DIAGNOSTIC - instead of trusting an
    @ assumed x_lo/x_hi/y_lo/y_hi register layout (0x8150..0x8153), which a hardware test showed reading back a
    @ suspicious uniform 0xFFF/0xFFF (a known GT911 "no valid data" sentinel, not plausible real coordinates) even
    @ via the already-proven-reliable single-register read shape - dump registers 0x814E..0x815F raw over UART
    @ (each line "D:0000rrvv", rr = register low byte, vv = value) so the real coordinate bytes can be found
    @ empirically (by comparing dumps from taps at different screen locations) instead of assumed from a
    @ (possibly mis-identified) offset. r10/r11 (x/y) are left at 0 for this diagnostic build - the on-screen
    @ X/Y line is not meaningful until this comes back and the real offsets are confirmed.
    bl i2c_send_nack
    bl i2c_stop
    @ CORRECTED after a hardware test showed EVERY register in the dump range reading back a uniform 0xFF,
    @ including 0x814E itself (which idle polling reads as a clean, real 0x00 over and over) - the classic
    @ floating/unanswered-bus signature, not real data, even though the very first status read in this same loop
    @ iteration got a real answer. The two reads are back-to-back with no gap; idle polling's reads are naturally
    @ spaced out by the rest of the loop's own work. Guessing the GT911 needs a short recovery time after being
    @ queried before it will answer a second, closely-spaced transaction - add a real (timer-measured, not
    @ instruction-count) gap before and between these diagnostic reads to test that theory.
    timer_delay_ticks 1000                   @ ~2 ms at this section's 500 kHz tick
    movs r5, #0x4E                           @ register low byte, starting at the status register itself
.wti_regdump_loop:
    timer_delay_ticks 1000                   @ same settle gap before every subsequent read in the dump
    movs r0, #0x81
    mov r1, r5
    bl i2c_read_reg8
    mov r4, r0                               @ value
    lsls r0, r5, #8
    orrs r0, r0, r4                          @ combined: reg_lo in bits [15:8], value in bits [7:0]
    movs r1, #0x44                           @ 'D' = diagnostic register-dump line
    ldr r2, =TEXT_BUF
    bl hex_line
    ldr r0, =TEXT_BUF
    bl uart_puts
    movs r0, #0x0D
    bl uart_putc
    movs r0, #0x0A
    bl uart_putc
    adds r5, r5, #1
    cmp r5, #0x60
    blo .wti_regdump_loop
    movs r10, #0
    movs r11, #0
    b .wti_touched

.wti_status_only:
    bl i2c_send_nack                        @ only the status byte, no point data: NACK, not ACK
    bl i2c_stop
.wti_int_idle:
    iwdg_feed                               @ the longest-running loop in this file - feed every attempt, not just
                                           @   once per batch, so normal polling (even if slow) never trips it

    @ elapsed-time check: TIM5 counts up to TOUCH_TIMER_ARR then wraps to 0, same wrap-detection idea as the
    @ melody's own "wait" loop above (a drop in the raw counter value means exactly one wrap happened, since
    @ this is polled far more often than once per 32.768 ms period).
    ldr r0, =(TIM5_BASE + TIM_CNT)
    ldr r1, [r0]
    cmp r1, r7
    bhs .wti_no_wrap
    adds r8, r8, #1
.wti_no_wrap:
    mov r7, r1
    ldr r0, =TOUCH_TIMEOUT_WRAPS
    cmp r8, r0
    bhs .wti_timeout

    subs r5, r5, #1
    bne .wti_loop
    movs r1, #0x53                          @ 'S' = still waiting, this is just a periodic status refresh
    movs r6, #0                              @ keep polling after this report
    b .wti_report
.wti_touched:
    movs r1, #0x4B                          @ 'K' = real touch seen
    movs r6, #2                              @ return after this report, and also show the X/Y line below
    b .wti_report
.wti_timeout:
    movs r1, #0x58                          @ 'X' = gave up after TOUCH_TIMEOUT_MS with no real touch
    movs r6, #1                              @ return after this report, no X/Y (no real touch happened)
.wti_report:
    ldr r0, =TOUCH_DEBUG_Y0
    bl clear_touch_debug                    @ erase the previous frame first - see the function's own comment
    lsls r0, r9, #31                        @ bit31 = any-NACK flag, bits7:0 = raw status byte - see the function
    orrs r0, r0, r4                         @   header comment for how to read this
    ldr r2, =TEXT_BUF
    bl hex_line
    ldr r0, =TEXT_BUF
    ldr r1, =TEXT_X0
    ldr r2, =TOUCH_DEBUG_Y0
    bl draw_text
    uart_dump_buf

    cmp r6, #2
    bne .wti_no_xy_report                   @ only a real touch (r6==2) has point data to show
    ldr r0, =LOOPBACK_Y0                    @ CORRECTED: this line used to be drawn without clearing it first,
    bl clear_touch_debug                    @   garbling on top of the one-time loopback test's leftover digits
    lsls r0, r10, #16                        @ combined display value: x in the high 16 bits, y in the low -
    orrs r0, r0, r11                         @   "X:0abc0def" reads as x=0xabc, y=0xdef (each 12 bits, so the
    movs r1, #0x58                           @   top nibble of each half is always 0) - 'X' label for "coordinates"
    ldr r2, =TEXT_BUF
    bl hex_line
    ldr r0, =TEXT_BUF
    ldr r1, =TEXT_X0
    ldr r2, =LOOPBACK_Y0                     @ reuse this line - the one-time loopback test already shown earlier
    bl draw_text
    uart_dump_buf
.wti_no_xy_report:

    cmp r6, #0
    beq .wti_outer                          @ batch refresh only: keep polling

    @ hold the final report on screen for TOUCH_REPORT_HOLD_MS before returning - see that equ's comment
    @ BUG FIXED: this loop used to spin for the full TOUCH_REPORT_HOLD_MS (10000 ms) with no iwdg_feed at
    @ all, racing IWDG_RLR_VAL's own ~10.0s timeout - a successful touch report (the one case this whole
    @ watchdog exists to protect, not undermine) could get its own display cut off by a watchdog reset.
    @ Feed every iteration (cheap: a register read + compare). iwdg_feed clobbers r0/r1, so the running
    @ state that must survive the call lives in r2/r4/r6 instead (r6's earlier "report kind" value is no
    @ longer needed once control reaches here - see the branch just above).
    ldr r4, =(TIM5_BASE + TIM_CNT)
    ldr r6, [r4]                             @ previous sample
    movs r2, #0                              @ wrap count
.wti_hold:
    ldr r3, [r4]
    cmp r3, r6
    bhs .wti_hold_no_wrap
    adds r2, r2, #1
.wti_hold_no_wrap:
    mov r6, r3
    ldr r3, =TOUCH_REPORT_HOLD_WRAPS
    cmp r2, r3
    iwdg_feed                                @ does not touch flags (ldr/str), the blo below still sees the cmp above
    blo .wti_hold

    pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}

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
