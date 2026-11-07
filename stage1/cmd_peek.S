/* cmd_peek.S - the peek function of the 0x2A1E command blob (included by cmd.S inside the
 * .peekblob section, the same translation unit, no .globl / no section switches).
 *
 * Syntax: peek <addr>,<len>
 *   addr: hex, 0x optional (peek grammar; >8 digits wrap the 32-bit accumulator)
 *   len:  decimal, 1..PEEK_MAX_LEN
 * Reply:  one 0x5A beacon (every 0x2A1E hit), then dump frames
 *         72 <n> <n data bytes> FF FF FF (n = 1..254 as-is; a full 255-byte chunk sends
 *         n = 0xFE on the wire), or the error frame 72 FF FF FF on bad syntax,
 *         then the stock's own 00 invalid-instruction ack (r0 = -1 = not found).
 *         0xFF is the only length the error frame uses, so every frame is unambiguous:
 *         the host consumes exactly n data bytes, then the terminator - no pattern scan,
 *         no lookahead, and data holding 0xFF/0x72/0x00 (long FF runs included) is safe.
 *
 * Called with bl from peekblob_entry (cmd.S). `bl` does not push a frame, so sp is the entry
 * frame (peekblob_entry's push {r0-r7,lr}) throughout and pb_peek leaves it untouched for the
 * terminal pop. It uses r7 = the field start, which the entry already computed (r5 +
 * *(u16*)r6) and which the bl preserves - no stack re-read (r5/r6 stay in their entry-frame
 * slots; only r7 is needed live).
 *
 * This file references only cmd.S symbols (pb_exit, pb_exit_err, pk_marker,
 * pk_hex_table, pk_dec_table) and its own locals - nothing from cmd_poke.S. */

.equ PEEK_MAX_LEN, 0x40000

.thumb_func
pb_peek:
    // sp is the entry frame (peekblob_entry's push {r0-r7,lr}); `bl` does NOT push a frame,
    // so there is nothing to discard here - sp must stay at the entry frame
    // for the terminal pop in pb_exit. r7 = the field start (the 'p' of "peek"), set by the
    // entry and preserved across the bl (the bl clobbers only lr). No stack re-read needed.
    // ---- parse "<addr>,<len>" after the token: one space, hex addr (0x optional), comma,
    // optional spaces, decimal len. Every stop condition is "not the right kind of byte".
    add r7, r7, #5                     // r7 = just past "peek " (the addr start)
.pp_addr_spaces:
    ldrb r0, [r7]
    cmp r0, #' '
    beq .pp_addr_spaces_skip
    cmp r0, #'0'
    bne .pp_hex
    ldrb r1, [r7, #1]
    cmp r1, #'x'
    beq .pp_hex_skip
    cmp r1, #'X'
    beq .pp_hex_skip
    b .pp_hex                          // bare "0": a digit, parse normally
.pp_addr_spaces_skip:
    add r7, r7, #1                     // advance (a beq-without-advance = infinite loop)
    b .pp_addr_spaces
.pp_hex_skip:
    add r7, r7, #2
.pp_hex:
    movs r0, #0
.pp_hex_loop:
    ldrb r2, [r7]
    cmp r2, #','
    beq .pp_have_addr
    adr r3, pk_hex_table               // PC-relative, in-blob: coherent after the word-copy
    ldrb r1, [r3, r2]
    cmp r1, #0xFF
    beq .pp_err
    lsl r0, r0, #4
    add r0, r0, r1
    add r7, r7, #1
    b .pp_hex_loop
.pp_have_addr:
    mov r4, r0                         // r4 = addr
    add r7, r7, #1                     // past the ','
.pp_len_space:
    ldrb r0, [r7]
    cmp r0, #' '
    beq .pp_len_space_skip
    movs r0, #0
.pp_dec:
    ldrb r2, [r7]
    adr r3, pk_dec_table               // PC-relative, in-blob
    ldrb r2, [r3, r2]
    cmp r2, #0xFF
    beq .pp_have_len
    lsl r1, r0, #3                     // r0 * 10 = r0*8 + r0*2
    lsl r0, r0, #1
    add r0, r0, r1
    add r0, r0, r2
    add r7, r7, #1
    b .pp_dec
.pp_len_space_skip:
    add r7, r7, #1                     // advance (a beq-without-advance = infinite loop)
    b .pp_len_space
.pp_have_len:
    cmp r0, #0
    beq .pp_err                        // no digit: len missing
    cmp r0, #PEEK_MAX_LEN
    bhs .pp_err
    mov r5, r0                         // r5 = len
    // ---- dump: read the source straight out, chunked 72 <n> <data> FF FF FF frames, each
    // byte via pk_marker (the raw UART2 write). pk_marker clobbers r0-r3 only, so r4/r5/r6
    // survive every call (the dump loop's live registers). A full 255-byte chunk sends
    // n = 0xFE on the wire: 0xFF is reserved for the error frame (pb_exit_err), so the host
    // parses every frame positionally by n - no pattern, no lookahead.
    mov r6, r4                         // r6 = src
.pp_chunk:
    cmp r5, #0
    beq .pp_done
    cmp r5, #0xFF
    ble .pp_n_ok
    movs r7, #0xFF
    b .pp_len_set
.pp_n_ok:
    mov r7, r5
.pp_len_set:
    cmp r7, #0xFF
    beq .pp_len_fe
    mov r4, r7                         // r4 = the on-wire length byte (free in this loop)
    movs r0, #0x72
    b .pp_len_tx
.pp_len_fe:
    movs r4, #0xFE                     // full chunk: 0xFE on the wire; 0xFF stays the error sentinel
.pp_len_tx:
    movs r0, #0x72
    bl pk_marker
    mov r0, r4
    bl pk_marker
.pp_data:
    ldrb r0, [r6]
    bl pk_marker
    add r6, r6, #1
    subs r5, r5, #1
    subs r7, r7, #1
    bne .pp_data
    movs r0, #0xFF
    bl pk_marker
    movs r0, #0xFF
    bl pk_marker
    movs r0, #0xFF
    bl pk_marker
    b .pp_chunk
.pp_done:
    b pb_exit
.pp_err:
    b pb_exit_err
