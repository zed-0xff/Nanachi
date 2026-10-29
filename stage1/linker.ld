/*
 * Linker script for the minimal stage1 bootloader.
 *
 * Linked at 0x80000 on purpose: this is where the stage 0 loader (loader.c
 * sub_20002F38) copies the SD image, sets VTOR=0x80000 and jumps. The vector
 * table therefore already holds the absolute addresses the loader expects.
 */

ENTRY(entry)

SECTIONS
{
    . = 0x80000;  /* Load address in RAM */

    .text : {
        *(.vector_table)
        *(.text)
    }

    /* fw_pack.pack() writes the container header (CRC32s, length) into image offsets 0x1C8..0x267, over whatever
     * is there: code, vectors and literal pool must end before it. */
    ASSERT(. <= 0x80000 + 0x1C8, "stage1 image overlaps the container header area 0x1C8..0x267")

    .rodata : {
        *(.rodata)
    }

    .image : {
        _image_start = .;
        *(.image)
        _image_end = .;
    }

    .data : {
        _data_start = .;
        *(.data)
        _data_end = .;
    }

    .bss : {
        _bss_start = .;
        *(.bss)
        _bss_end = .;
    }

    _end = .;
}
