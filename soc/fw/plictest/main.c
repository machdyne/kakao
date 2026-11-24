/*
 * plictest: the interrupt controller and UART 0's interrupts, from
 * kakao_soc's boot memory, in M-mode (sim/tb_soc_rom.v). It prints a
 * digit as each test passes and then PASS, or "FAIL n".
 */

#define UART   ((volatile unsigned char *)0x10000000)
#define THR    UART[0]
#define IER    UART[1]
#define IIR    UART[2]
#define LCR    UART[3]
#define LSR    UART[5]
#define SCR    UART[7]
#define PLIC   0x0c000000
#define PRIO(n)   (*(volatile unsigned *)(PLIC + 4 * (n)))
#define PENDING   (*(volatile unsigned *)(PLIC + 0x1000))
#define ENABLE(c) (*(volatile unsigned *)(PLIC + 0x2000 + 0x80 * (c)))
#define THRESH(c) (*(volatile unsigned *)(PLIC + 0x200000 + 0x1000 * (c)))
#define CLAIM(c)  (*(volatile unsigned *)(PLIC + 0x200004 + 0x1000 * (c)))

#define csr_read(r) ({ unsigned v_; __asm__ volatile ("csrr %0, " #r : "=r"(v_)); v_; })
#define csr_set(r, v) __asm__ volatile ("csrs " #r ", %0" :: "r"((unsigned)(v)))
#define csr_clear(r, v) __asm__ volatile ("csrc " #r ", %0" :: "r"((unsigned)(v)))

static volatile unsigned n_irq, last_id, last_iir;

static void out(int c)
{
	while (!(LSR & 0x20)) ;
	THR = c;
}

static void fail(int n)
{
	csr_clear(mstatus, 8);
	IER = 0;
	out('F'); out('A'); out('I'); out('L'); out(' '); out('0' + n); out('\n');
	for (;;) ;
}

/* M external interrupt: claim, look at the UART, complete */
void trap_c(unsigned cause)
{
	unsigned id;
	if (cause != 0x8000000b) fail(9);
	id = CLAIM(0);
	last_id = id;
	last_iir = IIR;			/* (takes the transmitter's reason back) */
	n_irq++;
	CLAIM(0) = id;
}

static void wait_tx(void)
{
	while (!(LSR & 0x40)) ;
}

int main(void)
{
	unsigned i;

	out('0');
	wait_tx();

	/* 1: the registers that are only kept; the divisor does not send */
	SCR = 0x5a;
	if (SCR != 0x5a) fail(1);
	LCR = 0x83;
	UART[0] = 0x1a; UART[1] = 0x00;		/* the divisor: not characters */
	if (UART[0] != 0x1a) fail(1);
	LCR = 0x03;
	if (LCR != 0x03 || IER != 0) fail(1);
	if ((IIR & 0x0f) != 1) fail(1);
	out('1');
	wait_tx();

	/* 2: nothing is pending, nothing claims */
	if (PENDING != 0 || CLAIM(0) != 0 || CLAIM(1) != 0) fail(2);
	if (csr_read(mip) & 0xa00) fail(2);

	/* the transmitter's interrupt reaches the PLIC, and M-mode only
	   when enabled there with a priority above the threshold */
	IER = 2;
	for (i = 0; i < 20; i++) ;
	if (!(PENDING & (1 << 10))) fail(2);
	if (csr_read(mip) & 0xa00) fail(2);
	PRIO(10) = 1;
	ENABLE(0) = 1 << 10;
	THRESH(0) = 1;
	for (i = 0; i < 20; i++) ;
	if (csr_read(mip) & 0x800) fail(2);
	THRESH(0) = 0;
	for (i = 0; i < 20; i++) ;
	if (!(csr_read(mip) & 0x800)) fail(2);
	if (csr_read(mip) & 0x200) fail(2);		/* not S-mode's */
	out('2');

	/* 3: taken as an interrupt: source 10, the transmitter's reason,
	   once */
	n_irq = 0;
	csr_set(mie, 0x800);
	csr_set(mstatus, 8);
	for (i = 0; i < 200; i++) ;
	csr_clear(mstatus, 8);
	if (n_irq != 1 || last_id != 10 || (last_iir & 0x0f) != 2) fail(3);
	if (PENDING != 0) fail(3);
	out('3');

	/* 4: each character sent brings one (the one for the '3' just sent
	   is taken by hand first: it is pending in the PLIC by now) */
	wait_tx();
	for (i = 0; i < 20; i++) ;
	if (CLAIM(0) != 10) fail(4);
	(void)IIR;
	CLAIM(0) = 10;
	for (i = 0; i < 20; i++) ;
	if (PENDING != 0) fail(4);
	n_irq = 0;
	csr_set(mstatus, 8);
	for (i = 0; i < 5; i++) {
		unsigned was = n_irq;
		THR = 'a' + i;
		while (n_irq == was) ;
	}
	csr_clear(mstatus, 8);
	if (n_irq != 5) fail(4);
	IER = 0;
	out('4');
	wait_tx();

	/* 5: the S-mode context: its own enables and claim */
	IER = 2;
	ENABLE(0) = 0;
	ENABLE(1) = 1 << 10;
	PRIO(10) = 7;
	THRESH(1) = 6;
	for (i = 0; i < 20; i++) ;
	if ((csr_read(mip) & 0xa00) != 0x200) fail(5);
	if (CLAIM(0) != 0) fail(5);
	if (CLAIM(1) != 10) fail(5);
	for (i = 0; i < 20; i++) ;
	if (csr_read(mip) & 0x200) fail(5);			/* being served */
	if (CLAIM(1) != 0) fail(5);
	IER = 0;
	CLAIM(1) = 10;
	for (i = 0; i < 20; i++) ;
	if (PENDING != 0 || (csr_read(mip) & 0xa00)) fail(5);
	out('5');

	out(' '); out('P'); out('A'); out('S'); out('S'); out('\n');
	for (;;) ;
}
