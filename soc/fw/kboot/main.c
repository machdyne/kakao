/*
 * kboot -- the Kakao SOC's boot ROM.
 *
 * On a board with DDR3 it trains that (Zeitlos's trainer, taken from
 * its BIOS at build time: ddr3_train.inc); on one with SDRAM
 * (KBOOT_SDRAM: 32 MB) there is nothing to train. It tests a little of
 * the memory, and if that went well boots from the SD card (sdboot.c). Without a card, or
 * without /sys/linux/boot.json on it, it takes commands from the UART,
 * which tools/kload.py sends:
 *
 *   'L' address length data...   load: four bytes each of address and
 *                                length, low byte first, then the data.
 *                                Answered with "sum xxxxxxxx\n", the sum
 *                                of the bytes as stored (read back).
 *   'G'                          go: start what was loaded first (OpenSBI)
 *                                with a0 = 0 and a1 = 0x81f0_0000, the
 *                                device tree
 *   'T'                          train and test again
 *   'S'                          boot from the SD card
 *
 * Anything else is answered with '?'.
 */

#include <stdint.h>

#define UART_THR (*(volatile uint8_t *)0x10000000)
#define UART_RBR (*(volatile uint8_t *)0x10000000)
#define UART_LSR (*(volatile uint8_t *)0x10000005)

#define MEM_MAIN 0x80000000u
/* (a 64 bit machine has OpenSBI at the bottom of memory and the device
 * tree out of the kernel's way: the Makefile says where) */
#ifndef DTB_ADDR
#define DTB_ADDR 0x81f00000u
#endif

static void putc_(char c) {
	while (!(UART_LSR & 0x20)) ;
	UART_THR = c;
}
void print(const char *s) {
	for (; *s; s++) { if (*s == '\n') putc_('\r'); putc_(*s); }
}
void print_hex(uint32_t v, int digits) {
	for (int i = (digits - 1) * 4; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15]);
}

#ifdef KBOOT_SDRAM
/* the cache's control (rtl/k_cache.v), which the DDR3's trainer has as
   its own */
#define reg_dcache_ctrl (*(volatile uint32_t *)0x03000110)
static int ddr3_train(void) { return 1; }
#else
#include "ddr3_train.inc"
#endif

/* a trap here is a bug or a broken memory: say so and stop */
void *trap_c(uint32_t cause, uint32_t epc, uint32_t tval) {
	print("\nkboot: trap, cause "); print_hex(cause, 8);
	print(" epc "); print_hex(epc, 8); print(" tval "); print_hex(tval, 8); print("\n");
	for (;;) ;
}

static int overrun;
static uint8_t getc_(void) {
	uint8_t s;
	while (!((s = UART_LSR) & 1)) ;
	if (s & 2) overrun = 1;
	return UART_RBR;
}
static uint32_t get32(void) {
	uint32_t v = getc_();
	v |= (uint32_t)getc_() << 8;
	v |= (uint32_t)getc_() << 16;
	v |= (uint32_t)getc_() << 24;
	return v;
}

/* a megabyte at each of a few places, written and then read back, with
 * the cache on: each word holds its own address, scrambled */
static int memtest(void) {
#ifdef KBOOT_SDRAM
	static const uint32_t at[] = { 0x00100000, 0x00f00000, 0x01700000, 0x01f00000 };
#else
	static const uint32_t at[] = { 0x00100000, 0x03f00000, 0x0ff00000, 0x1ff00000 };
#endif
	int bad = 0;
	for (int k = 0; k < 4; k++) {
		volatile uint32_t *m = (volatile uint32_t *)(MEM_MAIN + at[k]);
		for (uint32_t i = 0; i < 0x40000; i += 61) m[i] = ((uint32_t)&m[i] * 2654435761u) ^ 0x5a5a5a5a;
	}
	for (int k = 0; k < 4; k++) {
		volatile uint32_t *m = (volatile uint32_t *)(MEM_MAIN + at[k]);
		for (uint32_t i = 0; i < 0x40000; i += 61)
			if (m[i] != (((uint32_t)&m[i] * 2654435761u) ^ 0x5a5a5a5a)) {
				if (!bad) { print("memory: at "); print_hex((uint32_t)&m[i], 8);
					print(" read "); print_hex(m[i], 8); print("\n"); }
				bad++;
			}
	}
	print("memory test "); print(bad ? "FAILED\n" : "ok\n");
	return !bad;
}

#include "sdboot.c"

static int bring_up(void) {
	int ok = ddr3_train();
	/* the cache's data side and its write buffer, off during training */
	reg_dcache_ctrl = ok ? 5 : 0;
	if (ok) ok = memtest();
	return ok;
}

static uint32_t first;				/* where the first load went: what 'G' starts */
static int loads;

static void load(void) {
	uint32_t adr = get32(), len = get32(), sum = 0;
	if (!loads++) first = adr;
	volatile uint8_t *p = (volatile uint8_t *)adr;
	overrun = 0;
	for (uint32_t i = 0; i < len; i++) p[i] = getc_();
	for (uint32_t i = 0; i < len; i++) sum += p[i];
	if (overrun) print("overrun\n");
	else { print("sum "); print_hex(sum, 8); print("\n"); }
}

int main(void) {
	print("\n\nkboot\n");
	if (bring_up()) sd_boot();
	print("ready\n");
	for (;;) {
		uint8_t c = getc_();
		if (c == 'L') load();
		else if (c == 'T') { bring_up(); print("ready\n"); }
		else if (c == 'S') { sd_boot(); print("ready\n"); }
		else if (c == 'G') {
			print("go\n");
			while (!(UART_LSR & 0x40)) ;
			((void (*)(unsigned long, unsigned long))(uintptr_t)(loads ? first : MEM_MAIN))(0, (unsigned long)DTB_ADDR);
		} else putc_('?');
	}
}
