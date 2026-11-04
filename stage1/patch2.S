/* site2: the 8-byte loader patch for ldr_exec_'s jump (0x20001df6..0x1dfd). build.py's 2nd
 * pass substitutes the TRAMP marker (the in-image entry_trampoline address, Thumb bit set)
 * with a hex literal and assembles the result; the blob is spliced into stage1.S's patch_blob
 * (bytes 24..31). The window originally holds:
 *
 *   0x1df6  LDR  R0, =ldr_last_dst   literal 0x20000010 at 0x1e00 (still referenced by 0x1de8 -
 *                                    do not touch it)
 *   0x1df8  LDR  R0, [R0]
 *   0x1dfa  BLX  R0                  jumps the image's reset-vector word
 *   0x1dfc  MOVS R0, #0              only reached if the target RETURNS
 *
 * and is replaced by:
 *
 *   0x1df6  mov r0, #hi  \
 *   0x1df8  lsl r0, #12  |  r0 = TRAMP - all 16-bit insns, because movw/movt are 32-bit
 *   0x1dfa  add r0, #lo  /  and don't fit the 8-byte window. hi = bits 12..23 of TRAMP fits
 *   0x1dfc  blx r0          the 8-bit mov for any TRAMP below 0x1000000; lo = bits 0..11 must
 *                           be <= 0xFF, because this GAS builds no 12-bit 16-bit ADD imm
 *                           (16-bit ADD immediate is 8-bit only, else ADD.W). stage1.S keeps
 *                           entry_trampoline 0x1000-aligned (.align 12), so lo = 1 always;
 *                           build.py asserts the range and fails the build otherwise.
 *
 * Every post-patch ldr_exec_ jump (the ldr_call tail's re-run for the stock call) lands in the
 * trampoline. The FIRST call's blx (the original 0x1dfa) also returns to 0x1dfc - now a `blx
 * r0` - but entry's cold pass no longer `bx lr`s there: it exits directly into
 * entry_trampoline (see entry's tail), so the 0x1dfc blx never executes with entry's leftover
 * r0 (= HOOK_DONE_ADDR: even -> ARM mode, and the magic word stored there is an undefined ARM
 * instruction -> HardFault; the m2c/m2d failure mode this rewrite removes).
 *
 * No ranged branches and no literal pools, so every encoding here is location-independent and
 * this file assembles to the same 8 bytes at any address; build.py asserts the size.
 */
.thumb
.text

    mov  r0, #(TRAMP >> 12)
    lsl  r0, r0, #12
    add  r0, #(TRAMP & 0xFFF)
    blx  r0
