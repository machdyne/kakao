OUTPUT_ARCH(riscv)
ENTRY(_start)
/* the boot ROM is block RAM at 0x1000, ROM_SIZE bytes of it (the
   Makefile's): code, data and stack */
MEMORY { rom (rwx) : ORIGIN = 0x00001000, LENGTH = ROM_SIZE }
SECTIONS {
	.text : { *(.text.init) *(.text .text.*) } > rom
	.rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > rom
	.data : { *(.data .data.* .sdata .sdata.*) } > rom
	. = ALIGN(8);
	_bss = .;
	.bss : { *(.bss .bss.* .sbss .sbss.* COMMON) } > rom
	. = ALIGN(8);
	_ebss = .;
	_stack = ORIGIN(rom) + LENGTH(rom);
}
