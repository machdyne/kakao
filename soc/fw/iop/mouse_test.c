/*
 * The mouse's selecting, copying and pasting (mouse.c) on the terminal
 * (term.c), built for this machine: text is put on a screen, the mouse
 * is moved over it, and what is copied and what is typed back are
 * compared with what should be.   make mouse_test && ./mouse_test
 */

#include <stdio.h>
#include <string.h>
#include "iop.h"
#include "term.h"


static unsigned char typed[4096];
static unsigned typed_n, room = 1000000, ticks;
static const char *note = "";
static int errors;

void host_put(unsigned char c) { if (typed_n < sizeof typed) typed[typed_n++] = c; if (room) room--; }
int host_room(void) { return room != 0; }
void term_send(unsigned char c) { (void)c; }
uint32_t now_ticks(void) { return ticks; }
int hud_active(void) { return 0; }
void hud_note(const char *t) { note = t; }
const unsigned char *mouse_clip(unsigned *n);

static void say(const char *s) { while (*s) term_char((unsigned char)*s++); }
static void at(int row, int col, int b) { mouse_at(col * 8 + 3, row * 16 + 5, b); }

static void want(const char *what, const unsigned char *got, unsigned n, const char *should)
{
	if (n != strlen(should) || memcmp(got, should, n)) {
		printf("FAIL: %s is \"%.*s\" (%u), should be \"%s\"\n", what, (int)n, got, n, should);
		errors++;
	}
}
static void want_reg(const char *what, uint32_t got, uint32_t should)
{
	if (got != should) { printf("FAIL: %s is %08x, should be %08x\n", what, got, should); errors++; }
}

int main(void)
{
	const unsigned char *c;
	unsigned n;

	term_init(2, 0);
	term_use(0);
	say("first line here   \r\nsecond \xc3\xbc line\r\nthird");

	/* the pointer alone */
	at(0, 6, 0);
	want_reg("pointer", t_regs[6], 0x8000 | 6);
	want_reg("no selection", t_regs[7], 0);
	mouse_copy();
	want("note", (const unsigned char *)note, strlen(note), "Nothing is selected");

	/* a click selects nothing; a drag does, here backwards */
	at(1, 7, 1); at(1, 7, 0);
	want_reg("a click", t_regs[7], 0);
	at(1, 7, 1); at(1, 2, 1); at(0, 6, 1); at(0, 6, 0);
	want_reg("selection", t_regs[7], 0x80000000u | (80 + 7) << 16 | 6);
	want_reg("pointer after", t_regs[6], 0x8000 | 6);
	mouse_copy();
	c = mouse_clip(&n);
	want("copied", c, n, "line here\rsecond \xc3\xbc");

	/* typed back, plain; and it is still selected until something is written */
	mouse_paste(); mouse_pump();
	want("pasted", typed, typed_n, "line here\rsecond \xc3\xbc");
	want_reg("still selected", t_regs[7] >> 31, 1);
	say("x");
	want_reg("gone when written to", t_regs[7], 0);

	/* in brackets when the host asked, and in pieces when the queue is short */
	say("\033[?2004h");
	typed_n = 0; room = 5;
	mouse_paste(); mouse_pump();
	if (typed_n != 5) { printf("FAIL: %u typed with room for 5\n", typed_n); errors++; }
	room = 1000000; mouse_pump();
	want("pasted in brackets", typed, typed_n, "\033[200~line here\rsecond \xc3\xbc\033[201~");

	/* a whole row, and the next one's start: blanks at a row's end are left out */
	at(2, 0, 1); at(2, 79, 1); at(2, 79, 0);
	mouse_copy();
	c = mouse_clip(&n);
	want("a row", c, n, "thirdx");

	/* another terminal shown: nothing selected there */
	at(0, 0, 1); at(0, 4, 1); at(0, 4, 0);
	term_show(1);
	want_reg("gone with the terminal", t_regs[7], 0);

	/* it goes away when left alone */
	ticks += 11 * 732; mouse_tick();
	want_reg("pointer hidden", t_regs[6], 0);

	printf(errors ? "%d errors\n" : "ok: selecting, copying and pasting\n", errors);
	return errors != 0;
}
