/* cmd.S - the 0x2A1E command blob: shared scaffolding (included by stage1.S at its former
 * cmd_peek.S site, the same translation unit, no .globl anywhere in the chain).
 *
 * One contiguous .peekblob section, word-copied at the stock hand-off (install_peek_blob) to
 * PEEK_BLOB_DST (a safe gap that survives the stock boot; the image at 0x80000 is clobbered).
 * Entry: build.py hand-encodes a 32-bit BL for the original BL.W at 0x2A1E in ldr_exec_'s
 * sub_2898 (cmd_lookup, the ASCII command parser) -> peekblob_entry. The blob is the sole
 * peek/poke implementation and the sole live TX path: its reply goes out the raw pk_marker
 * write to UART2_DR (v2l proved that reaches the bench in the stock pass; the image's
 * send_resp dies when the stock clobbers 0x80000).
 *
 * Layout:
 *   .text:      install_peek_hook (cold pass) / install_peek_blob (stock pass)
 *   .peekblob:  peekblob_entry (dispatch) -> .pb_replay, pb_exit, pb_exit_err,
 *               pk_marker, pk_hex_table, pk_dec_table,
 *               then cmd_peek.S (pb_peek), cmd_poke.S (pb_poke) and cmd_fun.S (pb_fun),
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
 * pb_peek/pb_poke must NOT move sp: they take the field start in r7 (the entry
 * computed it, r5 + *(u16*)r6, and the bl preserves r7), run with sp at the entry frame, and
 * leave it there for the terminal pop. The v2t/v2u incident: each of them did an unbalanced
 * "add sp,#4 to discard the bl frame" - shifting sp off the entry frame so pb_exit's
 * pop {r0-r7,lr} read lr from the wrong slot and `bx lr` jumped into 0x77F3B0 data (hang,
 * IWDG reboot, silence). Those adds are removed: pb_exit/pb_exit_err now pop the intact
 * entry frame and return r0=-1 to lr=0x2A23 (the stock's get_String8 not-found value; the
 * stock's 00 ack follows).
 * pk_marker is a leaf clobbering r0-r3. All intra-blob refs are PC-relative (bl/bx/ADR);
 * all absolute literals are fixed values; no pool may point into the image.
 *
 * Non-local symbols (reachable from the other .include files): pb_peek, pb_poke, pb_fun,
 * pb_exit, pb_exit_err, pk_marker, pk_hex_table, pk_dec_table.
 * (GAS scopes .local labels per .include file, so anything called across files must be
 * non-local.) */

.equ PEEK_PATCH_SITE,  0x2A1E         // stock sub_2898: the BL.W we replace (the 0x0-alias form,
                                      // the form both bench-verified passes write - see below)
.equ PEEK_BLOB_DST,    0x79D448       // the safe gap in the firmware's BSS/heap zone (bench-safe)
.equ GET_STRING8_ADDR, 0x451D         // the original BL.W's target (odd = Thumb)

/* No window gating (since v3): peek/poke accept ANY parsed address - the former
 * six-window check (W0 0x0-alias / W1 0x10000000 / W2 SRAM0 0x20000000 /
 * W3 0x40000000 / W4 flash 0xE0000000 / W5 arena 0x20000-0x800000) was removed
 * on request, so the host can reach the whole map - in particular the VOUT
 * register block at 0x40026000 (CFBAR at +0x50 = the live framebuffer address).
 * Known writability (stock pass): SRAM0 yes; PSRAM/flash stores silently
 * dropped; the SDRAM arena (0x0..0x800000) untested as of v2z. The len/syntax
 * checks (PEEK_MAX_LEN/POKE_MAX_LEN) remain. */

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
 *      a single contiguous block (entry + peek + poke + replay + marker + tables):
 *      all intra-blob refs are PC-relative (bl/bx/ADR), all absolute literals are fixed
 *      values (the UART2/GPIO registers, GET_STRING8_ADDR; the window table is gone -
 *      no gating since v3) - no pool may point into the image (the image is dead
 *      after the stock boot).
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
    // liveness beacon: one 0x5A on every 0x2A1E hit, before any dispatch (the deterministic
    // "the blob runs" ground truth the bench greps). pk_marker clobbers r0-r3 only (all on
    // the push), so the token check below re-reads the entry r5/r6 from the stack.
    movs r0, #0x5a
    bl pk_marker
    // ---- the token is in memory at R5 + *(u16*)R6: the current field's start.
    ldr r6, [sp, #24]                  // entry r6 = &u16 field byte-offset
    ldrh r0, [r6]
    ldr r7, [sp, #20]                  // entry r5 = the line base
    add r7, r7, r0                     // r7 = the current field's start
    // ---- "peek " / "poke " / "funN " / "furN " dispatch: ALL FIVE chars must match before
    // we commit (a partial match falls to .pb_replay). The 1st char picks the family (p/f),
    // the 2nd the candidate word (p->e/o, f->u).
    ldrb r0, [r7]
    cmp r0, #'p'
    beq .pb_p_tok
    cmp r0, #'f'
    beq .pb_f_tok
    b .pb_replay
.pb_p_tok:
    ldrb r1, [r7, #1]
    cmp r1, #'e'
    beq .pb_peek_tok
    cmp r1, #'o'
    beq .pb_poke_tok
    b .pb_replay
.pb_f_tok:
    ldrb r1, [r7, #1]
    cmp r1, #'u'
    bne .pb_replay
    ldrb r1, [r7, #3]                 // the N digit: 0-2
    cmp r1, #'0'
    blt .pb_replay
    cmp r1, #'2'
    bhi .pb_replay
    ldrb r2, [r7, #4]
    cmp r2, #' '
    bne .pb_replay
    subs r4, r1, #'0'                 // r4 = N (0-2)
    ldrb r2, [r7, #2]                 // 'n' (fun) or 'r' (fur)
    cmp r2, #'r'
    beq .pb_f_r
    movs r5, #0                       // fun: discard the return
    b .pb_f_go
.pb_f_r:
    movs r5, #1                       // fur: print the return
.pb_f_go:
    bl pb_fun                         // "funN "/furN " confirmed: parse + call in cmd_fun.S
    b pb_exit
.pb_poke_tok:
    ldrb r1, [r7, #2]
    cmp r1, #'k'
    bne .pb_replay
    ldrb r1, [r7, #3]
    cmp r1, #'e'
    bne .pb_replay
    ldrb r1, [r7, #4]
    cmp r1, #' '
    bne .pb_replay                     // not "poke " (no space) -> a normal line, replay the stock
    bl pb_poke                         // "poke " confirmed: the parse + write live in cmd_poke.S
    b pb_exit
.pb_peek_tok:
    ldrb r1, [r7, #2]
    cmp r1, #'e'
    bne .pb_replay
    ldrb r1, [r7, #3]
    cmp r1, #'k'
    bne .pb_replay
    ldrb r1, [r7, #4]
    cmp r1, #' '
    bne .pb_replay                     // not "peek " (no space) -> a normal line, replay the stock
    bl pb_peek                         // "peek " confirmed: the parse + dump live in cmd_peek.S
    b pb_exit
    // ---- replay: byte-for-byte the original BL.W - same args, same target, same return point.
    // Non-peek/poke lines replay the stock's own get_String8 so its normal handling is preserved.
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
 *  byte is the error sentinel: data chunks never send it (a full 255-byte chunk sends
 *  0xFE on the wire - see cmd_peek.S), so a host-side 72 FF can only be this frame.
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

.align 2
/* pk_hex_table / pk_dec_table: for ASCII 0..127 the nibble/digit value, or 0xFF = not a
 * digit (the parse loops' stop condition). In the blob (ADR-referenced) so the word-copy
 * to PEEK_BLOB_DST keeps them coherent with the peek/poke parse loops. 128 bytes each. */
pk_hex_table:
    .rept 48
    .byte 0xFF
    .endr
    .byte 0, 1, 2, 3, 4, 5, 6, 7, 8, 9        // '0'-'9'
    .rept 7
    .byte 0xFF
    .endr
    .byte 10, 11, 12, 13, 14, 15              // 'A'-'F'
    .rept 26
    .byte 0xFF
    .endr
    .byte 10, 11, 12, 13, 14, 15              // 'a'-'f'
    .rept 25
    .byte 0xFF
    .endr
pk_dec_table:
    .rept 48
    .byte 0xFF
    .endr
    .byte 0, 1, 2, 3, 4, 5, 6, 7, 8, 9        // '0'-'9'
    .rept 70
    .byte 0xFF
    .endr

/* The theme files: same section (.peekblob), same translation unit. Each holds only its
 * theme's functions (no cross-references between them); the shared scaffolding above is
 * what they call (pb_exit/pb_exit_err/pk_marker/pk_hex_table). */
.include "cmd_peek.S"
.include "cmd_poke.S"
.include "cmd_fun.S"
    .align 2                  // end the section 4-aligned: the word copy at the stock
                              // hand-off is word-granular, a partial tail word would
                              // overwrite live stock data past the blob
    .ltorg

.text
