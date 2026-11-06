/* cmd_fun.S - the fun/fur commands of the 0x2A1E command blob (included by cmd.S inside the
 * .peekblob section, the same translation unit, no .globl / no section switches).
 *
 * Syntax:
 *   fun0 <addr>                    call the procedure at <addr>, no args; result discarded
 *   fun1 <addr>,<arg0>             call <addr> with r0 = <arg0>; result discarded
 *   fun2 <addr>,<arg0>,<arg1>      call <addr> with r0 = <arg0>, r1 = <arg1>; result discarded
 *   fur0 <addr>                    call <addr>, no args; the returned r0 is printed
 *   fur1 <addr>,<arg0>             call <addr> with r0 = <arg0>; the returned r0 is printed
 *   fur2 <addr>,<arg0>,<arg1>      call <addr> with r0 = <arg0>, r1 = <arg1>; the returned r0
 *                                   is printed
 *   <addr>: the function's own address (hex, 0x optional) - called directly with `blx addr`.
 *           Pass the exact (odd/Thumb) address of the function; the value is NOT dereferenced.
 *           No range/window check is applied (the caller's choice - a bad address faults).
 *   <arg0>/<arg1>: hex (0x optional).
 *
 * Reply: one 0x5A beacon (every 0x2A1E hit, emitted by the entry before dispatch), then:
 *   fun*  -> no frame (the return is discarded); the stock's own 00 ack follows.
 *   fur*  -> a readback frame 72 04 <4B LE r0> FF FF FF (the peek/poke readback shape - the
 *            host reads it with its existing peek parser), then the stock's 00 ack.
 *   bad syntax (a missing ',' where an arg is required / a non-hex byte in a hex field)
 *            -> the error frame 72 FF FF FF, then the stock's 00 ack.
 *
 * Registers: called from the entry with bl (r4 = N (0-2), r5 = print (0/1), r7 = the field
 * start = the 'f' of "fun"/"fur"; the data starts at r7+5 - the same token width as "peek ").
 * `bl` does NOT push a frame, so sp is the entry frame (peekblob_entry's push {r0-r7,lr})
 * throughout and MUST NOT be moved here or in ph_hex/ph_sep: pb_exit's terminal pop relies on
 * it (the v2t/v2u incident). r8-r11 (callee-saved) must stay pristine: the stock calls the
 * blob via a bl and may hold live values there, so this file uses only r0-r7 and r12.
 *
 * The r5 print flag is read (cbz) BEFORE the `blx r12`, when it is still valid: the function
 * at <addr> follows the AAPCS and clobbers r0-r7/r12, so the flag cannot be read after the
 * call. Two `blx` paths result (the fur path captures r0 and prints it; the fun path just
 * returns). r12 = the <addr> blx target; after the call r0 = the return is re-captured into
 * r12 for the print (pk_marker clobbers r0-r3, so the value must live in r12 - r12 survives
 * every pk_marker). ph_hex/ph_sep are leaves; ph_sep b's to pb_exit_err on a missing comma
 * (the entry frame is intact, so the error terminal's pop is valid). */

.thumb_func
pb_fun:
    add r7, r7, #5                     // r7 = the data start (just past "funN "/"furN ")
    bl ph_hex                          // r0 = <addr>; r7 at the following delimiter
    mov r12, r0                        // r12 = <addr> (the blx target; survives the parse)
    // ---- N is in r4 (set by the entry). Branch on it BEFORE any clobber.
    cmp r4, #0
    beq .pf_n0
    cmp r4, #1
    beq .pf_n1
    // ---- N == 2: parse both args
    bl ph_sep                          // skip the ',' (b pb_exit_err if missing)
    bl ph_hex                          // r0 = <arg0>
    mov r4, r0                         // r4 = <arg0>
    bl ph_sep
    bl ph_hex                          // r0 = <arg1>
    mov r1, r0                         // r1 = <arg1>
    mov r0, r4                         // r0 = <arg0>
    b .pf_decide
.pf_n1:
    bl ph_sep
    bl ph_hex                          // r0 = <arg0>
    movs r1, #0                        // r1 = 0 (no <arg1>)
    b .pf_decide
.pf_n0:
    movs r0, #0                        // r0 = 0 (no args)
    movs r1, #0
.pf_decide:
    // r5 = the print flag (still valid: the parse only clobbers r0-r3/r7, not r5).
    cbz r5, .pf_noprint
    // ---- fur*: call, capture the return, print 72 04 <4B LE> FF FF FF
    blx r12                            // call <addr>; on return r0 = the function's r0
    mov r12, r0                        // r12 = the return (captured before pk_marker clobbers r0)
    movs r0, #0x72
    bl pk_marker
    movs r0, #0x04
    bl pk_marker
    mov r0, r12                        // byte 0 (least significant)
    bl pk_marker
    mov r0, r12, lsr #8               // byte 1
    bl pk_marker
    mov r0, r12, lsr #16              // byte 2
    bl pk_marker
    mov r0, r12, lsr #24              // byte 3 (most significant)
    bl pk_marker
    movs r0, #0xFF
    bl pk_marker
    movs r0, #0xFF
    bl pk_marker
    movs r0, #0xFF
    bl pk_marker
    b pb_exit
.pf_noprint:
    blx r12                            // fun*: call <addr>, discard the return
    b pb_exit

/* --------------------------------------------------------------------------
 *  ph_sep(r7 = cursor): skip an optional run of spaces, then a REQUIRED ',', then optional
 *  spaces, advancing r7 (the cursor). Leaf on r7; clobbers r0. A missing ',' (the field ended
 *  or is malformed) is a syntax error -> b pb_exit_err (the entry frame is intact, so the
 *  error terminal's pop is valid). Used between <addr>/<arg0>/<arg1>. */
.thumb_func
ph_sep:
.ph_s1:
    ldrb r0, [r7]
    cmp r0, #' '
    beq .ph_s1s
    cmp r0, #','
    bne .ph_s_err
    add r7, r7, #1
.ph_s2:
    ldrb r0, [r7]
    cmp r0, #' '
    beq .ph_s2s
    bx lr
.ph_s1s:
    add r7, r7, #1                     // advance (a beq-without-advance = infinite loop)
    b .ph_s1
.ph_s2s:
    add r7, r7, #1                     // advance (a beq-without-advance = infinite loop)
    b .ph_s2
.ph_s_err:
    b pb_exit_err

/* --------------------------------------------------------------------------
 *  ph_hex(r7 = cursor): parse one hex field - optional leading spaces, optional "0x"/"0X"
 *  prefix, then hex digits until a non-hex byte (a ',' or the end of field). Out: r0 = the
 *  value, r7 = just past the last digit (NOT past the following ',' - the caller's ph_sep
 *  consumes that). A field with no digits (e.g. "0x" alone) yields 0. Clobbers r0-r3, r7;
 *  no push, no sp move. The table reference is ADR (PC-relative, in-blob) so the word-copy
 *  to PEEK_BLOB_DST stays coherent - the same idiom peek/poke use. */
.thumb_func
ph_hex:
.ph_hsp:
    ldrb r2, [r7]
    cmp r2, #' '
    beq .ph_hsp_s
    b .ph_0x
.ph_hsp_s:
    add r7, r7, #1                     // advance (a beq-without-advance = infinite loop)
    b .ph_hsp
.ph_0x:
    ldrb r2, [r7]
    cmp r2, #'0'
    bne .ph_init
    ldrb r3, [r7, #1]
    cmp r3, #'x'
    bne .ph_init
    cmp r3, #'X'
    bne .ph_init
    add r7, r7, #2                     // skip the "0x"/"0X" prefix
.ph_init:
    movs r0, #0
.ph_dl:
    ldrb r2, [r7]
    adr r3, pk_hex_table               // PC-relative, in-blob
    ldrb r2, [r3, r2]
    cmp r2, #0xFF
    beq .ph_done
    lsl r0, r0, #4
    add r0, r0, r2
    add r7, r7, #1
    b .ph_dl
.ph_done:
    bx lr
