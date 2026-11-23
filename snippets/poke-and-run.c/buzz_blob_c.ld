/*
 * Linker script for the C buzz blob (poked into panel SDRAM, blx'd on the
 * running panel).
 *
 * Links buzz_blob.c at 0x650000 (a proven poke-writable SDRAM scratch
 * region), entry included. No .vector_table — unlike the assembly image,
 * this blob is only ever blx'd (`fun 0x650001`), never VTOR'd, so entry
 * sits right at 0x650000 and the blx target is 0x650001. `entry` loads the
 * melody table from its own .rodata, so the linked addresses are
 * self-consistent and a `blx entry` needs no arguments.
 */

ENTRY(entry)

SECTIONS
{
    . = 0x650000;  /* load address: SDRAM scratch (arena) */

    .text : {
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
    }

    .data : {
        *(.data .data.*)
    }

    _end = .;
}
