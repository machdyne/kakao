OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { ram (rwx) : ORIGIN = 0x80000000, LENGTH = 64K }
SECTIONS {
	.text : { *(.text.init) *(.text .text.*) } > ram
	.rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > ram
	.data : { *(.data .data.* .sdata .sdata.*) } > ram
	. = ALIGN(4096);
	_bss = .;
	.bss : { *(.bss .bss.* .sbss .sbss.* COMMON) } > ram
	. = ALIGN(4);
	_ebss = .;
	_stack = ORIGIN(ram) + LENGTH(ram);
}
