/*
 * stage1 diagnostic loader: plays a short "ta-daa" on the board buzzer on entry, then returns
 * to the stage-0 loader.
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

.equ ENCLK0_GPIO,     (1 << 1)             @ GPIO block clock (probably already on, set again to be sure)
.equ ENCLK2_TIM5,     (1 << 20)            @ TIM5 clock
.equ IPSWRST2_TIM5,   (1 << 20)            @ TIM5 reset bit

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

.section .vector_table
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

    @ ---- play the melody ----
    @ The stack is the loader's (MSP = 0x20000648, vector word 0): pushing below it is safe.
    push {r4, r5}                          @ callee-saved: r5 = pointer into the table, r4 = safety timeout
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
    bx lr

/* "ta-daa": a short note, a gap, then a longer one a fifth higher (C6 -> G6; a piezo is loudest around 2-4 kHz, so
 * the notes are kept high). Edit the table to change the tune; keep the total image below 0x1C8 bytes. */
.align 2
melody:
    note 1047, 110        @ "ta"   C6
    rest 40
    note 1568, 520        @ "daa"  G6
    .word 0               @ end of the melody
