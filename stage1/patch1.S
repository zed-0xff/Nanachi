/* site1: the 24-byte loader patch for ldr_call (0x200015c4..0x200015db). Assembled by
 * build.py's 2nd pass and spliced into stage1.S's patch_blob (bytes 0..23).
 * See the big comment above install_entry_hook in stage1.S for the design.
 *
 *   0x15c4  7 x NOP      - kills the original VTOR write (0x15c4..0x15cb: BIC.W/LDR/STR), the
 *                          MOV r0,r4 (0x15cc..0x15cd) and the original 4-byte BL.W ldr_exec_
 *                          (0x15ce..0x15d1). Execution falls through the NOPs into the tail.
 *   0x15d2  mov r0, r4   - r4 is ldr_call's a1 (0x80000, the image address, on the SD pass);
 *                          it is set in ldr_call's prologue (not NOPed) and preserved across
 *                          the fall-through. Restores the original BL.W's argument.
 *   0x15d4  ldr r1, [pc,#0]  r1 = the literal word at 0x15d8 = 0x20001de1 (ldr_exec_ in
 *                          loader RAM, Thumb bit set for blx). A pool literal, NOT movw/movt
 *                          (both 32-bit) and NOT the old mov/lsl/add 3-instr sequence, which
 *                          only builds the 16-bit value 0x1de1 and dropped the 0x2000 word -
 *                          that is the bug this rewrite fixes.
 *   0x15d6  blx r1       - re-runs ldr_exec_; site2 detours its blx into entry_trampoline.
 *                          The blx return (0x15d8) is never taken - the trampoline epilogue
 *                          returns to ldr_main instead.
 *   0x15d8  .word 0x20001DE1  pool literal. The slot originally held 0xe000ed08 (SCB->VTOR),
 *                          read only by the now-NOPed LDR at 0x15c8, so it is free to reuse.
 *
 * The one literal pool is at a FIXED offset within the blob (0x15d8 = byte 20) and the LDR is
 * at byte 16, so the PC-relative distance (0x4) is a constant no matter where build.py splices
 * the 24 bytes; the blob assembles to the same 24 bytes at any base address. build.py asserts
 * the size.
 */
.thumb
.text

    nop                       @ 0x15c4
    nop                       @ 0x15c6
    nop                       @ 0x15c8
    nop                       @ 0x15ca
    nop                       @ 0x15cc
    nop                       @ 0x15ce
    nop                       @ 0x15d0
    mov r0, r4                @ 0x15d2
    ldr r1, [pc, #0]          @ 0x15d4  -> pool at 0x15d8
    blx r1                    @ 0x15d6
    .word 0x20001DE1          @ 0x15d8..0x15db
