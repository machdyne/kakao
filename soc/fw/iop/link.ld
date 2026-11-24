OUTPUT_ARCH(riscv)
ENTRY(_start)
/* the I/O processor's memory: RAM_WORDS in rtl/k_iop.v (the Makefile
   passes its size in bytes) */
MEMORY { ram (rwx) : ORIGIN = 0x00000000, LENGTH = RAM_BYTES }
SECTIONS {
	.text : { *(.text.init) *(.text .text.*) } > ram
	.rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > ram
	.data : { *(.data .data.* .sdata .sdata.*) } > ram
	. = ALIGN(4);
	_bss = .;
	.bss : { *(.bss .bss.* .sbss .sbss.* COMMON) } > ram
	. = ALIGN(4);
	_ebss = .;
	/* what is left is the stack: at least 512 bytes of it */
	ASSERT(_ebss + 512 <= ORIGIN(ram) + LENGTH(ram), "the I/O processor's program does not fit")
	_stack = ORIGIN(ram) + LENGTH(ram);
}
