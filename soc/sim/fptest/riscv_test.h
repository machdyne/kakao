/*
 * riscv-tests' environment for a program under the SBI firmware: in
 * S-mode, at 0x8020_0000 and every 64 KB after it, one test behind the
 * other. A test that passes prints a dot and goes on to the next; the
 * last "test" is done.S. One that fails says which (its place in the
 * row, and riscv-tests' number within it) and turns the machine off.
 *
 * This is how the floating point that the firmware emulates is tested
 * (rv64uf, rv64ud): the same image runs on QEMU's virt, whose floating
 * point is its own, and on the Kakao SOC.
 */
#ifndef _ENV_SBI_H
#define _ENV_SBI_H

#include "encoding.h"

#define RVTEST_RV64U
#define RVTEST_RV64UF
#define RVTEST_RV32U
#define RVTEST_RV32UF

#define TESTNUM gp

#define SBI_PUTC(c) li a0, c; li a7, 1; ecall
#define SBI_OFF     li a0, 0; li a1, 0; li a6, 0; li a7, 0x53525354; ecall; 1: j 1b

#define RVTEST_CODE_BEGIN \
	.section .text.init; \
	.globl _start; \
_start: \
	la t0, _fail_trap; \
	csrw stvec, t0; \
	li t0, SSTATUS_FS; \
	csrs sstatus, t0; \
	fscsr x0; \
	li TESTNUM, 0; \
	j _begin; \
	.align 2; \
_fail_trap: \
	li TESTNUM, 255; \
	j fail; \
_begin:

#define RVTEST_CODE_END

#define RVTEST_PASS \
	SBI_PUTC('.'); \
	la t0, _start; \
	li t1, 0x10000; \
	add t0, t0, t1; \
	jr t0

/* "F", the test's place as two letters, the number as three digits */
#define RVTEST_FAIL \
	SBI_PUTC('F'); \
	SBI_PUTC('A' + TEST_INDEX / 26); \
	SBI_PUTC('a' + TEST_INDEX % 26); \
	li t3, 100; divu t4, TESTNUM, t3; addi a0, t4, '0'; li a7, 1; ecall; \
	remu TESTNUM, TESTNUM, t3; li t3, 10; divu t4, TESTNUM, t3; addi a0, t4, '0'; li a7, 1; ecall; \
	remu t4, TESTNUM, t3; addi a0, t4, '0'; li a7, 1; ecall; \
	SBI_PUTC('\n'); \
	SBI_OFF

#define EXTRA_DATA
#define RVTEST_DATA_BEGIN .align 4;
#define RVTEST_DATA_END

#endif
