# Start-up for the I/O processor's program: no traps, no interrupts.

	.section .text.init
	.globl _start
_start:
	la sp, _stack
	la t0, _bss
	la t1, _ebss
1:	bgeu t0, t1, 2f
	sw zero, 0(t0)
	addi t0, t0, 4
	j 1b
2:	call main
3:	j 3b
