/* cmd_poke.S - the poke function of the 0x2A1E command blob (included by cmd.S inside the
 * .peekblob section, the same translation unit, no .globl / no section switches).
 *
 * Syntax: poke <addr>,<N><hex data>
 *   addr:  hex, 0x optional (peek grammar; mirrors the peek addr parse byte-for-byte)
 *   N:     decimal 1..POKE_MAX_LEN (255) - the byte count
 *   data:  exactly 2N hex digits (an optional space or comma may separate N from the
 *         data; no spaces inside the data)
 * Behavior: the FULL data is validated before any store (no partial writes on bad input).
 *   success: NO reply frame (one 0x5A beacon only, like every 0x2A1E hit) - the write
 *            happens, then the stock's 00 ack follows; the host verifies with a peek.
 *   error:   72 FF FF FF (bad syntax / short data / N > 255),
 *            then the stock's 00 ack.
 * Bench truth (2026-11-06, stock pass): only W2 (SRAM0, 0x20000000) is writable; stores into
 * W3 (PSRAM) / W4 / W1 (flash) are silently dropped (no fault, no IWDG).
 *
 * Called with bl from peekblob_entry (cmd.S). `bl` does not push a frame, so sp is the entry
 * frame (peekblob_entry's push {r0-r7,lr}) throughout and pb_poke leaves it untouched for the
 * terminal pop. It uses r7 = the field start, which the entry already computed (r5 +
 * *(u16*)r6) and which the bl preserves - no stack re-read (see the pb_peek header). Register
 * plan after the parse: r4 = addr, r5 = N, r6 = data
 * start, r2 = data end.
 *
 * This file references only cmd.S symbols (pb_exit, pb_exit_err, pk_marker,
 * pk_hex_table) and its own locals - nothing from cmd_peek.S. */

.equ POKE_MAX_LEN, 255

.thumb_func
pb_poke:
    // sp is the entry frame (peekblob_entry's push {r0-r7,lr}); `bl` does NOT push a frame,
    // so there is nothing to discard here - sp must stay at the entry frame
    // for the terminal pop in pb_exit. r7 = the field start (the 'p' of "poke"), set by the
    // entry and preserved across the bl (the bl clobbers only lr). No stack re-read needed.
    add r7, r7, #5                     // r7 = just past "poke " (the addr start)
    // ---- addr: the peek grammar (0x optional, hex, comma-terminated).
.np_addr_spaces:
    ldrb r0, [r7]
    cmp r0, #' '
    beq .np_addr_spaces_skip
    cmp r0, #'0'
    bne .np_hex
    ldrb r1, [r7, #1]
    cmp r1, #'x'
    beq .np_hex_skip
    cmp r1, #'X'
    beq .np_hex_skip
    b .np_hex
.np_addr_spaces_skip:
    add r7, r7, #1                     // advance (a beq-without-advance = infinite loop)
    b .np_addr_spaces
.np_hex_skip:
    add r7, r7, #2
.np_hex:
    movs r0, #0
.np_hex_loop:
    ldrb r2, [r7]
    cmp r2, #','
    beq .np_have_addr
    adr r3, pk_hex_table               // PC-relative, in-blob: coherent after the word-copy
    ldrb r1, [r3, r2]
    cmp r1, #0xFF
    beq .np_err
    lsl r0, r0, #4
    add r0, r0, r1
    add r7, r7, #1
    b .np_hex_loop
.np_have_addr:
    mov r4, r0                         // r4 = addr
    add r7, r7, #1                     // past the ','
    // ---- N: decimal 1..POKE_MAX_LEN (an optional space/comma may precede it).
.np_n_pre:
    ldrb r0, [r7]
    cmp r0, #' '
    beq .np_n_pre_skip
    cmp r0, #','
    beq .np_n_pre_skip
    cmp r0, #'0'
    blt .np_err
    cmp r0, #'9'
    bgt .np_err
    movs r5, #0
.np_n_loop:
    ldrb r2, [r7]
    cmp r2, #','
    beq .np_have_n
    cmp r2, #' '
    beq .np_have_n
    cmp r2, #'0'
    blt .np_err
    cmp r2, #'9'
    bgt .np_err
    sub r2, r2, #'0'                   // ASCII -> digit value (the old raw-byte add made N wrong)
    lsl r1, r5, #3                     // r5 * 10 = r5*8 + r5*2
    lsl r5, r5, #1
    add r5, r5, r1
    add r5, r5, r2
    add r7, r7, #1
    b .np_n_loop
.np_n_pre_skip:
    add r7, r7, #1                     // advance (a beq-without-advance = infinite loop)
    b .np_n_pre
.np_have_n:
    cmp r5, #0
    beq .np_err                        // no digit: N missing
    cmp r5, #POKE_MAX_LEN
    bhi .np_err
    // ---- data: exactly 2N hex digits; an optional space/comma may precede it.
.np_data_pre:
    ldrb r0, [r7]
    cmp r0, #' '
    beq .np_data_pre_skip
    cmp r0, #','
    beq .np_data_pre_skip
    mov r6, r7                         // r6 = data start
    lsl r2, r5, #1                     // r2 = 2N digits to validate
    adr r3, pk_hex_table
.np_val_loop:
    cmp r2, #0
    beq .np_have_data
    ldrb r1, [r7]
    ldrb r1, [r3, r1]
    cmp r1, #0xFF
    beq .np_err
    add r7, r7, #1
    subs r2, r2, #1
    b .np_val_loop
.np_data_pre_skip:
    add r7, r7, #1                     // advance (a beq-without-advance = infinite loop)
    b .np_data_pre
.np_have_data:
    lsl r2, r5, #1                     // r2 = 2N (the data is 2N hex chars, not N)
    add r2, r6, r2                     // r2 = data end (r6 + 2N): the store cursor steps 2/byte
    // ---- write: N strb stores (no alignment requirement). The bytes were validated above,
    // so no error path exists here anymore.
    mov r7, r6                         // r7 = data cursor
.np_store_loop:
    cmp r7, r2
    beq .np_done
    ldrb r0, [r7]                      // hi nibble
    adr r3, pk_hex_table
    ldrb r0, [r3, r0]
    ldrb r1, [r7, #1]                  // lo nibble
    ldrb r1, [r3, r1]
    lsl r0, r0, #4
    add r0, r0, r1                     // r0 = the byte
    strb r0, [r4]
    add r4, r4, #1
    add r7, r7, #2
    b .np_store_loop
.np_done:
    b pb_exit
.np_err:
    b pb_exit_err
