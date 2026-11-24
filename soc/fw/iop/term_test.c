/*
 * The terminal on this machine: standard input is what the host
 * sends; the screen comes out as 30 lines of text, 30 lines of
 * attributes (two hex digits a cell), the cursor, and what the
 * terminal answered. tests/compare.py reads that.
 */

#include <stdio.h>
#include "term.h"

static unsigned char ans[4096];
static int n_ans;

void term_send(unsigned char c)
{
	if (n_ans < (int)sizeof ans) ans[n_ans++] = c;
}

/* (no mouse here) */
unsigned char mouse_sel_on;
void mouse_clear(void) {}

int main(void)
{
	int c, r, k;
	term_init(1, 0);
	while ((c = getchar()) != EOF) term_char((unsigned char)c);
	term_update();

	/* the picture as the text mode would draw it: from START, row after
	   row, and from END back to BASE */
	unsigned at = t_regs[2], cur_r = 0, cur_c = 0;
	static unsigned scr[30][80];
	for (r = 0; r < 30; r++) {
		for (k = 0; k < 80; k++) {
			scr[r][k] = t_cells[at + k];
			if (at + k == t_regs[1]) { cur_r = r; cur_c = k; }
		}
		at += 80;
		if (at == t_regs[5]) at = t_regs[4];
	}
	for (r = 0; r < 30; r++) {
		for (k = 0; k < 80; k++) {
			unsigned v = scr[r][k] & 0xff;
			putchar(v >= 0x20 && v < 0x7f ? (int)v : v == 0x7f ? '?' : '#');
		}
		putchar('\n');
	}
	for (r = 0; r < 30; r++) {
		for (k = 0; k < 80; k++) printf("%02x", (scr[r][k] >> 8) & 0xff);
		putchar('\n');
	}
	printf("cursor %u %u ctrl %u\n", cur_r, cur_c, t_regs[0]);
	printf("answer");
	for (k = 0; k < n_ans; k++) printf(" %02x", ans[k]);
	putchar('\n');
	return 0;
}
