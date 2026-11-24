/*
 * memtest: main memory through the cache, from kakao_soc's boot
 * memory. It is for the simulation of the SOC on Zeitlos's DDR3
 * controller and a checking DRAM model (sim/tb_soc_ddr3.v), where the
 * question is whether k_cache and the controller understand each
 * other: line fills, lines written back as four stores to a block,
 * the controller's write combining, fetches of what was just stored.
 * It would also run on a board.
 *
 * It prints a digit as each test passes and then PASS, or
 * "FAIL test address got wanted".
 */

#define THR   (*(volatile unsigned char *)0x10000000)
#define LSR   (*(volatile unsigned char *)0x10000005)
#define CACHE (*(volatile unsigned *)0x03000110)
#define MEM   ((volatile unsigned *)0x80000000)

static void out(int c)
{
	while (!(LSR & 0x20)) ;
	THR = c;
}

static void hex(unsigned v)
{
	int i;
	out(' ');
	for (i = 28; i >= 0; i -= 4) out("0123456789abcdef"[(v >> i) & 15]);
}

static void fail(int t, unsigned a, unsigned got, unsigned want)
{
	out('F'); out('A'); out('I'); out('L'); out(' '); out('0' + t);
	hex(a); hex(got); hex(want); out('\n');
	for (;;) ;
}

void trapped(unsigned cause, unsigned epc, unsigned tval)
{
	fail(9, cause, epc, tval);
}

/* a sequence with no pattern a shifted or repeated word would fit */
static unsigned next(unsigned s)
{
	return (s << 1) ^ ((int)s < 0 ? 0x04c11db7 : 0);
}

typedef unsigned (*fn_t)(unsigned);

int main(void)
{
	unsigned i, s, a, v;

	CACHE = 5;

	/* 1: 32 KB of words, twice the data cache, written and then read:
	   every line is written back and fetched again */
	s = 0x12345678;
	for (i = 0; i < 8192; i++) { MEM[i] = s; s = next(s); }
	s = 0x12345678;
	for (i = 0; i < 8192; i++) {
		v = MEM[i];
		if (v != s) fail(1, (unsigned)&MEM[i], v, s);
		s = next(s);
	}
	out('1');

	/* 2: words all over 256 KB, written in one order and read in the
	   other: a miss nearly every time, no two in one block */
	for (i = 0; i < 1024; i++) {
		a = 0x4000 + ((i * 2053u) & 0xffff);
		MEM[a] = a ^ 0xdeadbeef ^ (a << 16);
	}
	for (i = 1024; i-- > 0; ) {
		a = 0x4000 + ((i * 2053u) & 0xffff);
		v = MEM[a];
		if (v != (a ^ 0xdeadbeef ^ (a << 16))) fail(2, (unsigned)&MEM[a], v, a ^ 0xdeadbeef ^ (a << 16));
	}
	out('2');

	/* 3: bytes and halves, into lines that are not in the cache */
	{
		volatile unsigned char *b = (volatile unsigned char *)&MEM[0x20000];
		volatile unsigned short *h = (volatile unsigned short *)&MEM[0x21000];
		for (i = 0; i < 256; i++) MEM[0x20000 + (i >> 2)] = 0xffffffff;
		for (i = 0; i < 256; i += 3) b[i] = i * 7 + 1;
		for (i = 0; i < 256; i++) {
			v = (i % 3 == 0) ? ((i * 7 + 1) & 0xff) : 0xff;
			if (b[i] != v) fail(3, (unsigned)&b[i], b[i], v);
		}
		for (i = 0; i < 64; i++) h[i] = 0xa500 + i;
		for (i = 0; i < 32; i++) {
			v = MEM[0x21000 + i];
			a = (0xa500 + 2 * i) | (0xa500 + 2 * i + 1) << 16;
			if (v != a) fail(3, (unsigned)&MEM[0x21000 + i], v, a);
		}
	}
	out('3');

	/* 4: three lines that share a place in the data cache, in turn:
	   each store puts another's line out */
	MEM[0x30100] = 0; MEM[0x30100 + 4096] = 0; MEM[0x30100 + 8192] = 0;
	for (i = 0; i < 48; i++) {
		MEM[0x30100] += 1;
		MEM[0x30100 + 4096] += 3;
		MEM[0x30100 + 8192] += 5;
	}
	if (MEM[0x30100] != 48) fail(4, 0, MEM[0x30100], 48);
	if (MEM[0x30100 + 4096] != 144) fail(4, 1, MEM[0x30100 + 4096], 144);
	if (MEM[0x30100 + 8192] != 240) fail(4, 2, MEM[0x30100 + 8192], 240);
	out('4');

	/* 5: instructions. A function stored and called at once (its lines
	   are in the data cache, unwritten, when they are first fetched);
	   then changed, and after fence.i the change is what runs */
	{
		volatile unsigned *c = &MEM[0x40000];
		fn_t f = (fn_t)&MEM[0x40000];
		for (i = 0; i < 21; i++) c[i] = 0x00150513;	/* addi a0, a0, 1 */
		c[21] = 0x00008067;							/* ret */
		v = f(100);
		if (v != 121) fail(5, 0, v, 121);
		c[10] = 0x06450513;							/* addi a0, a0, 100 */
		__asm__ volatile ("fence.i");
		v = f(100);
		if (v != 220) fail(5, 1, v, 220);
		/* and data read from a line that is also in the instruction cache */
		if (c[21] != 0x00008067) fail(5, 2, c[21], 0x00008067);
	}
	out('5');

	/* 6: stores with pauses between them, so that the controller
	   writes its block on its own; then all read back */
	for (i = 0; i < 48; i++) {
		volatile int d;
		MEM[0x50000 + i * 5] = 0xc0de0000 + i;
		for (d = 0; d < (int)(i & 3); d++) ;
	}
	for (i = 0; i < 48; i++) {
		v = MEM[0x50000 + i * 5];
		if (v != 0xc0de0000 + i) fail(6, (unsigned)&MEM[0x50000 + i * 5], v, 0xc0de0000 + i);
	}
	out('6');

	/* 7: the first test's words again: they have been out of the cache
	   since, and through everything above */
	s = 0x12345678;
	for (i = 0; i < 8192; i++) {
		v = MEM[i];
		if (v != s) fail(7, (unsigned)&MEM[i], v, s);
		s = next(s);
	}
	out('7');

	out(' '); out('P'); out('A'); out('S'); out('S'); out('\n');
	for (;;) ;
}
