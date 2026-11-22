/* cmd_poke.S - the poke handler of the nana console (included by cmd.S inside the
 * .peekblob section, the same translation unit, no .globl / no section switches).
 *
 * Wire (the binary nana protocol - spec in .operator/specs/nana_protocol.md):
 *   request  "nana [u32 size][2][u32 addr][data...][u32 crc32] " FF FF FF
 *   reply    "chi!" [u32 0][u32 crc32 of the empty payload] FF FF FF 00 FF FF FF
 *
 * The data is validated (length cap) BEFORE any store - no partial writes on a bad
 * request - then written byte by byte to <addr> (the address increments per byte).
 * The data length cap is the RX-ring line bound, not an arbitrary constant: the nana
 * request line must fit the committed 4096-byte RX frame (see NANA_MAX_DATA in
 * tools/screen_probe.py for the derivation), so
 *
 *   data bytes <= 4045  (= NANA_MAX_DATA - 4 (the addr))
 *
 * and the host chunks a longer poke transparently (it advances the address per chunk).
 *
 * Bench truth (stock pass, corrected 2026-11-12): ALL RAM is poke-writable - the SDRAM
 * arena 0x0-0x1000000 (16 MB) and SRAM0 0x20000000. The 2026-11-06 "only SRAM0 writable,
 * other stores dropped" line was a false negative: only 0x20000000 was ever positively
 * tested, and the 2026-11-07 0x650000 arena poke persisted and read back byte-for-byte on
 * a fresh console. Not writable via poke: flash XIP (0x10000000 / 0xE0000000, stores
 * silently dropped) and the 0x40000000 IO/peripheral region (some VOUT registers are
 * read-only).
 *
 * Entry (branched to from pb_nana's dispatch in cmd.S; sp is the pb_nana frame top - must
 * be preserved exactly; see cmd_peek.S):
 *   r4 = ptr to [u32 size][cmd][args][u32 crc32] (args: [u32 addr][data] from r4+5)
 *   r5 = the u32 size (intact)
 *   r7 = 1 + args byte count (1 + 4 + data) - the data count is r7 - 5
 *
 * This file references only cmd.S symbols (pb_nana_done, pb_nana_err, pb_nana_reply) and
 * its own locals - nothing from cmd_peek.S / cmd_fun.S. */

.thumb_func
pb_nana_poke:
    ldr r5, [r4, #5]                   // r5 = addr
    sub r7, r7, #5                     // r7 = data byte count (args = addr + data)
    cmp r7, #0
    beq pb_nana_err                    // no data
    movw r0, #4045
    cmp r7, r0
    bhi pb_nana_err                    // > 4045 bytes (the RX-ring line bound)
    add r6, r4, #9                     // r6 = ptr to the data
.pb_nana_poke_loop:
    ldrb r0, [r6]
    strb r0, [r5]
    add r5, r5, #1
    add r6, r6, #1
    subs r7, r7, #1
    bne .pb_nana_poke_loop
    // Reply: empty payload (len 0, crc32 of the empty data = 0)
    movs r0, #0
    movs r1, #0
    bl pb_nana_reply
    b pb_nana_done
    .ltorg
