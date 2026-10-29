/*
 * Super-minimal stage1 diagnostic loader: entry() is a single `bx lr`.
 *
 * Purpose: isolate whether the stage1 image itself "takes over" the boot /
 * kills the interpreter, from the buzzer timer code. With only `bx lr` at the
 * entry there is nothing to drive the buzzer or hang — we just watch what the
 * device does after the stage-0 loader hands control.
 *
 * Entry path: the loader runs this image via ldr_exec's `BLX struct[4]`
 * (struct[4] = this entry). The return address from that BLX sits in LR, so a
 * single `bx lr` hands control straight back to the loader — no stack access,
 * no reliance on a reset-vector stack frame. `bx` (not `mov pc`) is used
 * because BLX sets the Thumb bit in LR and `bx` clears it; `mov pc, lr` would
 * leave it set and jump to the wrong state.
 *
 * The vector table still holds MSP + a reset slot so the image is a valid
 * vector-table image the loader can VTOR to and read SP from. Pure assembly
 * (same reason tools/sdboot.S is asm).
 */

.syntax unified
.thumb

.section .text
.global entry
.thumb_func
entry:
    bx lr

.section .rodata
.section .bss
