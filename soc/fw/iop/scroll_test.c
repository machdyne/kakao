/*
 * scroll_test -- the first terminal's scroll buffer (term.c), on the
 * host: a hundred numbered lines, and what the picture's top row is
 * as it is scrolled back and forward and as more arrives meanwhile.
 */
#include <stdio.h>
#include <stdint.h>
#include "term.h"

uint8_t mouse_sel_on;
void mouse_clear(void) { }
void term_send(unsigned char c) { (void)c; }

static int errors;

static int top_line(void)
{
	/* the picture's top row says "Lnnn" */
	if ((term_cell(0, 0) & 0xff) != 'L') return -1;
	return ((term_cell(0, 1) & 0xff) - '0') * 100 + ((term_cell(0, 2) & 0xff) - '0') * 10 +
	       ((term_cell(0, 3) & 0xff) - '0');
}

static void want(const char *what, int got, int should)
{
	if (got != should) { printf("FAIL: %s: line %d at the top, should be %d\n", what, got, should); errors++; }
}

static void lines(int from, int to)
{
	char s[16];
	for (; from <= to; from++) { sprintf(s, "L%03d\r\n", from); term_puts(s); }
}

int main(void)
{
	term_init(2, 2);				/* two terminals; two screens of buffer: 60 rows */
	term_use(0);
	lines(0, 99);					/* the screen: L071..L099 and an empty row */
	want("the screen", top_line(), 71);
	term_scroll(1);   want("a row back", top_line(), 70);
	term_scroll(25);  want("a page back", top_line(), 45);
	term_scroll(-1);  want("a row forward", top_line(), 46);
	term_scroll(1000); want("as far back as it goes", top_line(), 11);
	lines(100, 100);				/* the oldest row goes; the picture stays at the end of the buffer */
	want("a line more, at the buffer's end", top_line(), 12);
	term_scroll(-30);
	want("thirty forward", top_line(), 42);
	lines(101, 103);				/* the picture stays on what it shows */
	want("three lines more, in the middle", top_line(), 42);
	want("scrolled", term_scrolled(), 1);
	term_scroll(0);   want("back to the screen", top_line(), 75);
	want("not scrolled", term_scrolled(), 0);
	/* the other terminal has no buffer, and is not disturbed */
	term_use(1);
	lines(0, 49);
	term_show(1);
	want("the second terminal", top_line(), 21);
	term_scroll(5);   want("...has nothing to scroll back to", top_line(), 21);
	term_show(0);     want("the first again", top_line(), 75);
	/* a reset empties the buffer */
	term_use(0);
	term_puts("\033c");
	lines(0, 9);
	term_scroll(5);
	want("after a reset: nothing above the screen", top_line(), 0);
	if (errors == 0) printf("scroll_test: PASS\n");
	return errors != 0;
}
