OUTPUT_ARCH(riscv)
ENTRY(_start)
/* kakao_soc's boot memory: 16 KB at 0x1000, writable */
MEMORY { rom (rwx) : ORIGIN = 0x00001000, LENGTH = 16K }
SECTIONS {
	.text : { *(.text.init) *(.text .text.*) } > rom
	.rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > rom
	.data : { *(.data .data.* .sdata .sdata.*) *(.bss .bss.* .sbss .sbss.* COMMON) } > rom
	_stack = ORIGIN(rom) + LENGTH(rom);
}
