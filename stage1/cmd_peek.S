/* cmd_peek: everything specific to the 0x2A1E "peek <addr>,<len>" command, split out of
 * stage1.S and pulled back in by its .include (at the old constants site). Same translation
 * unit, so none of this needs .globl. Contents, in order: the peek .equ constants (must come
 * before entry_trampoline's P:/R: self-check uses them), install_peek_hook (cold pass) and
 * install_peek_blob (stock pass), the readable windows, and the .peekblob section - the live
 * blob word-copied to PEEK_BLOB_DST by install_peek_blob. This file MUST end with `.text`:
 * the last block switches into .peekblob, and stage1.S's continuation (the fault trap and the
 * melody tables) must go on in .text.
 */

/* ---- peek hook: patches the stock's ASCII parser (sub_2898) to add a "peek" command ----
 * The 4-byte window at 0x2A1E holds the parser's BL.W get_String8. build.py encodes a 32-bit
 * Thumb BL (T1) targeting PEEK_BLOB_DST over it (patch_blob offset 32); install_peek_hook stores
 * it on the cold pass, install_peek_blob re-writes it on the stock pass (the stock's own boot
 * wipes the cold-pass copy). The 0x2A1E BL lands in the .peekblob blob (PEEK_BLOB_DST = 0x79D448,
 * a copy the stock pass made from the image into the safe gap - see below), not in the image:
 * bench-confirmed, the stock boot (reset 0x348 -> init_table_runner 0x270) clobbers
 * 0x080000..~0x077F3B0 (which includes the image at 0x80000..0x82648 - an in-image blob dies
 * before the first serial command) and clears bss 0x7620D0..0x79D438. The safe gap
 * 0x79D438..0x7DF000 (above the bss top, below the stack floor 0x7DF000, the stock's SP =
 * 0x800000) survives the boot, and 0x2A1E reaches it directly (32-bit Thumb BL range = +/-16 MB).
   * The blob (peekblob_entry) is the live peek (v2m, bench-confirmed): "peek <addr>,<len>" is
   * parsed (hex addr / decimal len) and window-checked, then dumped as 72 <n> <data> FF FF FF
   * frames over the raw UART2 write (pk_marker); bad syntax / out-of-range -> 72 FF FF FF; any
   * other line re-runs the original get_String8 lookup byte-for-byte. Every path returns
   * r0 = -1 (the stock's get_String8 not-found value) so the parser takes its plain
   * unknown-command path either way (the only safe return: any >= 0 value would make the stock
   * execute a real command handler). */
.equ PEEK_PATCH_SITE,  0x2A1E          // stock sub_2898: the BL.W we replace
.equ GET_STRING8_ADDR, 0x451D          // the original BL.W's target (odd = Thumb)
.equ PEEK_MAX_LEN,     0x4000          // max dump per command (16 KB ≈ 1.4 s at 115200, inside the IWDG window)
.equ PEEK_BLOB_DST,    0x79D448        // the .peekblob blob's runtime home: the safe gap (see above)

/* install_peek_hook: stores the 4-byte 32-bit Thumb BL (T1) (hand-encoded by build.py for the
 * 0x2A1E site and spliced into patch_blob offset 32 = peek_patch_word) over the stock parser's
 * original BL.W at 0x2A1E. The word targets PEEK_BLOB_DST (0x79D448) - the .peekblob blob's
 * runtime home in the safe gap. Called from entry's cold pass only, right after
 * install_entry_hook (first write; read back + verified). The stock pass uses
 * install_peek_blob instead: the loader's stock path (ldr_main -> sub_200013D8/sub_20001554
 * -> sub_20002BD4) copies the whole stock firmware from the flash window (0x10000000) into RAM
 * 0x0, clobbering the cold pass's write, and the stock boot then clobbers the image itself -
 * so the stock pass must re-write the word AND land the blob in the gap first. Leaf on
 * purpose: at the entry call site its push {lr} (the loader's return address) is live and must
 * survive. */
install_peek_hook:
    ldr r0, =peek_patch_word
    ldr r0, [r0]
    ldr r1, =PEEK_PATCH_SITE
    str r0, [r1]
    bx lr
    .ltorg

/* install_peek_blob: the stock pass's peek setup, right before the one-way jump to stock.
 *   1. Copies the .peekblob section (__peekblob_lma..__peekblob_end, its LMA in the image) to
 *      PEEK_BLOB_DST (0x79D448): the safe gap that survives the stock boot (the image the blob
 *      is linked into is inside the clobber map - see the PEEK_BLOB_DST comment). The section is
 *      a contiguous block (code + literal pools + PKBLK_SAVE), so a raw word copy relocates it
 *      as a unit: every intra-blob reference is PC-relative (ADR), every absolute literal is a
 *      fixed value (GPIO registers, GET_STRING8_ADDR), not a pointer into the
 *      blob. 0x79D448 is 4-byte aligned and the section is 4-byte padded, so the word copy is
 *      exact.
 *   2. Writes the site3 BL word (targeting PEEK_BLOB_DST) over 0x2A1E - re-writing it after
 *      the stock copy wiped the cold pass's.
 *   3. I-cache reset (shared icache_reset): defensive - nothing in this boot has fetched
 *      0x2A1E or 0x79D448 yet, but the idiom is the cache's only reset and it is cheap.
 * Push/pop {r4-r6,lr}; clobbers r0-r3 (all dead at the caller - it re-loads r0 for the P:/R:
 * prints). The stock's boot runs AFTER the return, so by the time it clobbers the image and
 * clears bss, the copy at 0x79D448 already sits above both
 * ranges and survive. */
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

/* The readable windows for the 0x2A1E peek (the .peekblob blob below): the only ranges the
 * "peek <addr>,<len>" command accepts; addr+len must stay inside one window, else error frame.
 * 0x0-0x20000 = SRAM0 via the boot-ROM alias (the stock's own code+data, 0x0-0x33C1C);
 * 0x20000000-0x20010000 = the same SRAM0 via its native address; 0x40000000-0x50000000 = the
 * 256 MB PSRAM; 0xE0000000-0xF0000000 = the 16 MB SPI flash (XIP). */
.equ PEEK_W0_LO, 0x00000000
.equ PEEK_W0_HI, 0x00020000
.equ PEEK_W1_LO, 0x10000000
.equ PEEK_W1_HI, 0x10010000
.equ PEEK_W2_LO, 0x20000000
.equ PEEK_W2_HI, 0x20010000
.equ PEEK_W3_LO, 0x40000000
.equ PEEK_W3_HI, 0x50000000
.equ PEEK_W4_LO, 0xE0000000
.equ PEEK_W4_HI, 0xF0000000

   /* ==== .peekblob: the live 0x2A1E peek blob (v2m; runtime home PEEK_BLOB_DST = 0x79D448) ====
   * Everything inside the .section switch below is one contiguous block (code + literal pools +
   * the pk_hex_table/pk_dec_table parse tables + PKBLK_SAVE); install_peek_blob copies the whole
   * block word-for-word from its LMA in the image to 0x79D448 at the stock hand-off, and the
   * 0x2A1E BL lands on its entry. For that copy to be a valid relocation: every intra-block
   * reference must be PC-relative (ADR), and every absolute literal must be a fixed VALUE (the
   * GPIO/UART register addresses, GET_STRING8_ADDR) - never an address pointing into the image
   * (those die with it). The block is 4-byte padded, so the word copy is exact, and 0x79D448 is
   * 4-byte aligned, so the 32-bit-Thumb entry stays 4-byte aligned after the copy.
   *
   * peekblob_entry (the 0x2A1E target; bench-confirmed v2m): every hit first emits the 0x5A 'Z'
   * beacon (a raw UART2_DR write via pk_marker - the only TX that reaches the bench in the stock
   * pass), then: "peek <addr>,<len>" -> parse (hex addr / decimal len), window-check, chunked
   * dump 72 <n> <data> FF FF FF over pk_marker, return r0 = -1; bad syntax / out-of-range /
   * len 0 or > PEEK_MAX_LEN -> 72 FF FF FF, r0 = -1; any other line -> replay the stock's own
   * get_String8 with the original args (byte-for-byte stock). r0 = -1 is the stock's
   * get_String8 not-found value: the parser takes its unknown-command path and its 00 FF FF FF
   * ack follows our frame - the only safe return (any index >= 0 would make the stock execute
   * a real command handler). r7 must survive the replay: the stock writes state through it
   * (0x2966/0x2A34/0x29AC), and an earlier version that loaded the call target into r7
   * corrupted sub_480C's code (0x451D+0x4CA = 0x49E7), silencing every later parser line -
   * hence the push/pop around the blx in the entry.
   */
.ltorg                                   // flush any pending .text pool before the section switch
.section .peekblob, "a"                  // "a" = SHF_ALLOC: objcopy -O binary emits only alloc sections, so
                                         // without this the whole blob is dropped from the image and the
                                         // install_peek_blob copy reads uninitialized RAM (the v2j R: bug)
.align 2
.thumb_func
peekblob_entry:
    // v2m: the REAL peek. 0x2A1E lands here (build.py's _bl_word(0x2A1E, 0x79D448)). The blob is the
    // sole peek implementation and the sole live TX path: it sits in the safe gap (survives the
    // stock boot), so its reply goes out the raw pk_marker write to UART2_DR (v2l proved that
    // reaches the bench in the stock pass; the image's send_resp dies when the stock
    // clobbers 0x80000). Entry state (IDA cmd_lookup 0x2898): r0=dst slot, r1=strings41,
    // r2=0x29, r3=2, r5=line base, r6=&u16 field offset, r7=g_widget_property (0x77F3B0), lr=0x2A23.
    push {r0-r7, lr}
    // liveness beacon: one 0x5A on every 0x2A1E hit, before any dispatch (the deterministic
    // "the blob runs" ground truth the bench greps). pk_marker clobbers r0-r3 only (all on the
    // push), so the token check below re-reads r5/r6 from the stack.
    movs r0, #0x5a
    bl pk_marker
    // ---- is this the "peek" command? the token is in memory at R5 + *(u16*)R6.
    ldr r6, [sp, #24]                  // entry r6 = &u16 field byte-offset
    ldrh r0, [r6]
    ldr r7, [sp, #20]                  // entry r5 = the line base
    add r7, r7, r0                     // r7 = the current field's start
    ldrb r0, [r7]
    cmp r0, #'p'
    bne .pb_replay
    ldrb r1, [r7, #1]
    cmp r1, #'e'
    bne .pb_replay
    ldrb r1, [r7, #2]
    cmp r1, #'e'
    bne .pb_replay
    ldrb r1, [r7, #3]
    cmp r1, #'k'
    bne .pb_replay
    ldrb r1, [r7, #4]
    cmp r1, #' '
    bne .pb_replay                     // not "peek " (no space) -> a normal line, replay the stock
    // ---- parse "<addr>,<len>" after the field: one space, hex addr (0x optional), comma,
    // optional spaces, decimal len. Every stop condition is "not the right kind of byte".
    add r7, r7, #5                     // r7 = just past "peek " (the addr start)
.pb_addr_spaces:
    ldrb r0, [r7]
    cmp r0, #' '
    beq .pb_addr_spaces
    cmp r0, #'0'
    bne .pb_hex
    ldrb r1, [r7, #1]
    cmp r1, #'x'
    beq .pb_hex_skip
    cmp r1, #'X'
    beq .pb_hex_skip
    b .pb_hex                          // bare "0": a digit, parse normally
.pb_hex_skip:
    add r7, r7, #2
.pb_hex:
    movs r0, #0
.pb_hex_loop:
    ldrb r2, [r7]
    cmp r2, #','
    beq .pb_have_addr
    adr r3, pk_hex_table               // PC-relative, in-blob: coherent after the word-copy
    ldrb r1, [r3, r2]
    cmp r1, #0xFF
    beq .pb_err
    lsl r0, r0, #4
    add r0, r0, r1
    add r7, r7, #1
    b .pb_hex_loop
.pb_have_addr:
    mov r4, r0                         // r4 = addr
    add r7, r7, #1                     // past the ','
    ldrb r0, [r7]
    cmp r0, #' '
    beq .pb_len_space
    b .pb_dec
.pb_len_space:
    add r7, r7, #1
    ldrb r0, [r7]
    cmp r0, #' '
    beq .pb_len_space
.pb_dec:
    movs r0, #0
.pb_dec_loop:
    ldrb r2, [r7]
    adr r3, pk_dec_table               // PC-relative, in-blob
    ldrb r2, [r3, r2]
    cmp r2, #0xFF
    beq .pb_have_len
    lsl r1, r0, #3                     // r0 * 10 = r0*8 + r0*2
    lsl r0, r0, #1
    add r0, r0, r1
    add r0, r0, r2
    add r7, r7, #1
    b .pb_dec_loop
.pb_have_len:
    cmp r0, #0
    beq .pb_err                        // no digit: len missing
    cmp r0, #PEEK_MAX_LEN
    bhs .pb_err
    mov r5, r0                         // r5 = len
    // ---- window check: r4 = addr, r2 = the matched window's end (every window below).
    movs r2, #0x2000
    lsl r2, r2, #4                     // r2 = 0x20000 (window 0 = the 0x0 SRAM0 alias end)
    cmp r4, r2
    blo .pb_w_ok
    ldr r1, =PEEK_W1_LO
    cmp r4, r1
    blo .pb_err
    ldr r2, =PEEK_W1_HI
    cmp r4, r2
    bhs .pb_w2
    b .pb_w_ok
.pb_w2:
    ldr r1, =PEEK_W2_LO
    cmp r4, r1
    blo .pb_err
    ldr r2, =PEEK_W2_HI
    cmp r4, r2
    bhs .pb_w3
    b .pb_w_ok
.pb_w3:
    ldr r1, =PEEK_W3_LO
    cmp r4, r1
    blo .pb_err
    ldr r2, =PEEK_W3_HI
    cmp r4, r2
    bhs .pb_w4
    b .pb_w_ok
.pb_w4:
    ldr r1, =PEEK_W4_LO
    cmp r4, r1
    blo .pb_err
    ldr r2, =PEEK_W4_HI
    cmp r4, r2
    bhs .pb_err
.pb_w_ok:
    add r1, r4, r5                     // addr + len must stay inside the window
    cmp r1, r2
    bhi .pb_err
    // ---- dump: read the source straight out, chunked 72 <n> <data> FF FF FF frames, each byte
    // via pk_marker (the raw UART2 write). pk_marker clobbers r0-r3 only, so r4/r5/r6/r7 survive
    // every call (the dump loop's live registers).
    mov r6, r4                         // r6 = src
.pb_chunk:
    cmp r5, #0
    beq .pb_done
    cmp r5, #0xFF
    ble .pb_n_ok
    movs r7, #0xFF
    b .pb_n_set
.pb_n_ok:
    mov r7, r5
.pb_n_set:
    movs r0, #0x72
    bl pk_marker
    mov r0, r7
    bl pk_marker
.pb_data:
    ldrb r0, [r6]
    bl pk_marker
    add r6, r6, #1
    subs r5, r5, #1
    subs r7, r7, #1
    bne .pb_data
    movs r0, #0xFF
    bl pk_marker
    movs r0, #0xFF
    bl pk_marker
    movs r0, #0xFF
    bl pk_marker
    b .pb_chunk
.pb_done:
    b .pb_finish
    // ---- error: the 72 FF FF FF frame, then the same -1 return as success.
.pb_err:
    movs r0, #0x72
    bl pk_marker
    movs r0, #0xFF
    bl pk_marker
    movs r0, #0xFF
    bl pk_marker
    movs r0, #0xFF
    bl pk_marker
    b .pb_finish
    // ---- success/error exit: r0 = -1 (the stock's get_String8 not-found value), so the parser
    // takes its stock unknown-command path (the 00 invalid-instruction reply follows our frame).
    // r7 (0x77F3B0) and lr come from the entry push (the bl pk_marker calls never clobber r7/lr).
.pb_finish:
    pop {r0-r7, lr}
    movs r0, #0
    sub r0, r0, #1                     // r0 = -1
    bx lr
    // ---- replay: byte-for-byte the original BL.W - same args, same target, same return point.
    // non-peek lines replay the stock's own get_String8 so its normal handling is preserved.
.pb_replay:
    pop {r0-r7, lr}                    // original args (r0-r3) + the caller's live r7, lr = 0x2A23
    push {r7, lr}                      // r7 must not die in the ldr below; blx clobbers lr
    ldr r7, =GET_STRING8_ADDR          // 0x451D (Thumb); indirect call, no ABS branch relocation
    blx r7                             // get_String8; clobbers r0-r2/r5, preserves r3/r6/r7
    pop {r7, lr}                       // r7 = 0x77F3B0, lr = 0x2A23 again
    bx lr
    .ltorg

.align 2
/* pk_hex_table / pk_dec_table: for ASCII 0..127 the nibble/digit value, or 0xFF = not a digit (the
 * parse loops' stop condition). In the blob (ADR-referenced) so the word-copy to PEEK_BLOB_DST keeps
 * them coherent with the peekblob_entry parse loops. 128 bytes each. */
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

.align 2
/* pk_blink(r0 = 1..6): the blink for the relocated blob (and the in-image dump stages B1..B6) -
 * drives the backlight off for r0 * ~200 ms (200 MHz core, ~2 cycles/iteration), then restores the
 * pin state exactly. Works in BOTH backlight configurations the stock can leave on GPIOC9: TIM8
 * PWM (AF mode 01, the cold-pass bring-up) and plain GPIO output (mode 00, set_dim's dim=100 path):
 * it saves the pin's IOMODE[2]/IOAFR6/OBSR state first, then forces mode 00 (output) + OBSR bit
 * cleared (drive low = the LED off; mode 00 is set_dim's own GPIO mode, low = the inverse of its
 * dim=100 high), busy-waits, and restores all three saved registers verbatim. The blink is the
 * only output channel visible to the bench camera in the stock pass (serial TX from the blob has
 * never been observed), so a blink is the proof of life. PKBLK_SAVE is ADR-referenced (the block
 * is relocated by copy - an absolute ldr would outlive the copy as a stale pointer into the
 * clobbered image). Leaf: clobbers r0-r3 only. */
/* pk_marker(r0 = byte): the relocated blob's own uart_putc. The blob cannot reuse the in-image
 * uart_putc/send_resp (the image at 0x80000 is clobbered by the stock boot), so it re-derives the
 * UART2 TX here: poll UART2_TH's TX FIFO fill level (the exact wait uart_putc uses), then strb the
 * byte to UART2_DR. All four address literals (UART2_TH/MASK/FULL/DR) sit in THIS section's pool
 * (PC-relative ldr) and stay valid after the word copy because the whole block moves as one unit.
 * This is the deterministic reach signal: one 'Z' per 0x2A1E hit, independent of the backlight.
 * Leaf: clobbers r0-r3 only. */
.thumb_func
pk_marker:
    mov r3, r0                        // keep the byte out of r0-r2 while polling
.pk_marker_wait:
    ldr r0, =UART2_TH
    ldr r1, [r0]
    ldr r2, =UART2_TXFIFO_MASK
    ands r1, r1, r2
    ldr r2, =UART2_TXFIFO_FULL
    cmp r1, r2
    bhs .pk_marker_wait
    ldr r0, =UART2_DR
    strb r3, [r0]
    bx lr
    .ltorg

.equ BLINK_UNIT_ITERS, 20000000       // one unit = ~200 ms at 200 MHz (~2 cycles/iteration)
.thumb_func
pk_blink:
    ldr r2, =BLINK_UNIT_ITERS
    mul r2, r2, r0                    // r2 = total delay iterations (the r0 units are consumed now)
    adr r1, PKBLK_SAVE                // ADR on purpose: the block is copied to 0x79D448 at the
                                       // stock hand-off; an absolute ldr would leave the pool
                                       // pointing at the clobbered in-image copy
    ldr r3, =(SYS_BASE + SYS_IOMODE2)
    ldr r0, [r3]
    str r0, [r1]
    ldr r3, =(SYS_BASE + SYS_IOAFR6)
    ldr r0, [r3]
    str r0, [r1, #4]
    ldr r3, =GPIOC_OBSR
    ldr r0, [r3]
    str r0, [r1, #8]
    ldr r3, =(SYS_BASE + SYS_IOMODE2)
    ldr r0, [r3]
    ldr r1, =BL_IOMODE_MASK
    bic r0, r0, r1                    // pin 9 -> mode 00 (plain output, set_dim's own mode)
    str r0, [r3]
    ldr r3, =GPIOC_OBSR
    ldr r0, [r3]
    ldr r1, =BL_PIN_MASK
    bic r0, r0, r1                    // OBSR pin 9 -> 0: the backlight is off
    str r0, [r3]
.pl_blink_loop:
    subs r2, r2, #1
    bne .pl_blink_loop
    adr r1, PKBLK_SAVE                // ADR on purpose: the block is copied to 0x79D448 at the
                                       // stock hand-off; an absolute ldr would leave the pool
                                       // pointing at the clobbered in-image copy
    ldr r3, =(SYS_BASE + SYS_IOMODE2)
    ldr r0, [r1]
    str r0, [r3]
    ldr r3, =(SYS_BASE + SYS_IOAFR6)
    ldr r0, [r1, #4]
    str r0, [r3]
    ldr r3, =GPIOC_OBSR
    ldr r0, [r1, #8]
    str r0, [r3]
    bx lr
    .ltorg

.align 2
/* PKBLK_SAVE: pk_blink's 3 saved register words (IOMODE[2], IOAFR6, GPIOC_OBSR); in the blob. */
PKBLK_SAVE:
    .word 0, 0, 0

.text
