#include "riscv_test.h"
	.section .text.init
	.globl _start
_start:
	SBI_PUTC(' '); SBI_PUTC('A'); SBI_PUTC('L'); SBI_PUTC('L'); SBI_PUTC(' ')
	SBI_PUTC('P'); SBI_PUTC('A'); SBI_PUTC('S'); SBI_PUTC('S'); SBI_PUTC('\n')
	SBI_OFF
