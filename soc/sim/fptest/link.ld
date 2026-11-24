OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS
{
	. = BASE;
	.text : { *(.text.init) *(.text*) }
	. = ALIGN(16);
	.data : { *(.data*) *(.sdata*) *(.rodata*) *(.bss*) *(.sbss*) }
	_end = .;
	ASSERT(_end - BASE <= 0x10000, "a test is over 64 KB")
}
