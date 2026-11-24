# The simulation's boot ROM: memory is already loaded, so turn the
# cache's data side and write buffer on, and enter OpenSBI as a boot
# loader would: a0 the hart, a1 the device tree. OpenSBI is at
# 0x81e0_0000 and the device tree at 0x81f0_0000, as kboot has them on
# the boards (boards/README.md).

#ifndef SBI_AT
#define SBI_AT 0x81e00000
#define DTB_AT 0x81f00000
#endif

	.text
	.globl _start
_start:
	li t0, 0x03000110
	li t1, 5
	sw t1, 0(t0)
	li a0, 0
	// (SBI_AT and DTB_AT halved and shifted: the same instructions
	// make the same addresses on a 32 and a 64 bit CPU)
	li a1, DTB_AT >> 1
	slli a1, a1, 1
	li t0, SBI_AT >> 1
	slli t0, t0, 1
	jr t0
