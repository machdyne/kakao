# Start-up, the trap entry and setjmp/longjmp for firstlight.

	.section .text.init
	.globl _start
_start:
	la sp, _stack
	la t0, trap_entry
	csrw mtvec, t0
	la t0, _bss
	la t1, _ebss
1:	bgeu t0, t1, 2f
	sw zero, 0(t0)
	addi t0, t0, 4
	j 1b
2:	call main
3:	j 3b

# Every trap comes here, in M-mode. trap_c(cause, epc, tval) returns 0
# to go back to what was interrupted, or a jmp_buf: then the trapped
# code is abandoned and k_setjmp returns 1 there, in M-mode.
	.align 2
trap_entry:
	addi sp, sp, -64
	sw ra, 0(sp);  sw t0, 4(sp);  sw t1, 8(sp);  sw t2, 12(sp)
	sw a0, 16(sp); sw a1, 20(sp); sw a2, 24(sp); sw a3, 28(sp)
	sw a4, 32(sp); sw a5, 36(sp); sw a6, 40(sp); sw a7, 44(sp)
	sw t3, 48(sp); sw t4, 52(sp); sw t5, 56(sp); sw t6, 60(sp)
	csrr a0, mcause
	csrr a1, mepc
	csrr a2, mtval
	call trap_c
	bnez a0, 1f
	lw ra, 0(sp);  lw t0, 4(sp);  lw t1, 8(sp);  lw t2, 12(sp)
	lw a0, 16(sp); lw a1, 20(sp); lw a2, 24(sp); lw a3, 28(sp)
	lw a4, 32(sp); lw a5, 36(sp); lw a6, 40(sp); lw a7, 44(sp)
	lw t3, 48(sp); lw t4, 52(sp); lw t5, 56(sp); lw t6, 60(sp)
	addi sp, sp, 64
	mret
1:	la t0, k_longjmp
	csrw mepc, t0
	li t0, 0x1800			# mstatus.MPP = M
	csrs mstatus, t0
	mret

# int k_setjmp(jmp_buf): 0 now, 1 when a trap comes back here
	.globl k_setjmp
k_setjmp:
	sw ra, 0(a0);   sw sp, 4(a0);   sw s0, 8(a0);   sw s1, 12(a0)
	sw s2, 16(a0);  sw s3, 20(a0);  sw s4, 24(a0);  sw s5, 28(a0)
	sw s6, 32(a0);  sw s7, 36(a0);  sw s8, 40(a0);  sw s9, 44(a0)
	sw s10, 48(a0); sw s11, 52(a0)
	li a0, 0
	ret

k_longjmp:
	lw ra, 0(a0);   lw sp, 4(a0);   lw s0, 8(a0);   lw s1, 12(a0)
	lw s2, 16(a0);  lw s3, 20(a0);  lw s4, 24(a0);  lw s5, 28(a0)
	lw s6, 32(a0);  lw s7, 36(a0);  lw s8, 40(a0);  lw s9, 44(a0)
	lw s10, 48(a0); lw s11, 52(a0)
	li a0, 1
	ret

# void enter_s(void (*fn)(void)): run fn in S-mode (it does not return:
# it ends in a trap)
	.globl enter_s
enter_s:
	csrw mepc, a0
	li t0, 0x1800
	csrc mstatus, t0
	li t0, 0x0800			# mstatus.MPP = S
	csrs mstatus, t0
	mret
