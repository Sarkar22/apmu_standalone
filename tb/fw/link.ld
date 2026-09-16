/* APMU test firmware: code in ISPM, data/stack in DSPM (he-soc default pmu_top addresses). */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    /* ISPM_NUM_WORDS=1024 -> 4 KiB at 0x10427000. Linked 4 bytes low because of the APMU fetch
       skew (see crt0.S): the image is LOADED at 0x10427000 and runs as if located at 0x10426FFC. */
    ISPM (rx) : ORIGIN = 0x10426FFC, LENGTH = 0x1000
    DSPM (rw) : ORIGIN = 0x10428200, LENGTH = 0x7E00     /* first 0x200 bytes = TB mailbox */
}

SECTIONS
{
    .text : {
        KEEP(*(.text.pad))
        KEEP(*(.text.init))
        . = ALIGN(0x100);
        KEEP(*(.text.trap))
        *(.text .text.*)
        . = ALIGN(4);
    } > ISPM

    .dspm_hdr : {
        LONG(0x0DA7A5EC)
    } > DSPM

    .rodata : {
        . = ALIGN(4);
        *(.srodata .srodata.*)
        *(.rodata .rodata.*)
        . = ALIGN(4);
    } > DSPM

    .data : {
        . = ALIGN(4);
        *(.sdata .sdata.*)
        *(.data .data.*)
        . = ALIGN(4);
    } > DSPM

    .bss (NOLOAD) : {
        . = ALIGN(4);
        _bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > DSPM

    .stack (NOLOAD) : {
        . = ALIGN(4);
        . += 0x800;
        _stack_end = .;
    } > DSPM

    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.note*) *(.eh_frame*) }
}
