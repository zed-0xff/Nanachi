/*
 * buzz_blob.c — C port of buzz_blob.S (snippets/poke-and-run.asm): plays a
 * short "ta-daa" on the board's TIM5 buzzer, then returns to the caller.
 * Same register map, same note values, same timer-based note timing — only
 * the implementation language differs, which is the point of this snippet:
 * C-compiled code poked into SDRAM and blx'd on the live panel.
 *
 * Consequences of the blx-only execution model (see README.md):
 *   - no boot, no vector table, no SP setup: the 0x2A1E console blob blx's
 *     here on the stock stack and the C epilogue (pop {r7, pc}) is the
 *     `bx lr` the assembly version does by hand;
 *   - absolute link at 0x650000: the code and the data reference each other
 *     and the peripherals with 32-bit absolute addresses; a blx to any other
 *     address breaks the blob;
 *   - freestanding: no libc, no malloc, no FPU. The only stack delta is this
 *     function's own frame, on top of whatever SP the blx left.
 */

#include <stdint.h>

/* ==========================================================================
 *  Register map (identical to buzz_blob.S; source: the BSP in
 *  ext/SoC/BPI-EAI80-bsp, checked against the stock firmware's own `beep`
 *  command (cmd_beep / cfgpio_apply / TIM5 setup) in the IDB)
 * ========================================================================== */

/* ---- SYS block (0x40000000): clocks, resets and pin multiplexing ---- */
#define SYS_BASE         0x40000000u
#define SYS_IPSWRST2     (SYS_BASE + 0x078u)  /* bit 20 = TIM5; 0 = held in reset, 1 = running */
#define SYS_ENCLK0       (SYS_BASE + 0x080u)  /* bit 1 = GPIO clock */
#define SYS_ENCLK2       (SYS_BASE + 0x088u)  /* bit 20 = TIM5 clock */
#define SYS_IOODC4       (SYS_BASE + 0x248u)  /* open-drain enable; port I in bits 0..15 */
#define SYS_IOPULLUP4    (SYS_BASE + 0x278u)  /* pull-up enable; same layout as IOODC4 */
#define SYS_IOPULLDOWN4  (SYS_BASE + 0x290u)  /* pull-down enable; same layout as IOODC4 */
#define SYS_IOMODE8      (SYS_BASE + 0x2E4u)  /* port I: 2 bits per pin (0 = GPIO, 1 = AF, 3 = analog) */
#define SYS_IOAFR16      (SYS_BASE + 0x330u)  /* port I pins 0..7: 4-bit AF number per pin */

#define ENCLK0_GPIO      (1u << 1)
#define ENCLK2_TIM5      (1u << 20)
#define IPSWRST2_TIM5    (1u << 20)

/* ---- buzzer pin: IO7 = GPIOI pin 3 = TIM5_CH4 (AF5) ----
 * Port I is the lower half of its pull/open-drain register pair, so the pin
 * number is used directly as the bit (port J would be shifted by 16). */
#define BUZZER_PIN         3u
#define BUZZER_PIN_MASK    (1u << BUZZER_PIN)
#define BUZZER_IOMODE_MASK (3u << (2 * BUZZER_PIN))
#define BUZZER_IOMODE_AF   (1u << (2 * BUZZER_PIN))
#define BUZZER_AFR_MASK    (0xFu << (4 * BUZZER_PIN))
#define BUZZER_AFR_TIM5    (5u << (4 * BUZZER_PIN))
#define GPIOI_OMCR         0x40019010u        /* GPIOI 0x40019000 + 0x10: output mode control */

/* ---- TIM5 (0x40007400), STM32-like layout ---- */
#define TIM5_BASE  0x40007400u
#define TIM_CR1    (TIM5_BASE + 0x00u)        /* bit 0 = counter enable */
#define TIM_CCMR1  (TIM5_BASE + 0x18u)        /* OC modes of channels 1, 2 */
#define TIM_CCMR2  (TIM5_BASE + 0x1Cu)        /* OC modes of channels 3, 4 */
#define TIM_CCER   (TIM5_BASE + 0x20u)        /* output enable + polarity, 4 bits per channel */
#define TIM_CNT    (TIM5_BASE + 0x24u)        /* counter: 0..ARR then wrap (one wrap = one period) */
#define TIM_PSC    (TIM5_BASE + 0x28u)        /* tick = clock / (PSC + 1) */
#define TIM_ARR    (TIM5_BASE + 0x2Cu)        /* period in ticks */
#define TIM_CCR4   (TIM5_BASE + 0x40u)        /* channel 4 pulse width in ticks */

#define TIM_PSC_VAL   99u                     /* 200 MHz / 100 = 2 MHz tick */
#define TIM_HZ        2000000u                /* tick rate after the prescaler */
#define WAIT_TIMEOUT  30000000u               /* per-note safety bound if the counter never moves */

/* ==========================================================================
 *  Register access
 * ========================================================================== */

static inline uint32_t rd32(uint32_t addr) { return *(volatile uint32_t *)addr; }
static inline void wr32(uint32_t addr, uint32_t val) { *(volatile uint32_t *)addr = val; }

/* Read-modify-write: *addr = (*addr & ~clr) | set. */
static inline void rmw(uint32_t addr, uint32_t clr, uint32_t set)
{
    wr32(addr, (rd32(addr) & ~clr) | set);
}

/* ==========================================================================
 *  Melody table
 * ========================================================================== */

/*
 * One entry per note, three words: periods, ARR, CCR4 — the same layout the
 * assembly table uses:
 *   periods = ms * hz / 1000  PWM periods the note lasts (counted from
 *                             TIM5_CNT wrap-arounds)
 *   ARR     = TIM_HZ / hz     ticks per period
 *   CCR4    = ARR / 2         50% duty (0 = silence: a rest)
 * A zero word ends the table.
 */
typedef struct { uint32_t periods, arr, ccr4; } note_t;

#define NOTE(hz, ms) { (uint32_t)(ms) * (hz) / 1000u, TIM_HZ / (hz), TIM_HZ / (hz) / 2u }
#define REST(ms)     { (uint32_t)(ms), TIM_HZ / 1000u, 0u }

static const note_t melody[] = {
    NOTE(1047, 110),   /* "ta"  C6 */
    REST(40),
    NOTE(1568, 520),   /* "daa" G6 */
    { 0, 0, 0 },
};

/* ==========================================================================
 *  entry
 * ========================================================================== */

/*
 * blx target (0x650001). Runs on the caller's SP; returns via the standard
 * C epilogue, which is the `bx lr` the assembly version does by hand.
 */
void entry(void)
{
    /* 1. Enable the GPIO and TIM5 clocks: a peripheral with its clock off
     *    ignores register writes, so this has to come first. */
    rmw(SYS_ENCLK0, 0, ENCLK0_GPIO);
    rmw(SYS_ENCLK2, 0, ENCLK2_TIM5);

    /* 2. Pulse the TIM5 software reset (active low): known state, whatever
     *    the stock firmware or a previous run left behind. */
    rmw(SYS_IPSWRST2, IPSWRST2_TIM5, 0);
    rmw(SYS_IPSWRST2, 0, IPSWRST2_TIM5);

    /* 3. Pin PI3: alternate function 5 (TIM5_CH4), no pulls, push-pull. */
    rmw(SYS_IOMODE8, BUZZER_IOMODE_MASK, BUZZER_IOMODE_AF);
    rmw(SYS_IOAFR16, BUZZER_AFR_MASK, BUZZER_AFR_TIM5);
    rmw(SYS_IOPULLUP4, BUZZER_PIN_MASK, 0);
    rmw(SYS_IOPULLDOWN4, BUZZER_PIN_MASK, 0);
    rmw(SYS_IOODC4, BUZZER_PIN_MASK, 0);
    wr32(GPIOI_OMCR, BUZZER_PIN_MASK);

    /* 4. TIM5: PWM on CH4 (everything except the note-specific ARR/CCR4). */
    wr32(TIM_CR1, 0);            /* stopped while configuring */
    wr32(TIM_PSC, TIM_PSC_VAL);
    wr32(TIM_CCMR1, 0x7070);     /* OCxM = 0b111 (PWM mode 2) */
    wr32(TIM_CCMR2, 0x7070);
    wr32(TIM_CCER, 0x3333);      /* all four channels enabled, polarity bit set */

    /* 5. Play the melody. Note length is measured with the timer itself
     *    (TIM5_CNT wrap-arounds, one per PWM period), not with a delay
     *    loop: the blob runs from SDRAM where fetches are slow, so a loop
     *    calibrated for 200 MHz would take several times too long. */
    for (const note_t *n = melody; n->periods != 0; n++) {
        wr32(TIM_CR1, 0);
        wr32(TIM_CNT, 0);        /* with a smaller new ARR a counter above it
                                   would otherwise run on to 0xFFFF first */
        wr32(TIM_ARR, n->arr);
        wr32(TIM_CCR4, n->ccr4);
        wr32(TIM_CR1, 1);        /* go */

        uint32_t prev = 0;
        uint32_t left = n->periods;
        uint32_t timeout = WAIT_TIMEOUT;
        for (;;) {
            uint32_t cnt = rd32(TIM_CNT);
            if (cnt < prev) {    /* counter wrapped: one more period done */
                left--;
                if (left == 0)
                    break;
            }
            prev = cnt;
            if (--timeout == 0)  /* safety: the counter does not run */
                break;
        }
    }

    /* 6. Stop the timer. The pin stays configured as TIM5_CH4; with the
     *    counter stopped the output stops toggling. */
    wr32(TIM_CR1, 0);
}
