/*
 * Linker script for the stage1 bootloader.
 *
 * Linked at 0x80000 on purpose: this is where the stage 0 loader (loader.c
 * sub_20002F38) copies the SD image, sets VTOR=0x80000 and jumps. The vector
 * table therefore already holds the absolute addresses the loader expects.
 *
 * Layout: the loader only ever reads two words of this image (word 0 -> MSP,
 * word 1 -> entry address, both absolute, see stage1.S's .vectors comment),
 * so the entry address does not need to sit right after the vector table.
 * fw_pack.pack() overwrites image offsets 0x1C8..0x267 with the container
 * header (CRCs, length); keeping the vector table (0x40 bytes) at offset 0
 * and jumping the rest of the image (code, literal pool, data) to file
 * offset 0x800 - the same boundary fw_pack already requires as the image's
 * minimum size - avoids that zone without having to keep the whole program
 * under a ~400-byte budget.
 */

ENTRY(entry)

SECTIONS
{
    . = 0x80000;  /* Load address in RAM */

    .vectors : {
        *(.vector_table)
    }

    /* Skip the container-header zone (0x1C8..0x267); objcopy -O binary zero-fills the gap. */
    . = 0x80000 + 0x800;

    .text : {
        *(.text)
    }

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
