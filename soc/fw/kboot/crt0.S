# Start-up and the trap entry for kboot (firstlight's, with its setjmp).
# The stack is in the boot ROM's own block RAM, above the code.

/* a register saved: a word on RV32, a doubleword on RV64 (kakao64) */
#if __riscv_xlen == 64
#define SREG sd
#define LREG ld
#define RSZ 8
#else
#define SREG sw
#define LREG lw
#define RSZ 4
#endif

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
	addi sp, sp, -16*RSZ
	SREG ra, 0*RSZ(sp);  SREG t0, 1*RSZ(sp);  SREG t1, 2*RSZ(sp);  SREG t2, 3*RSZ(sp)
	SREG a0, 4*RSZ(sp); SREG a1, 5*RSZ(sp); SREG a2, 6*RSZ(sp); SREG a3, 7*RSZ(sp)
	SREG a4, 8*RSZ(sp); SREG a5, 9*RSZ(sp); SREG a6, 10*RSZ(sp); SREG a7, 11*RSZ(sp)
	SREG t3, 12*RSZ(sp); SREG t4, 13*RSZ(sp); SREG t5, 14*RSZ(sp); SREG t6, 15*RSZ(sp)
	csrr a0, mcause
	csrr a1, mepc
	csrr a2, mtval
	call trap_c
	bnez a0, 1f
	LREG ra, 0*RSZ(sp);  LREG t0, 1*RSZ(sp);  LREG t1, 2*RSZ(sp);  LREG t2, 3*RSZ(sp)
	LREG a0, 4*RSZ(sp); LREG a1, 5*RSZ(sp); LREG a2, 6*RSZ(sp); LREG a3, 7*RSZ(sp)
	LREG a4, 8*RSZ(sp); LREG a5, 9*RSZ(sp); LREG a6, 10*RSZ(sp); LREG a7, 11*RSZ(sp)
	LREG t3, 12*RSZ(sp); LREG t4, 13*RSZ(sp); LREG t5, 14*RSZ(sp); LREG t6, 15*RSZ(sp)
	addi sp, sp, 16*RSZ
	mret
1:	la t0, k_longjmp
	csrw mepc, t0
	li t0, 0x1800			# mstatus.MPP = M
	csrs mstatus, t0
	mret

# int k_setjmp(jmp_buf): 0 now, 1 when a trap comes back here
	.globl k_setjmp
k_setjmp:
	SREG ra, 0*RSZ(a0);   SREG sp, 1*RSZ(a0);   SREG s0, 2*RSZ(a0);   SREG s1, 3*RSZ(a0)
	SREG s2, 4*RSZ(a0);  SREG s3, 5*RSZ(a0);  SREG s4, 6*RSZ(a0);  SREG s5, 7*RSZ(a0)
	SREG s6, 8*RSZ(a0);  SREG s7, 9*RSZ(a0);  SREG s8, 10*RSZ(a0);  SREG s9, 11*RSZ(a0)
	SREG s10, 12*RSZ(a0); SREG s11, 13*RSZ(a0)
	li a0, 0
	ret

k_longjmp:
	LREG ra, 0*RSZ(a0);   LREG sp, 1*RSZ(a0);   LREG s0, 2*RSZ(a0);   LREG s1, 3*RSZ(a0)
	LREG s2, 4*RSZ(a0);  LREG s3, 5*RSZ(a0);  LREG s4, 6*RSZ(a0);  LREG s5, 7*RSZ(a0)
	LREG s6, 8*RSZ(a0);  LREG s7, 9*RSZ(a0);  LREG s8, 10*RSZ(a0);  LREG s9, 11*RSZ(a0)
	LREG s10, 12*RSZ(a0); LREG s11, 13*RSZ(a0)
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
