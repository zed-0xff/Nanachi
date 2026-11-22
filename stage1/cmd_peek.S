/* cmd_peek.S - the peek handler of the nana console (included by cmd.S inside the
 * .peekblob section, the same translation unit, no .globl / no section switches).
 *
 * Wire (the binary nana protocol - spec in .operator/specs/nana_protocol.md):
 *   request  "nana [u32 size][1][u32 addr][u32 n][u32 crc32] " FF FF FF
 *   reply    "chi!" [u32 n][n raw memory bytes][u32 crc32] FF FF FF 00 FF FF FF
 *            (the "chi!" prefix is the entry beacon; the trailing 00 FF FF FF is the
 *            stock's own line terminator after pb_exit)
 *
 * No window gating (removed per user request; cmd.S documents the former windows) and no
 * size cap: the reply goes out the raw UART2 TX (pk_marker), not through the RX ring, so a
 * single peek may be arbitrarily long - the host chunks long shots for transport
 * convenience (SHOT_CHUNK in tools/screen_probe.py), not because of the blob.
 *
 * Entry (branched to from pb_nana's dispatch in cmd.S; sp is the pb_nana frame top - must
 * be preserved exactly; only the pb_nana frame, and the entry frame beneath it, may be
 * unwound, each by its own terminal pop):
 *   r4 = ptr to [u32 size][cmd][args][u32 crc32] (the payload base; args start at r4+5)
 *   r5 = the u32 size (intact across pb_crc32, which saves its own r4)
 *   r6 = the stored crc32 (intact; unused here)
 *   r7 = 1 + args byte count (intact; unused here)
 *
 * This file references only cmd.S symbols (pb_nana_done, pb_nana_reply) and its own locals
 * - nothing from cmd_poke.S / cmd_fun.S. */

.thumb_func
pb_nana_peek:
    ldr r5, [r4, #5]                   // r5 = addr
    ldr r6, [r4, #9]                   // r6 = n (byte count; no cap - see the header)
    movs r0, r5                        // r0 = data ptr
    movs r1, r6                        // r1 = data len
    bl pb_nana_reply
    b pb_nana_done
    .ltorg
