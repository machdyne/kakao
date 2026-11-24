# The three machine interrupts: each alone, all three at once (taken in
# the order external, software, timer), and held off by mstatus.MIE and
# by mie. The test bench's interrupt lines are at 0xe0000014: bit 0
# MSI, bit 1 MTI, bit 2 MEI.

#include "riscv_test.h"
#include "test_macros.h"

#define IRQ_LINES 0xe0000014

RVTEST_RV32M
RVTEST_CODE_BEGIN

  # s0: the lines' address; s1: how many interrupts were taken;
  # s2: their causes, four bits each, the latest lowest;
  # s3: the lines still raised (the handler lowers the one it takes)
  li s0, IRQ_LINES
  li s1, 0
  li s2, 0

  # -- each alone ---------------------------------------------------
  li t0, 0x888
  csrw mie, t0
  csrsi mstatus, 8

  li TESTNUM, 2
  li s3, 1; sw s3, 0(s0)        # MSI
  nop; nop; nop; nop
  li t0, 1; bne s1, t0, fail
  li t0, 0x3; bne s2, t0, fail

  li TESTNUM, 3
  li s3, 2; sw s3, 0(s0)        # MTI
  nop; nop; nop; nop
  li t0, 2; bne s1, t0, fail
  li t0, 0x37; bne s2, t0, fail

  li TESTNUM, 4
  li s3, 4; sw s3, 0(s0)        # MEI
  nop; nop; nop; nop
  li t0, 3; bne s1, t0, fail
  li t0, 0x37b; bne s2, t0, fail

  # -- mstatus.MIE off: pending in mip, not taken ----------------------
  li TESTNUM, 5
  csrci mstatus, 8
  li s3, 7; sw s3, 0(s0)
  nop; nop; nop; nop
  li t0, 3; bne s1, t0, fail
  csrr t1, mip
  li t0, 0x888; bne t1, t0, fail

  # -- on again: all three, external first, then software, then timer --
  li TESTNUM, 6
  li s2, 0
  csrsi mstatus, 8
  nop; nop; nop; nop
  li t0, 6; bne s1, t0, fail
  li t0, 0xb37; bne s2, t0, fail
  csrr t1, mip
  bnez t1, fail

  # -- mie masks: only the timer's is enabled ----------------------------
  li TESTNUM, 7
  li s2, 0
  li t0, 0x080
  csrw mie, t0
  li s3, 7; sw s3, 0(s0)
  nop; nop; nop; nop
  li t0, 7; bne s1, t0, fail
  li t0, 0x7; bne s2, t0, fail
  csrr t1, mip
  li t0, 0x808; bne t1, t0, fail
  sw x0, 0(s0)

  # -- an interrupt between a load and its use, and around a divide ------
  li TESTNUM, 8
  li t0, 0x888
  csrw mie, t0
  la t2, word
  li s3, 2; sw s3, 0(s0)
  lw t3, 0(t2)
  addi t3, t3, 1
  li t4, 1000
  li t5, 7
  div t6, t4, t5
  li t0, 0x12345679; bne t3, t0, fail
  li t0, 142; bne t6, t0, fail
  li t0, 8; bne s1, t0, fail

  TEST_PASSFAIL

  # In the handler: mstatus.MIE is off and MPIE on, mcause is an
  # interrupt, mepc is in the test. It lowers the line it was given.
  .align 2
  .global mtvec_handler
mtvec_handler:
  csrr a0, mcause
  bgez a0, fail
  csrr a1, mstatus
  andi a2, a1, 8
  bnez a2, fail
  andi a2, a1, 0x80
  beqz a2, fail
  andi a0, a0, 0xf
  slli s2, s2, 4
  or s2, s2, a0
  addi s1, s1, 1
  li a2, 3;  li a3, 1; beq a0, a2, 1f
  li a2, 7;  li a3, 2; beq a0, a2, 1f
  li a2, 11; li a3, 4; beq a0, a2, 1f
  j fail
1:
  not a3, a3
  and s3, s3, a3
  sw s3, 0(s0)
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
word: .word 0x12345678
RVTEST_DATA_END
