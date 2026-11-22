/* cmd_fun.S - the fun/fur handlers of the nana console (included by cmd.S inside the
 * .peekblob section, the same translation unit, no .globl / no section switches).
 *
 * Wire (the binary nana protocol - spec in .operator/specs/nana_protocol.md):
 *   fun  request  "nana [u32 size][3][u32 addr][u32 a0]?[u32 a1]?[u32 crc32] " FF FF FF
 *        reply    "chi!" [u32 0][u32 crc32 of the empty payload] FF FF FF 00 FF FF FF
 *   fur  request  same as fun
 *        reply    "chi!" [u32 4][u32 r0 LE][u32 crc32] FF FF FF 00 FF FF FF
 *
 *   <addr>: the code to run, called with blx (pass the exact, odd/Thumb, address of the
 *           function - the value is NOT dereferenced; no window check - a bad address
 *           faults). AAPCS: r0 = a0, r1 = a1; absent args are 0.
 *   fun discards the return; fur echoes r0 (the AAPCS return register).
 *   The args byte count is 0, 4, or 8 (after the addr) - anything else is a protocol
 *   error (the 1-byte 0xFF payload reply).
 *
 * Neither handler pushes a frame: nothing is live across the blx except sp (AAPCS
 * preserves it) and r0, which fur captures straight after the call - so sp stays at the
 * pb_nana frame top for the whole handler and the pb_nana terminal pop unwinds it (see
 * the entry contract in cmd_peek.S). The callee clobbers r0-r3/r12/lr per AAPCS, but the
 * only post-call value used is r0 (fur stashes it in the ENTRY frame's r0 slot, [sp,#20]
 * above the pb_nana frame - NOT this frame's slot: pb_nana_reply's [sp,#24] store lands
 * on the pb_nana frame's r7 slot and would clobber it; see pb_nana_err in cmd.S, which
 * uses the same slot for the 0xFF sentinel).
 *
 * Entry (branched to from pb_nana's dispatch in cmd.S; sp is the pb_nana frame top):
 *   r4 = ptr to [u32 size][cmd][args][u32 crc32] (args: [u32 addr][a0?][a1?] from r4+5)
 *   r5 = the u32 size (intact)
 *   r7 = 1 + args byte count - the args-after-addr count is r7 - 5 (0, 4, or 8)
 *
 * This file references only cmd.S symbols (pb_nana_done, pb_nana_err, pb_nana_reply) and
 * its own locals - nothing from cmd_peek.S / cmd_poke.S. */

.thumb_func
pb_nana_fun:
    ldr r5, [r4, #5]                   // r5 = blx target (the value is not dereferenced)
    sub r6, r7, #5                     // r6 = args-after-addr byte count (0, 4, or 8)
    cmp r6, #0
    beq .pb_nana_fun_noargs
    cmp r6, #4
    beq .pb_nana_fun_a0                // a0 only
    cmp r6, #8
    beq .pb_nana_fun_a1                // a0 + a1
    b pb_nana_err                      // any other count: protocol error
.pb_nana_fun_noargs:
    movs r0, #0                        // each block is self-contained: a beq lands on its first
    movs r1, #0                        // instruction, so no block may fall through into the next
    b .pb_nana_fun_call
.pb_nana_fun_a0:
    ldr r0, [r4, #9]                   // r0 = a0
    movs r1, #0
    b .pb_nana_fun_call
.pb_nana_fun_a1:
    ldr r0, [r4, #9]                   // r0 = a0
    ldr r1, [r4, #13]                  // r1 = a1
.pb_nana_fun_call:
    blx r5                             // clobbers r0-r3/r12/lr; sp preserved (AAPCS)
    // Reply: empty payload (the return is discarded)
    movs r0, #0
    movs r1, #0
    bl pb_nana_reply
    b pb_nana_done
    .ltorg

.thumb_func
pb_nana_fur:
    ldr r5, [r4, #5]
    sub r6, r7, #5
    cmp r6, #0
    beq .pb_nana_fur_noargs
    cmp r6, #4
    beq .pb_nana_fur_a0
    cmp r6, #8
    beq .pb_nana_fur_a1
    b pb_nana_err
.pb_nana_fur_noargs:
    movs r0, #0                        // self-contained blocks (same layout rule as pb_nana_fun)
    movs r1, #0
    b .pb_nana_fur_call
.pb_nana_fur_a0:
    ldr r0, [r4, #9]
    movs r1, #0
    b .pb_nana_fur_call
.pb_nana_fur_a1:
    ldr r0, [r4, #9]
    ldr r1, [r4, #13]
.pb_nana_fur_call:
    blx r5                             // r0 = the return value
    str r0, [sp, #20]                 // the ENTRY frame's r0 slot (dead - see the header)
    add r0, sp, #20
    movs r1, #4
    bl pb_nana_reply                   // [u32 4][u32 r0 LE][crc32]
    b pb_nana_done
    .ltorg
