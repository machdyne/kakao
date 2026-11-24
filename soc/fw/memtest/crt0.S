# Start-up for memtest: a stack, and any trap is a failure.

	.section .text.init
	.globl _start
_start:
	la sp, _stack
	la t0, trap
	csrw mtvec, t0
	call main
1:	j 1b

	.align 2
trap:
	csrr a0, mcause
	csrr a1, mepc
	csrr a2, mtval
	call trapped
1:	j 1b
