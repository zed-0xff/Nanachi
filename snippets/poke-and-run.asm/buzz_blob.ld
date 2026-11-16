/*
 * Linker script for the self-contained beep blob (poked + blx'd on the running panel).
 *
 * Links buzz_blob.S as-is at 0x650000 (a proven-writable SDRAM scratch region).
 * Layout: .vector_table (0x40, loader-only baggage, never read on the blx path) at
 * 0x650000, then .text (entry function + its literal pool + the melody table, all
 * contiguous) right after. `entry` loads `melody` from its own literal pool, so the
 * linked addresses are self-consistent and a `blx entry` needs no arguments.
 */

ENTRY(entry)

SECTIONS
{
    . = 0x650000;  /* Load address: SDRAM scratch (arena), proven poke-writable on the stock pass */

    .vector_table : {
        *(.vector_table)
    }

    .text : {
        *(.text)
    }

    .rodata : {
        *(.rodata)
    }

    .data : {
        *(.data)
    }

    _end = .;
}
