/* cmd.S - the 0x2A1E command blob: shared scaffolding (included by stage1.S at its former
 * cmd_peek.S site, the same translation unit, no .globl anywhere in the chain).
 *
 * One contiguous .peekblob section, word-copied at the stock hand-off (install_peek_blob) to
 * PEEK_BLOB_DST (a safe gap that survives the stock boot; the image at 0x80000 is clobbered).
 * Entry: build.py hand-encodes a 32-bit BL for the original BL.W at 0x2A1E in ldr_exec_'s
 * sub_2898 (cmd_lookup, the ASCII command parser) -> peekblob_entry. The blob is the
 * nana console (the binary peek/poke/fun/fur handlers) and the sole live TX path: its
 * reply goes out the raw pk_marker write to UART2_DR (v2l proved that reaches the bench
 * in the stock pass; the image's send_resp dies when the stock clobbers 0x80000).
 *
 * Layout:
 *   .text:      install_peek_hook (cold pass) / install_peek_blob (stock pass)
 *   .peekblob:  peekblob_entry (dispatch) -> .pb_replay, pb_exit, pb_exit_err,
 *               pk_marker, pb_send_u32, pb_crc32, pb_nana_reply, pb_nana (parse + CRC +
 *               dispatch), pb_nana_done, pb_nana_err,
 *               then the theme files: cmd_peek.S (pb_nana_peek), cmd_poke.S (pb_nana_poke),
 *               cmd_fun.S (pb_nana_fun, pb_nana_fur),
 *               included here so the whole blob stays one word-copyable block. The section
 *               must end 4-aligned (the word copy at the stock hand-off is word-granular)
 *               and its end must stay < PEEK_BLOB_END (0x7DF000, the stock stack floor):
 *               the safe gap is 0x79D438..0x7DF000 (above the bss top, below the stack floor
 *               - see build.py), so the blob may grow well past the old 0x428 design cap.
 *               build.py asserts PEEK_BLOB_DST + size <= PEEK_BLOB_END.
 *
 * Entry state (IDA cmd_lookup 0x2898): r0=dst slot, r1=strings41, r2=0x29, r3=2, r5=line base,
 * r6=&u16 field byte-offset, r7=g_widget_property (0x77F3B0), lr=0x2A23. The token is the
 * field at R5 + *(u16*)R6; after the entry push the slots the code reads are [sp,#20]=r5
 * and [sp,#24]=r6 (slot values bench-verified against the green baseline).
 *
 * Stack discipline: peekblob_entry pushes {r0-r7,lr} (36 B) once and never pops; sp is that
 * frame top for the whole dispatch. `bl` does NOT push a frame (it only sets lr), so
 * the nana handlers must NOT move sp: pb_nana (called with bl from the entry) pushes its own
 * {r4-r7,lr} on top of the entry frame, and its dispatch branches (b - no frame) to the
 * theme handlers, which run with sp at the pb_nana frame top; only pb_nana's terminal pop
 * unwinds it, leaving the entry frame intact for pb_exit's terminal pop. The v2t/v2u
 * incident: the old text pb_peek/pb_poke each did an unbalanced "add sp,#4 to discard the bl
 * frame" - shifting sp off the entry frame so pb_exit's pop {r0-r7,lr} read lr from the wrong slot and `bx lr` jumped into 0x77F3B0 data (hang,
 * IWDG reboot, silence). Those adds are removed: pb_exit/pb_exit_err now pop the intact
 * entry frame and return r0=-1 to lr=0x2A23 (the stock's get_String8 not-found value; the
 * stock's 00 ack follows).
 * pk_marker is a leaf clobbering r0-r3. All intra-blob refs are PC-relative (bl/bx/ADR);
 * all absolute literals are fixed values; no pool may point into the image.
 *
 * Non-local symbols (reachable from the theme .include files): pb_nana_peek, pb_nana_poke,
 * pb_nana_fun, pb_nana_fur, pb_nana_done, pb_nana_err, pb_nana_reply.
 * (GAS scopes .local labels per .include file, so anything called across files must be
 * non-local.) */

.equ PEEK_PATCH_SITE,  0x2A1E         // stock sub_2898: the BL.W we replace (the 0x0-alias form,
                                      // the form both bench-verified passes write - see below)
.equ PEEK_BLOB_DST,    0x79D448       // the safe gap in the firmware's BSS/heap zone (bench-safe)
.equ GET_STRING8_ADDR, 0x451D         // the original BL.W's target (odd = Thumb)

/* No window gating (since v3): nana peek/poke/fun/fur accept ANY 32-bit address - the
 * former six-window check (W0 0x0-alias / W1 0x10000000 / W2 SRAM0 0x20000000 /
 * W3 0x40000000 / W4 flash 0xE0000000 / W5 arena 0x20000-0x800000) was removed
 * on request, so the host can reach the whole map - in particular the VOUT
 * register block at 0x40026000 (CFBAR at +0x50 = the live framebuffer address).
 * The only size check left is the poke data cap (POKE_MAX_DATA in cmd_poke.S -
 * the RX-ring line bound; the bench-truth writability notes moved to that file). */

/* --------------------------------------------------------------------------
 *  install_peek_hook: the COLD pass's peek setup, right after install_entry_hook. Stores the
 *  4-byte 32-bit Thumb BL (T1) (hand-encoded by build.py for the 0x2A1E site and spliced into
 *  patch_blob offset 32 = peek_patch_word) over the stock parser's original BL.W at 0x2A1E
 *  (the 0x0-alias form: in the cold pass the boot-ROM alias 0x0 = SRAM0 0x20000000). The
 *  original BL.W goes to get_String8 (0x451D), an instruction that only searches the ASCII
 *  tables for the command and returns -1 (not found) for unknown words without touching the
 *  line or the fields - so the detour keeps the stock's visible behavior (the "peek"/"poke"
 *  lines are not in its table; the 00 invalid-instruction reply is sent by the stock after
 *  we return). Leaf on purpose: at the entry call site its push {lr} (the loader's return
 *  address) is live and must survive. The stock pass re-writes the word after the stock
 *  boot wipes it (install_peek_blob). */
.thumb_func
install_peek_hook:
    ldr r0, =peek_patch_word
    ldr r0, [r0]
    ldr r1, =PEEK_PATCH_SITE
    str r0, [r1]
    bx lr
    .ltorg

/* --------------------------------------------------------------------------
 *  install_peek_blob: the STOCK pass's peek setup, right before the one-way jump to stock
 *  (the stock boot has clobbered the cold pass's 0x2A1E word - the stock rewrites the
 *  SRAM0 code region, so the word must be re-installed after the boot).
 *   1. Word-copies the whole .peekblob section (__peekblob_lma..__peekblob_end, its LMA in
 *      the image) to PEEK_BLOB_DST, the safe gap that survives the stock boot. The blob is
 *      a single contiguous block (entry + nana dispatch + the three theme handlers +
 *      replay + marker + crc/senders): all intra-blob refs are PC-relative (bl/bx/ADR),
 *      all absolute literals are fixed values (the UART2 registers, GET_STRING8_ADDR) -
 *      no pool may point into the image (the image is dead after the stock boot).
 *   2. Re-writes the 0x2A1E BL word to target the gap copy (same 0x0-alias form as the
 *      cold pass; bench-confirmed the word then reads back at 0x20002A1E in the stock pass).
 *   3. I-cache reset (the shared icache_reset in stage1.S): defensive - nothing in this
 *      boot has fetched 0x2A1E or 0x79D448 yet, but the idiom is the cache's only reset.
 *  Push/pop {r4-r6,lr}; clobbers r0-r3 (all dead at the caller - it re-loads r0 for the
 *  P:/R: self-check prints). */
.thumb_func
install_peek_blob:
    push {r4-r6, lr}
    ldr r4, =__peekblob_lma                  // source: the blob's home in the image
    ldr r5, =__peekblob_end
    subs r5, r5, r4                          // r5 = the section size (a multiple of 4)
    ldr r6, =PEEK_BLOB_DST                   // destination: the safe gap
    movs r0, #0
.ipb_copy:
    ldr r1, [r4, r0]
    str r1, [r6, r0]
    adds r0, r0, #4
    cmp r0, r5
    blo .ipb_copy
    ldr r0, =peek_patch_word
    ldr r0, [r0]
    ldr r1, =PEEK_PATCH_SITE
    str r0, [r1]                             // 0x2A1E -> BL to the gap copy
    bl icache_reset
    pop {r4-r6, lr}
    bx lr
    .ltorg

/* --------------------------------------------------------------------------
 *  .peekblob - the relocated command blob (one contiguous word-copyable block).
 *  The blob must stay aligned 4: the word copy assumes 32-bit alignment, and the first
 *  word of the section is the R: self-check signature the stock pass prints. */
.section .peekblob, "a"
.align 2
.thumb_func
peekblob_entry:
    // 0x2A1E lands here (build.py's _bl_word(0x2A1E, 0x79D448)). The first two instructions
    // are the R: self-check signature (the stock pass prints the section's first word).
    push {r0-r7, lr}
    // liveness beacon: "chi!" on every 0x2A1E hit, before any dispatch (the deterministic
    // "the blob runs" ground truth the bench greps; also the nana reply prefix the host keys
    // on). pk_marker clobbers r0-r3 only (all on the push), so the token check below re-reads
    // the entry r5/r6 from the stack.
    movs r0, #'c'
    bl pk_marker
    movs r0, #'h'
    bl pk_marker
    movs r0, #'i'
    bl pk_marker
    movs r0, #'!'
    bl pk_marker
    // ---- the token is in memory at R5 + *(u16*)R6: the current field's start.
    ldr r6, [sp, #24]                  // entry r6 = &u16 field byte-offset
    ldrh r0, [r6]
    ldr r7, [sp, #20]                  // entry r5 = the line base
    add r7, r7, r0                     // r7 = the current field's start
    // ---- "nana" dispatch: the binary protocol. The 1st char must be 'n' (then .pb_nana_tok
    // confirms the full "nana"); anything else falls to .pb_replay (the stock's own handling).
    // The stock's 0x2A1E hook is only reached for lowercase-first tokens (its char-range test
    // accepts only '_'-'z'), so the trigger MUST start lowercase: an uppercase 'N' is routed to
    // the variable/property path and never reaches this hook.
    ldrb r0, [r7]
    cmp r0, #'n'
    beq .pb_nana_tok
    b .pb_replay
.pb_nana_tok:
    // "nana" trigger: the binary protocol. All four chars must match before we commit;
    // a partial match falls to .pb_replay (the stock's own get_String8).
    ldrb r1, [r7, #1]
    cmp r1, #'a'
    bne .pb_replay
    ldrb r1, [r7, #2]
    cmp r1, #'n'
    bne .pb_replay
    ldrb r1, [r7, #3]
    cmp r1, #'a'
    bne .pb_replay
    bl pb_nana
    b pb_exit
    // ---- replay: byte-for-byte the original BL.W - same args, same target, same return point.
    // Non-nana lines replay the stock's own get_String8 so its normal handling is preserved
    // (the old text peek/poke/fun grammar is no longer handled by the blob).
    // Runs with sp at the entry frame (branched to, not called: no bl frame to discard).
.pb_replay:
    pop {r0-r7, lr}                    // original args (r0-r3) + the caller's live r7, lr = 0x2A23
    push {r7, lr}                      // r7 must not die in the ldr below; blx clobbers lr
    ldr r7, =GET_STRING8_ADDR          // 0x451D (Thumb); indirect call, no ABS branch relocation
    blx r7                             // get_String8; clobbers r0-r2/r5, preserves r3/r6/r7
    pop {r7, lr}                       // r7 = 0x77F3B0, lr = 0x2A23 again
    bx lr
    .ltorg

/* --------------------------------------------------------------------------
 *  pb_exit: the success/exit terminal. Runs with sp at the entry frame (the entry's
 *  push {r0-r7,lr}; no called function moves sp, since `bl` does not push a frame). Popping
 *  the full 9-word frame restores lr = 0x2A23; r0 is then set to -1 (the stock's get_String8
 *  not-found value) so the parser takes its stock unknown-command path (the 00
 *  invalid-instruction reply follows our frame). */
.thumb_func
pb_exit:
    pop {r0-r7, lr}
    movs r0, #0
    sub r0, r0, #1                     // r0 = -1
    bx lr

/* --------------------------------------------------------------------------
 *  pb_exit_err: the error terminal: the 72 FF FF FF frame, then pb_exit. The 0xFF length
 *  byte is the error sentinel: data chunks are capped at 254 (0xFE) and never send it
 *  (see cmd_peek.S), so a host-side 72 FF can only be this frame.
 *  pk_marker clobbers r0-r3 only; the entry frame (36 B) is intact under sp. */
.thumb_func
pb_exit_err:
    movs r0, #0x72
    bl pk_marker
    movs r0, #0xFF
    bl pk_marker
    movs r0, #0xFF
    bl pk_marker
    movs r0, #0xFF
    bl pk_marker
    b pb_exit

/* --------------------------------------------------------------------------
 *  pk_marker(r0 = byte): the relocated blob's own uart_putc. The blob cannot reuse the
 *  in-image uart_putc/send_resp (the image at 0x80000 is clobbered by the stock boot), so
 *  it re-derives the UART2 TX here: poll UART2_TH's TX FIFO fill level (the exact wait
 *  uart_putc uses), then strb the byte to UART2_DR. All four address literals (UART2_TH/
 *  MASK/FULL/DR) sit in THIS section's pool (PC-relative ldr) and stay valid after the
 *  word copy because the whole block moves as one unit. This is the deterministic reach
 *  signal: one 'Z' per 0x2A1E hit, independent of the backlight. Leaf: clobbers r0-r3. */
.thumb_func
pk_marker:
    mov r3, r0                         // keep the byte out of r0-r2 while polling
.pm_wait:
    ldr r0, =UART2_TH
    ldr r1, [r0]
    ldr r2, =UART2_TXFIFO_MASK
    ands r1, r1, r2
    ldr r2, =UART2_TXFIFO_FULL
    cmp r1, r2
    bhs .pm_wait
    ldr r0, =UART2_DR
    strb r3, [r0]
    bx lr
    .ltorg

/* --------------------------------------------------------------------------
 *  pb_send_u32(r0 = value): sends a 32-bit value as 4 LE bytes via pk_marker.
 *  Clobbers r0-r4. The value lives in r4 because pk_marker clobbers r0-r3
 *  (its FIFO poll uses r1); r4-r7 survive pk_marker.
 * -------------------------------------------------------------------------- */
.thumb_func
pb_send_u32:
    push {r4, lr}
    movs r4, r0                         // r4 = the full value (survives pk_marker)
    ands r0, r4, #0xFF                  // byte 0
    bl pk_marker
    movs r0, r4
    lsr r0, r0, #8
    ands r0, r0, #0xFF                  // byte 1
    bl pk_marker
    movs r0, r4
    lsr r0, r0, #16
    ands r0, r0, #0xFF                  // byte 2
    bl pk_marker
    movs r0, r4
    lsr r0, r0, #24
    ands r0, r0, #0xFF                  // byte 3
    bl pk_marker
    pop {r4, lr}
    bx lr

/* --------------------------------------------------------------------------
 *  pb_crc32(r0 = ptr, r1 = len) -> r0 = crc32.
 *  Standard IEEE 802.3 CRC32 (reflected, poly 0xEDB88320). Bit-by-bit (no table)
 *  to keep the blob small. Clobbers r0-r3 (r3 = bit counter, r2 = CRC state);
 *  r4 (the poly) is saved in a local push/pop.
 * -------------------------------------------------------------------------- */
.thumb_func
pb_crc32:
    push {r4, lr}
    movs r2, #0
    subs r2, r2, #1                     // r2 = 0xFFFFFFFF (CRC state)
    movw r4, #0x8320                   // r4 = 0xEDB88320 (the reflected poly)
    movt r4, #0xEDB8
.pb_crc32_byte:
    cmp r1, #0
    beq .pb_crc32_final
    ldrb r3, [r0]
    add r0, r0, #1
    subs r1, r1, #1
    eors r2, r2, r3                     // crc ^= byte
    movs r3, #8
.pb_crc32_bit:
    tst r2, #1                          // test bit 0 (sets flags only; r3 keeps the count)
    beq .pb_crc32_bit_sr
    lsr r2, r2, #1
    eors r2, r2, r4                     // crc = (crc >> 1) ^ poly
    b .pb_crc32_bit_next
.pb_crc32_bit_sr:
    lsr r2, r2, #1
.pb_crc32_bit_next:
    subs r3, r3, #1
    bne .pb_crc32_bit
    b .pb_crc32_byte
.pb_crc32_final:
    mvns r0, r2                         // r0 = ~r2 = r2 ^ 0xFFFFFFFF (final XOR)
    pop {r4, lr}
    bx lr

/* --------------------------------------------------------------------------
 *  pb_nana_reply(r0 = data ptr, r1 = data len):
 *  Sends the binary reply frame: [u32 len LE][data bytes][crc32 LE].
 *  CRC32 is over the data (r1 bytes at r0). Uses a local push/pop; sp is
 *  restored before return so the entry frame is intact for pb_exit.
 * -------------------------------------------------------------------------- */
.thumb_func
pb_nana_reply:
    push {r4-r5, lr}
    str r0, [sp, #16]                  // save data ptr (slot 4)
    str r1, [sp, #20]                  // save data len (slot 5)
    // Compute CRC32 over the data
    bl pb_crc32                        // r0 = crc; clobbers r2-r4
    str r0, [sp, #24]                  // save crc (slot 6, was r7 - dead here)
    // Send u32 size
    ldr r0, [sp, #20]
    bl pb_send_u32
    // Send data bytes
    ldr r4, [sp, #16]                  // r4 = data ptr
    ldr r5, [sp, #20]                  // r5 = data len (remaining)
.pb_nnr_loop:
    cmp r5, #0
    beq .pb_nnr_done
    ldrb r0, [r4]
    bl pk_marker
    add r4, r4, #1
    subs r5, r5, #1
    b .pb_nnr_loop
.pb_nnr_done:
    // Send u32 crc
    ldr r0, [sp, #24]
    bl pb_send_u32
    pop {r4-r5, lr}
    bx lr

/* --------------------------------------------------------------------------
 *  pb_nana: the binary protocol handler (triggered by the "nana" text token).
 *  Reads [u32 size][cmd][args][crc32][guard] from the RX ring at
 *  token_start + 5 (the "nana" token's position, plus the separating space),
 *  verifies CRC32, dispatches on cmd, and sends the reply.
 *
 *  The stock line framer (uart_rx_next_frame) has ALREADY advanced the RX read
 *  head past the whole "nana ..." frame before this hook runs, so pb_nana must
 *  NOT touch the read head (g_uart1 @ 0x77F604, field_0) - the framer owns it.
 *
 *  cmd values: 1=peek, 2=poke, 3=fun, 4=fur - the handlers are non-local symbols in the
 *  theme files, branched to from this dispatch (b, not bl); see their headers for the
 *  register plans. A handler ends in pb_nana_done, whose pop {r4-r7,lr} returns to the
 *  `b pb_exit` after the call.
 * -------------------------------------------------------------------------- */
.thumb_func
pb_nana:
    push {r4-r7, lr}
    // --- Locate the binary payload. The stock line framer puts the whole
    // "nana [u32 size][cmd][args][crc32][guard]" line into the RX ring, and
    // uart_rx_next_frame has ALREADY advanced the read head past that frame
    // by the time this 0x2A1E hook runs. The payload sits at token_start + 5
    // (token_start = entry r7 = [sp,#12] = the "nana" position in the RX ring;
    // +4 for "nana", +1 for the separating space). We must NOT touch the read
    // head (the framer owns it).
    ldr r4, [sp, #12]                  // r4 = token start (entry r7)
    add r4, r4, #5                     // r4 = ptr to [u32 size][cmd][args][crc32][guard]
    ldr r5, [r4]                       // r5 = dw_payload_size
    cmp r5, #5
    blt pb_nana_err
    add r6, r4, #4                     // r6 = ptr to [cmd][args]
    sub r7, r5, #4                     // r7 = data length
    movs r0, r6
    movs r1, r7
    bl pb_crc32                        // r0 = computed crc
    add r6, r4, r5                     // r6 = ptr to stored crc32
    ldr r6, [r6]                       // r6 = stored crc
    cmp r0, r6
    bne pb_nana_err
    // --- Dispatch on cmd byte (first byte of [cmd][args])
    ldrb r0, [r4, #4]                 // r0 = cmd
    cmp r0, #1
    beq pb_nana_peek
    cmp r0, #2
    beq pb_nana_poke
    cmp r0, #3
    beq pb_nana_fun
    cmp r0, #4
    beq pb_nana_fur
    b pb_nana_err

    // The theme handlers (cmd_peek.S / cmd_poke.S / cmd_fun.S, included below) each
    // branch here when done.
pb_nana_done:
    // No read-head update: uart_rx_next_frame already consumed the whole frame
    // (read head = frame start + len + 2) before this hook ran.
    pop {r4-r7, lr}
    bx lr

/* pb_nana_err: the nana error terminal - the 1-byte 0xFF payload reply, then the same
 * unwind as pb_nana_done. The sentinel byte is stored in the ENTRY frame's r0 slot
 * ([sp,#20] above this frame) - NOT in this frame's r7 slot ([sp,#12]): pb_nana_reply
 * pushes 12 bytes, and its [sp,#24] store (the computed crc) lands exactly on this frame's
 * r7 slot, clobbering the sentinel before the reply's data send reads it. The entry r0
 * slot is dead: the stock caller treats r0 as scratch across the hook call, and pb_exit
 * pops it and overwrites it with -1. pb_nana_fur stashes its return value in the same
 * slot for the same reason (see cmd_fun.S). */
pb_nana_err:
    movs r0, #0xFF
    strb r0, [sp, #20]               // 1-byte error payload (the entry r0 slot - see above)
    add r0, sp, #20
    movs r1, #1
    bl pb_nana_reply
    pop {r4-r7, lr}
    bx lr
    .ltorg

/* The theme files: same section (.peekblob), same translation unit. Each holds only its
 * theme's handlers (no cross-references between them); the shared scaffolding above is
 * what they call (pb_nana_done/pb_nana_err/pb_nana_reply - the rest, pb_crc32/pk_marker/
 * pb_send_u32, via pb_nana_reply). */
.include "cmd_peek.S"
.include "cmd_poke.S"
.include "cmd_fun.S"
    .align 2                  // end the section 4-aligned: the word copy at the stock
                              // hand-off is word-granular, a partial tail word would
                              // overwrite live stock data past the blob
    .ltorg

.text
