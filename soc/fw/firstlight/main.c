/*
 * firstlight -- kakao32's first program on a board. It runs from
 * 64 KB of block RAM in M-mode, tests the CPU as built into the FPGA,
 * reports on the UART and then echoes what is typed.
 *
 * Every line it prints ends in "ok" or "FAILED"; the last line before
 * the echo says which.
 */

#include <stdint.h>

#define UART_THR (*(volatile uint8_t *)0x10000000)
#define UART_RBR (*(volatile uint8_t *)0x10000000)
#define UART_LSR (*(volatile uint8_t *)0x10000005)
#define MTIMECMP (*(volatile uint32_t *)0x02004000)
#define MTIMECMPH (*(volatile uint32_t *)0x02004004)
#define MTIME    (*(volatile uint32_t *)0x0200bff8)

#define csr_read(c)     ({ uint32_t v_; __asm__ volatile ("csrr %0, " #c : "=r"(v_)); v_; })
#define csr_write(c, v) ({ uint32_t v_ = (v); __asm__ volatile ("csrw " #c ", %0" : : "r"(v_)); })
#define csr_set(c, v)   ({ uint32_t v_ = (v); __asm__ volatile ("csrs " #c ", %0" : : "r"(v_)); })
#define csr_clear(c, v) ({ uint32_t v_ = (v); __asm__ volatile ("csrc " #c ", %0" : : "r"(v_)); })

typedef uint32_t jmp_buf[14];
int k_setjmp(jmp_buf);
void enter_s(void (*fn)(void));

static void putc_(char c) {
	while (!(UART_LSR & 0x20)) ;
	UART_THR = c;
}
static void puts_(const char *s) {
	for (; *s; s++) { if (*s == '\n') putc_('\r'); putc_(*s); }
}
static void hex(uint32_t v) {
	for (int i = 28; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15]);
}
static void dec(uint32_t v) {
	char b[11]; int n = 0;
	do { b[n++] = '0' + v % 10; v /= 10; } while (v);
	while (n) putc_(b[--n]);
}

static int failures;
static void result(const char *what, int ok) {
	puts_(what); puts_(ok ? ": ok\n" : ": FAILED\n");
	if (!ok) failures++;
}

/* -- traps -------------------------------------------------------- */

static jmp_buf *catch;			/* where an exception goes, if anywhere */
static volatile uint32_t t_cause, t_epc, t_tval;
static volatile uint32_t ticks;

void *trap_c(uint32_t cause, uint32_t epc, uint32_t tval) {
	if (cause == 0x80000007) {			/* the machine timer */
		ticks++;
		MTIMECMPH = 0xffffffff;			/* no more of them */
		MTIMECMP = 0xffffffff;
		return 0;
	}
	t_cause = cause; t_epc = epc; t_tval = tval;
	if (!catch) {
		puts_("\nunexpected trap: cause "); hex(cause);
		puts_(" epc "); hex(epc); puts_(" tval "); hex(tval); puts_("\n");
		for (;;) ;
	}
	return catch;
}

/* run fn, which ends in a trap; that trap's cause comes back */
static uint32_t until_trap(void (*fn)(void), int in_s) {
	jmp_buf env;
	t_cause = 0xffffffff;
	catch = &env;
	if (!k_setjmp(env)) {
		if (in_s) enter_s(fn); else fn();
	}
	catch = 0;
	return t_cause;
}

/* -- the tests ------------------------------------------------------- */

static void do_ecall(void)   { __asm__ volatile ("ecall"); }
static void do_illegal(void) { __asm__ volatile (".word 0xffffffff"); }
static void do_misaligned(void) {
	uint32_t v, base = 0x80000100;		/* (in assembly: the compiler would split it) */
	__asm__ volatile ("lw %0, 1(%1)" : "=r"(v) : "r"(base));
}

static volatile uint32_t probe;
static uint32_t pt1[1024] __attribute__((aligned(4096)));
static uint32_t pt0[1024] __attribute__((aligned(4096)));
static uint32_t page[1024] __attribute__((aligned(4096)));
static volatile uint32_t stage;

#define PTE_V 1
#define PTE_R 2
#define PTE_W 4
#define PTE_X 8
#define PTE_A 0x40
#define PTE_D 0x80

/* in S-mode, with paging: memory is at its own address (a megapage)
 * and again 1 GB lower; `page` is at 0x40405000 through a second-level
 * table, and at 0x40406000 without its dirty bit */
static void s_megapage(void) {
	volatile uint32_t *alias = (uint32_t *)((uintptr_t)&probe - 0x40000000);
	*alias = 0xcafe0001;
	stage = (probe == 0xcafe0001) ? 1 : 100;
	__asm__ volatile ("ecall");
}
static void s_small(void) {
	volatile uint32_t *p = (uint32_t *)0x40405000;
	p[7] = 0x600dbeef;
	stage = (page[7] == 0x600dbeef) ? 2 : 100;
	__asm__ volatile ("ecall");
}
static void s_unmapped(void) {
	stage = 3;
	(void)*(volatile uint32_t *)0x10000000;
	stage = 100;
	__asm__ volatile ("ecall");
}
static void s_not_dirty(void) {
	stage = 4;
	*(volatile uint32_t *)0x40406010 = 1;
	stage = 100;
	__asm__ volatile ("ecall");
}

static void test_mmu(void) {
	uint32_t ram1 = 0x80000000u >> 22;		/* memory's megapage */
	pt1[ram1] = (ram1 << 20) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
	pt1[0x100] = (ram1 << 20) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
	pt1[0x101] = (((uint32_t)pt0 >> 12) << 10) | PTE_V;
	pt0[5] = (((uint32_t)page >> 12) << 10) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
	pt0[6] = (((uint32_t)page >> 12) << 10) | PTE_V | PTE_R | PTE_W | PTE_A;
	csr_write(satp, 0x80000000u | ((uint32_t)pt1 >> 12));

	uint32_t c = until_trap(s_megapage, 1);
	result("S-mode, a megapage, ecall back", c == 9 && stage == 1);
	c = until_trap(s_small, 1);
	result("S-mode, a 4 KB page through two levels", c == 9 && stage == 2 && page[7] == 0x600dbeef);
	c = until_trap(s_unmapped, 1);
	result("load page fault on an unmapped address", c == 13 && stage == 3 && t_tval == 0x10000000);
	c = until_trap(s_not_dirty, 1);
	result("store page fault on a clean page", c == 15 && stage == 4 && t_tval == 0x40406010);
	csr_write(satp, 0);
}

static void test_atomics(void) {
	static volatile uint32_t cell = 40;
	uint32_t old, sc1, sc2, lr;
	volatile uint32_t *p = &cell;
	__asm__ volatile ("amoadd.w %0, %2, (%1)" : "=&r"(old) : "r"(p), "r"(2));
	__asm__ volatile ("lr.w %0, (%2)\n sc.w %1, %3, (%2)" : "=&r"(lr), "=&r"(sc1) : "r"(p), "r"(7));
	__asm__ volatile ("sc.w %0, %2, (%1)" : "=&r"(sc2) : "r"(p), "r"(9));
	result("amoadd.w, lr.w and sc.w", old == 40 && lr == 42 && sc1 == 0 && sc2 == 1 && cell == 7);
}

static void test_timer(void) {
	ticks = 0;
	uint32_t t0 = MTIME;
	MTIMECMPH = 0;
	MTIMECMP = t0 + 48000;				/* a millisecond from now */
	csr_set(mie, 0x80);
	csr_set(mstatus, 0x8);
	uint32_t n = 0;
	while (!ticks && n < 2000000) n++;
	uint32_t dt = MTIME - t0;
	csr_clear(mstatus, 0x8);
	csr_clear(mie, 0x80);
	puts_("timer interrupt after "); dec(dt); puts_(" cycles (asked for 48000)");
	result("", ticks == 1 && dt >= 48000 && dt < 60000);
}

static void test_speed(void) {
	volatile uint32_t sink = 0;
	uint32_t c0 = csr_read(mcycle), i0 = csr_read(minstret);
	for (uint32_t i = 0; i < 20000; i++) sink += i;
	uint32_t c = csr_read(mcycle) - c0, i = csr_read(minstret) - i0;
	puts_("a loop of "); dec(i); puts_(" instructions took "); dec(c);
	puts_(" cycles: "); dec(c * 100 / i / 100); putc_('.');
	uint32_t f = c * 100 / i % 100; putc_('0' + f / 10); putc_('0' + f % 10);
	puts_(" each\n");
}

int main(void) {
	puts_("\n\nkakao32 firstlight\n");
	puts_("misa "); hex(csr_read(misa)); puts_("  mtime "); hex(MTIME); puts_("\n");

	volatile uint32_t a = 123456789, b = 1000;
	result("multiply and divide", a * b == 0xbe991a08u && a / b == 123456 && a % b == 789 &&
		(int32_t)(0 - a) / (int32_t)b == -123456);
	result("ecall from M-mode", until_trap(do_ecall, 0) == 11);
	result("illegal instruction", until_trap(do_illegal, 0) == 2 && t_tval == 0xffffffff);
	result("misaligned load", until_trap(do_misaligned, 0) == 4 && t_tval == 0x80000101);
	test_atomics();
	test_timer();
	test_mmu();
	test_speed();

	if (failures) { dec(failures); puts_(" test(s) FAILED\n"); }
	else puts_("all tests passed\n");
	puts_("echo: type something\n");
	for (;;) {
		if (UART_LSR & 1) {
			char c = UART_RBR;
			if (c == '\r') puts_("\n"); else putc_(c);
		}
	}
}
